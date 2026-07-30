import Foundation
import Accelerate
import CryptoKit
import NaturalLanguage
import Observation

// MARK: - Status (observable, for Settings UI)

/// Live progress of the semantic index, mirrored to the MainActor so
/// Settings can show "Indexing 4 210 / 15 800…" without touching the actor.
@MainActor
@Observable
final class SemanticIndexStatus {
    static let shared = SemanticIndexStatus()

    enum Phase: Equatable {
        case idle
        case preparing
        case indexing(done: Int, total: Int)
        case ready
        case unavailable(String)
    }

    var phase: Phase = .idle
    var indexedChunks: Int = 0
    var lastCompleted: Date?

    var summaryLine: String {
        switch phase {
        case .idle: return "Waiting for first pass"
        case .preparing: return "Scanning your data…"
        case .indexing(let done, let total): return "Indexing \(done) of \(total) items…"
        case .ready: return "\(indexedChunks) passages indexed"
        case .unavailable(let reason): return "Unavailable — \(reason)"
        }
    }
}

// MARK: - Search results

struct SemanticHit: Sendable {
    let type: String
    let id: UUID
    let title: String
    let snippet: String
    let date: Date?
    let score: Float
}

enum SemanticQueryOutcome: Sendable {
    /// Index is fully built (or fully caught up) — results are complete.
    case ready([SemanticHit])
    /// First index pass still running — results cover what's embedded so far.
    case building(done: Int, total: Int, partial: [SemanticHit])
    /// Engine can't run (assets missing, model unavailable, no pass yet).
    case unavailable(String)
}

// MARK: - Source documents

/// One indexable item flattened to text. `key` is "\(type):\(id)".
struct SemanticDoc: Sendable {
    let type: String
    let id: UUID
    let title: String
    let date: Date?
    let text: String
    let chunkCap: Int

    var key: String { "\(type):\(id.uuidString)" }
}

/// COW copies of every indexed collection, grabbed on the MainActor in O(1)
/// per array and consumed off-main. Value types only — safe to read across
/// actors once copied.
struct SemanticSnapshot: Sendable {
    var todos: [Todo] = []
    var notes: [Note] = []
    var ideas: [Idea] = []
    var reminders: [Reminder] = []
    var bookmarks: [Bookmark] = []
    var meetings: [Meeting] = []
    var emails: [Email] = []
    var connections: [Connection] = []
    var networkEntries: [NetworkEntry] = []
    var companies: [Company] = []
    var events: [Event] = []
    var communities: [Community] = []
    var files: [FileItem] = []
    var xPosts: [XPost] = []
    var xFollowers: [XFollower] = []
    var xDMs: [XDirectMessage] = []
    var habits: [Habit] = []
    var customTabs: [CustomTabDefinition] = []
    var customRecords: [CustomRecord] = []
    var agentMemories: [AgentMemoryEntry] = []

    @MainActor
    init(appState: AppState) {
        todos = appState.todos
        notes = appState.activeNotes
        ideas = appState.ideas
        reminders = appState.reminders
        bookmarks = appState.bookmarks
        meetings = appState.meetings
        emails = appState.emails
        connections = appState.connections
        networkEntries = appState.networkEntries
        companies = appState.companies
        events = appState.events
        communities = appState.communities
        files = appState.files
        xPosts = appState.xPosts
        xFollowers = appState.xFollowers
        xDMs = appState.xDirectMessages
        habits = appState.habits
        customTabs = appState.customTabs
        customRecords = appState.customRecords
        agentMemories = appState.agentMemories
    }
}

// MARK: - Index service

/// Local semantic index over everything Otto stores. Chunks each item into
/// ~800-char passages, embeds them on-device (`EmbeddingService`), and
/// serves cosine top-K queries for the `semantic_search` agent tool.
///
/// Storage lives OUTSIDE `otto_data.json` (its own folder in Application
/// Support) so index churn never rewrites the main store:
///   - `manifest.json` — per-doc content hashes + slot assignments
///   - `records.json`  — display metadata per live chunk
///   - `vectors.bin`   — raw Float32, slot-major, write-through FileHandle
///
/// Incremental: a revision watcher snapshots AppState when
/// `PersistenceService.revision` moves, re-embedding only docs whose
/// content hash changed. The actor is reentrant at `await` points, so
/// searches interleave with a running bulk pass instead of queueing behind
/// it (searches see partial results until the pass completes).
actor SemanticIndexService {
    static let shared = SemanticIndexService()

    // MARK: Persistent records

    private struct ChunkRecord: Codable {
        var slot: Int
        var docKey: String
        var type: String
        var itemId: UUID
        var title: String
        var snippet: String
        var date: Date?
    }

    private struct DocEntry: Codable {
        var hash: String
        var slots: [Int]
    }

    private struct Manifest: Codable {
        var version: Int
        var dimension: Int
        var slotCount: Int
        var docs: [String: DocEntry]
        var freeSlots: [Int]
    }

    private static let formatVersion = 2

    // MARK: In-memory state

    private var dimension = 0
    private var vectors: [Float] = []          // slotCount * dimension
    private var slotToChunk: [ChunkRecord?] = []
    private var docs: [String: DocEntry] = [:]
    private var freeSlots: [Int] = []
    private var loaded = false
    private var vectorsHandle: FileHandle?

    /// Progress of the current/last sync, mirrored into SemanticIndexStatus.
    private var syncRunning = false
    private var pendingSnapshot: SemanticSnapshot?
    private var lastProgress: (done: Int, total: Int) = (0, 0)
    private var everCompleted = false

    // MARK: Paths

    private static var indexDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Otto", isDirectory: true)
            .appendingPathComponent("SemanticIndex", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static var manifestURL: URL { indexDirectory.appendingPathComponent("manifest.json") }
    private static var recordsURL: URL { indexDirectory.appendingPathComponent("records.json") }
    private static var vectorsURL: URL { indexDirectory.appendingPathComponent("vectors.bin") }

    // MARK: - Install (MainActor side)

    /// Weak AppState holder + revision watcher. Installed once from
    /// `AppState.loadData()`; re-entrant calls are no-ops.
    @MainActor
    private static var installedFor: ObjectIdentifier?

    @MainActor
    static func install(appState: AppState) {
        let key = ObjectIdentifier(appState)
        guard installedFor != key else { return }
        installedFor = key

        Task(priority: .utility) { [weak appState] in
            var lastSeenRevision = -1
            while !Task.isCancelled {
                guard let state = appState else { return }
                let revision = PersistenceService.revision
                if revision != lastSeenRevision {
                    lastSeenRevision = revision
                    let snapshot = SemanticSnapshot(appState: state)
                    await shared.requestSync(snapshot)
                }
                try? await Task.sleep(nanoseconds: 12_000_000_000)
            }
        }
    }

    // MARK: - Sync entry

    /// Queue a sync for this snapshot. If a pass is already running the
    /// snapshot is parked and drained when the pass finishes (only the
    /// latest parked snapshot is kept — intermediate states are moot).
    func requestSync(_ snapshot: SemanticSnapshot) async {
        if syncRunning {
            pendingSnapshot = snapshot
            return
        }
        syncRunning = true
        defer { syncRunning = false }

        var current: SemanticSnapshot? = snapshot
        while let snap = current {
            await runSync(snap)
            current = pendingSnapshot
            pendingSnapshot = nil
        }
    }

    private func runSync(_ snapshot: SemanticSnapshot) async {
        do {
            try await EmbeddingService.shared.ensureReady()
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? "embedding model unavailable"
            await setPhase(.unavailable(reason))
            return
        }
        let dim = await EmbeddingService.shared.dimension
        loadIfNeeded(expectedDimension: dim)

        await setPhase(.preparing)

        let sourceDocs = Self.buildDocs(from: snapshot)
        var byKey: [String: SemanticDoc] = [:]
        byKey.reserveCapacity(sourceDocs.count)
        var hashes: [String: String] = [:]
        for doc in sourceDocs {
            byKey[doc.key] = doc
            hashes[doc.key] = Self.contentHash(of: doc)
        }

        // Drop docs that no longer exist.
        for key in Array(docs.keys) where byKey[key] == nil {
            freeDoc(key)
        }

        // Docs whose content changed (or are new).
        let work = sourceDocs.filter { docs[$0.key]?.hash != hashes[$0.key] }
        lastProgress = (0, work.count)

        if work.isEmpty {
            persist()
            everCompleted = true
            await finishStatus()
            return
        }

        var processed = 0
        var sinceCheckpoint = 0
        for doc in work {
            freeDoc(doc.key)

            var slots: [Int] = []
            let parts = Self.chunk(doc.text, cap: doc.chunkCap)
            for part in parts {
                guard let vector = await EmbeddingService.shared.vector(for: part) else { continue }
                let slot = allocateSlot()
                writeVector(vector, at: slot)
                slotToChunk[slot] = ChunkRecord(
                    slot: slot,
                    docKey: doc.key,
                    type: doc.type,
                    itemId: doc.id,
                    title: doc.title,
                    snippet: String(part.prefix(240)),
                    date: doc.date
                )
                slots.append(slot)
            }
            docs[doc.key] = DocEntry(hash: hashes[doc.key] ?? "", slots: slots)

            processed += 1
            sinceCheckpoint += 1
            lastProgress = (processed, work.count)
            if sinceCheckpoint >= 400 {
                sinceCheckpoint = 0
                persist()
            }
            if processed % 25 == 0 {
                await setPhase(.indexing(done: processed, total: work.count))
            }
        }

        persist()
        everCompleted = true
        await finishStatus()
    }

    private func setPhase(_ phase: SemanticIndexStatus.Phase) async {
        let chunks = liveChunkCount()
        await MainActor.run {
            SemanticIndexStatus.shared.phase = phase
            SemanticIndexStatus.shared.indexedChunks = chunks
        }
    }

    private func finishStatus() async {
        let chunks = liveChunkCount()
        await MainActor.run {
            SemanticIndexStatus.shared.phase = .ready
            SemanticIndexStatus.shared.indexedChunks = chunks
            SemanticIndexStatus.shared.lastCompleted = Date()
        }
    }

    private func liveChunkCount() -> Int {
        slotToChunk.lazy.compactMap { $0 }.count
    }

    // MARK: - Search

    /// Rank every live chunk against the best of `queries` (multiple query
    /// phrasings — e.g. an English + Turkish variant — are max-merged per
    /// chunk) and return the top `limit` distinct items.
    func search(queries: [String], types: Set<String>?, limit: Int) async -> SemanticQueryOutcome {
        do {
            try await EmbeddingService.shared.ensureReady()
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? "embedding model unavailable"
            return .unavailable(reason)
        }
        let dim = await EmbeddingService.shared.dimension
        loadIfNeeded(expectedDimension: dim)

        var queryVectors: [[Float]] = []
        for query in queries.prefix(5) {
            if let v = await EmbeddingService.shared.vector(for: query) { queryVectors.append(v) }
        }
        guard !queryVectors.isEmpty else { return .unavailable("query could not be embedded") }

        guard dimension > 0, !slotToChunk.isEmpty else {
            if everCompleted { return .ready([]) }
            return .unavailable("index has not been built yet — it fills in the background after launch")
        }

        // Best score per doc, computed chunk-by-chunk with vDSP dots.
        struct DocBest {
            var score: Float
            var record: ChunkRecord
        }
        var best: [String: DocBest] = [:]

        vectors.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for record in slotToChunk {
                guard let record else { continue }
                if let types, !types.contains(record.type) { continue }
                var chunkScore: Float = -2
                for q in queryVectors {
                    var dot: Float = 0
                    q.withUnsafeBufferPointer { qb in
                        vDSP_dotpr(base + record.slot * dimension, 1, qb.baseAddress!, 1, &dot, vDSP_Length(dimension))
                    }
                    chunkScore = max(chunkScore, dot)
                }
                if let existing = best[record.docKey] {
                    if chunkScore > existing.score {
                        best[record.docKey] = DocBest(score: chunkScore, record: record)
                    }
                } else {
                    best[record.docKey] = DocBest(score: chunkScore, record: record)
                }
            }
        }

        let ranked = best.values
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return (lhs.record.date ?? .distantPast) > (rhs.record.date ?? .distantPast)
            }
            .prefix(max(1, limit))
            .map { item in
                SemanticHit(
                    type: item.record.type,
                    id: item.record.itemId,
                    title: item.record.title,
                    snippet: item.record.snippet,
                    date: item.record.date,
                    score: item.score
                )
            }

        if syncRunning && !everCompleted {
            return .building(done: lastProgress.done, total: lastProgress.total, partial: Array(ranked))
        }
        return .ready(Array(ranked))
    }

    /// Cosine similarity of two short texts — used by `remember` for
    /// semantic dedupe of memories. Returns nil when embedding fails.
    func similarity(_ a: String, _ b: String) async -> Float? {
        guard let va = await EmbeddingService.shared.vector(for: a),
              let vb = await EmbeddingService.shared.vector(for: b) else { return nil }
        var dot: Float = 0
        vDSP_dotpr(va, 1, vb, 1, &dot, vDSP_Length(min(va.count, vb.count)))
        return dot
    }

    // MARK: - Slot + vector management

    private func allocateSlot() -> Int {
        if let slot = freeSlots.popLast() { return slot }
        let slot = slotToChunk.count
        slotToChunk.append(nil)
        vectors.append(contentsOf: [Float](repeating: 0, count: dimension))
        return slot
    }

    private func freeDoc(_ key: String) {
        guard let entry = docs.removeValue(forKey: key) else { return }
        for slot in entry.slots where slot < slotToChunk.count {
            slotToChunk[slot] = nil
            freeSlots.append(slot)
        }
    }

    private func writeVector(_ vector: [Float], at slot: Int) {
        let start = slot * dimension
        guard vector.count == dimension, start + dimension <= vectors.count else { return }
        vectors.replaceSubrange(start..<(start + dimension), with: vector)

        if let handle = vectorsHandle {
            let offset = UInt64(start * MemoryLayout<Float>.size)
            let data = vector.withUnsafeBufferPointer { Data(buffer: $0) }
            try? handle.seek(toOffset: offset)
            try? handle.write(contentsOf: data)
        }
    }

    // MARK: - Load / persist

    private func loadIfNeeded(expectedDimension: Int) {
        guard !loaded else { return }
        loaded = true
        dimension = expectedDimension

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var restored = false
        if let manifestData = try? Data(contentsOf: Self.manifestURL),
           let manifest = try? decoder.decode(Manifest.self, from: manifestData),
           manifest.version == Self.formatVersion,
           manifest.dimension == expectedDimension,
           let recordsData = try? Data(contentsOf: Self.recordsURL),
           let records = try? decoder.decode([ChunkRecord].self, from: recordsData),
           let vectorData = try? Data(contentsOf: Self.vectorsURL),
           vectorData.count >= manifest.slotCount * expectedDimension * MemoryLayout<Float>.size {

            var loadedVectors = [Float](repeating: 0, count: manifest.slotCount * expectedDimension)
            _ = loadedVectors.withUnsafeMutableBytes { dest in
                vectorData.copyBytes(to: dest, count: dest.count)
            }
            vectors = loadedVectors
            slotToChunk = Array(repeating: nil, count: manifest.slotCount)
            for record in records where record.slot < manifest.slotCount {
                slotToChunk[record.slot] = record
            }
            docs = manifest.docs
            freeSlots = manifest.freeSlots.filter { $0 < manifest.slotCount }
            everCompleted = !docs.isEmpty
            restored = true
        }

        if !restored {
            // Fresh (or corrupt/mismatched) index — start clean; the next
            // sync pass rebuilds everything from live data.
            vectors = []
            slotToChunk = []
            docs = [:]
            freeSlots = []
            try? FileManager.default.removeItem(at: Self.vectorsURL)
        }

        FileManager.default.createFile(atPath: Self.vectorsURL.path, contents: nil)
        if restored {
            // Recreate the backing file from RAM so handle writes and the
            // in-memory copy can't drift (also heals partial checkpoints).
            let data = vectors.withUnsafeBufferPointer { Data(buffer: $0) }
            try? data.write(to: Self.vectorsURL)
        }
        vectorsHandle = try? FileHandle(forWritingTo: Self.vectorsURL)
    }

    /// Compact free space when it dominates, then write manifest + records.
    private func persist() {
        if freeSlots.count > 2_000, freeSlots.count * 2 > slotToChunk.count {
            compact()
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let manifest = Manifest(
            version: Self.formatVersion,
            dimension: dimension,
            slotCount: slotToChunk.count,
            docs: docs,
            freeSlots: freeSlots
        )
        if let data = try? encoder.encode(manifest) {
            try? data.write(to: Self.manifestURL, options: .atomic)
        }
        let records = slotToChunk.compactMap { $0 }
        if let data = try? encoder.encode(records) {
            try? data.write(to: Self.recordsURL, options: .atomic)
        }
        try? vectorsHandle?.synchronize()
    }

    /// Rebuild slots densely, dropping freed rows, and rewrite vectors.bin.
    private func compact() {
        var newVectors: [Float] = []
        newVectors.reserveCapacity(liveChunkCount() * dimension)
        var newSlots: [ChunkRecord?] = []
        var remap: [String: [Int]] = [:]

        for record in slotToChunk {
            guard var record else { continue }
            let newSlot = newSlots.count
            let start = record.slot * dimension
            guard start + dimension <= vectors.count else { continue }
            newVectors.append(contentsOf: vectors[start..<(start + dimension)])
            record.slot = newSlot
            newSlots.append(record)
            remap[record.docKey, default: []].append(newSlot)
        }

        vectors = newVectors
        slotToChunk = newSlots
        freeSlots = []
        for (key, slots) in remap {
            docs[key]?.slots = slots
        }

        try? vectorsHandle?.close()
        let data = vectors.withUnsafeBufferPointer { Data(buffer: $0) }
        try? data.write(to: Self.vectorsURL)
        vectorsHandle = try? FileHandle(forWritingTo: Self.vectorsURL)
    }

    // MARK: - Hashing

    private static func contentHash(of doc: SemanticDoc) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(doc.title.utf8))
        hasher.update(data: Data(doc.text.utf8))
        if let date = doc.date {
            var stamp = date.timeIntervalSince1970.rounded()
            hasher.update(data: Data(bytes: &stamp, count: MemoryLayout<Double>.size))
        }
        return hasher.finalize().prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Chunking

    /// Split into ~800-char passages on sentence boundaries (paragraphs
    /// first), capped at `cap` chunks per document.
    static func chunk(_ text: String, target: Int = 800, cap: Int) -> [String] {
        let cleaned = normalize(text)
        guard !cleaned.isEmpty else { return [] }
        if cleaned.count <= target { return [cleaned] }

        var chunks: [String] = []
        var current = ""

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count >= 3 { chunks.append(trimmed) }
            current = ""
        }

        let paragraphs = cleaned.components(separatedBy: "\n")
        outer: for paragraph in paragraphs {
            let para = paragraph.trimmingCharacters(in: .whitespaces)
            if para.isEmpty { continue }

            let pieces: [String]
            if para.count > target {
                pieces = sentences(of: para)
            } else {
                pieces = [para]
            }

            for piece in pieces {
                if current.count + piece.count + 1 > target, !current.isEmpty {
                    flush()
                    if chunks.count >= cap { break outer }
                }
                if piece.count > target * 2 {
                    // Pathological run (URL soup, minified text) — hard split.
                    var rest = Substring(piece)
                    while !rest.isEmpty {
                        let take = rest.prefix(target)
                        chunks.append(String(take))
                        rest = rest.dropFirst(take.count)
                        if chunks.count >= cap { break outer }
                    }
                } else {
                    current += current.isEmpty ? piece : " " + piece
                }
            }
            current += "\n"
        }
        flush()

        if chunks.count > cap { chunks = Array(chunks.prefix(cap)) }
        return chunks
    }

    private static func sentences(of text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var result: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { result.append(sentence) }
            return true
        }
        return result.isEmpty ? [text] : result
    }

    /// Light cleanup: markdown chrome out, whitespace collapsed, image
    /// references dropped. Keeps link text, drops the URL targets.
    static func normalize(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[#*_`>+|]"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\n{2,}"#, with: "\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let recordDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    // MARK: - Doc builders

    /// Flatten every collection into SemanticDocs. Pure function of the
    /// snapshot — field choices mirror what search_items matches on, plus
    /// long-form content (bodies, transcripts, extracted file text).
    static func buildDocs(from s: SemanticSnapshot) -> [SemanticDoc] {
        var docs: [SemanticDoc] = []
        var capacity = s.todos.count + s.notes.count + s.ideas.count + s.reminders.count
        capacity += s.bookmarks.count + s.meetings.count + s.emails.count + s.connections.count
        capacity += s.networkEntries.count + s.companies.count + s.events.count + s.communities.count
        capacity += s.files.count + s.xPosts.count + s.xFollowers.count + s.xDMs.count
        capacity += s.habits.count + s.customRecords.count + s.agentMemories.count
        docs.reserveCapacity(capacity)

        for t in s.todos {
            let subs = t.subTasks.map(\.title).joined(separator: "\n")
            docs.append(SemanticDoc(
                type: ContentType.todo.rawValue, id: t.id, title: t.title,
                date: t.dueDate ?? t.updatedAt,
                text: [t.title, t.description, subs].joined(separator: "\n"),
                chunkCap: 4
            ))
        }
        for n in s.notes {
            docs.append(SemanticDoc(
                type: ContentType.note.rawValue, id: n.id, title: n.title,
                date: n.updatedAt,
                text: n.title + "\n" + n.content,
                chunkCap: 10
            ))
        }
        for i in s.ideas {
            docs.append(SemanticDoc(
                type: ContentType.idea.rawValue, id: i.id, title: i.title,
                date: i.updatedAt,
                text: i.title + "\n" + i.content,
                chunkCap: 6
            ))
        }
        for r in s.reminders {
            docs.append(SemanticDoc(
                type: ContentType.reminder.rawValue, id: r.id, title: r.title,
                date: r.reminderDate,
                text: r.title,
                chunkCap: 1
            ))
        }
        for b in s.bookmarks {
            let host = URL(string: b.url)?.host ?? b.url
            docs.append(SemanticDoc(
                type: ContentType.bookmark.rawValue, id: b.id, title: b.title,
                date: b.updatedAt,
                text: [b.title, b.description, b.ogDescription ?? "", b.siteName ?? "", host]
                    .filter { !$0.isEmpty }.joined(separator: "\n"),
                chunkCap: 3
            ))
        }
        for m in s.meetings {
            let people = (["Organizer: " + m.organizer] + m.participants).joined(separator: ", ")
            let parts = [m.title, people, m.overview, m.actionItems, m.content, m.transcript ?? ""]
            docs.append(SemanticDoc(
                type: ContentType.meeting.rawValue, id: m.id, title: m.title,
                date: m.meetingDate,
                text: parts.filter { !$0.isEmpty }.joined(separator: "\n"),
                chunkCap: 26
            ))
        }
        for e in s.emails {
            let sender = e.senderName.map { "\($0) <\(e.sender)>" } ?? e.sender
            let title = e.subject.isEmpty ? "(no subject) — \(sender)" : e.subject
            docs.append(SemanticDoc(
                type: ContentType.email.rawValue, id: e.id, title: title,
                date: e.receivedDate,
                text: [e.subject, "From: " + sender, String(e.body.prefix(9_000))].joined(separator: "\n"),
                chunkCap: 6
            ))
        }
        for c in s.connections {
            docs.append(SemanticDoc(
                type: ContentType.connection.rawValue, id: c.id, title: c.fullName,
                date: c.lastContactedAt ?? c.updatedAt,
                text: c.searchableContent,
                chunkCap: 2
            ))
        }
        for n in s.networkEntries {
            docs.append(SemanticDoc(
                type: "network", id: n.id,
                title: n.name.isEmpty ? n.company : n.name,
                date: n.updatedAt,
                text: n.searchableContent,
                chunkCap: 4
            ))
        }
        for c in s.companies {
            docs.append(SemanticDoc(
                type: ContentType.company.rawValue, id: c.id, title: c.name,
                date: c.updatedAt,
                text: [c.name, c.location, c.notes, c.tags.joined(separator: ", ")]
                    .filter { !$0.isEmpty }.joined(separator: "\n"),
                chunkCap: 3
            ))
        }
        for e in s.events {
            docs.append(SemanticDoc(
                type: ContentType.event.rawValue, id: e.id, title: e.name,
                date: e.startDate ?? e.updatedAt,
                text: [e.name, e.location, e.notes, e.tags.joined(separator: ", ")]
                    .filter { !$0.isEmpty }.joined(separator: "\n"),
                chunkCap: 3
            ))
        }
        for c in s.communities {
            docs.append(SemanticDoc(
                type: ContentType.community.rawValue, id: c.id, title: c.name,
                date: c.updatedAt,
                text: [c.name, c.location, c.notes, c.tags.joined(separator: ", ")]
                    .filter { !$0.isEmpty }.joined(separator: "\n"),
                chunkCap: 3
            ))
        }
        for f in s.files {
            docs.append(SemanticDoc(
                type: ContentType.file.rawValue, id: f.id, title: f.name,
                date: f.updatedAt,
                text: [f.name, f.notes, f.tags.joined(separator: ", "),
                       String((f.extractedText ?? "").prefix(9_000))]
                    .filter { !$0.isEmpty }.joined(separator: "\n"),
                chunkCap: 8
            ))
        }
        for p in s.xPosts {
            docs.append(SemanticDoc(
                type: "x_post", id: p.id,
                title: String(p.text.prefix(64)),
                date: p.createdAt,
                text: "@" + p.authorUsername + " (" + p.authorDisplayName + ")\n" + p.text,
                chunkCap: 2
            ))
        }
        for f in s.xFollowers {
            docs.append(SemanticDoc(
                type: "x_follower", id: f.id,
                title: f.displayName.isEmpty ? "@" + f.username : f.displayName,
                date: f.syncUpdatedAt,
                text: f.displayName + " @" + f.username + "\n" + f.bio,
                chunkCap: 1
            ))
        }
        for d in s.xDMs {
            docs.append(SemanticDoc(
                type: "x_dm", id: d.id,
                title: "DM — " + (d.senderDisplayName.isEmpty ? "@" + d.senderUsername : d.senderDisplayName),
                date: d.createdAt,
                text: "@" + d.senderUsername + ": " + d.text,
                chunkCap: 2
            ))
        }
        for h in s.habits {
            docs.append(SemanticDoc(
                type: ContentType.habit.rawValue, id: h.id, title: h.title,
                date: h.updatedAt,
                text: h.title + "\n" + h.notes,
                chunkCap: 1
            ))
        }

        // Custom-tab records: flatten "Field: value" lines using the owning
        // tab's field definitions; the agent-facing type is the tab slug
        // (same identifier search_items / get_item use).
        if !s.customRecords.isEmpty {
            var tabById: [UUID: CustomTabDefinition] = [:]
            for tab in s.customTabs { tabById[tab.id] = tab }
            for record in s.customRecords {
                guard let tab = tabById[record.tabId] else { continue }
                var fieldById: [UUID: CustomFieldDefinition] = [:]
                for collection in tab.collections {
                    for field in collection.fields { fieldById[field.id] = field }
                }
                var lines: [String] = []
                var title = ""
                let ordered = record.values.sorted { lhs, rhs in
                    (fieldById[lhs.key]?.sortIndex ?? .max) < (fieldById[rhs.key]?.sortIndex ?? .max)
                }
                for (fieldId, value) in ordered {
                    guard let field = fieldById[fieldId] else { continue }
                    let rendered: String
                    switch value {
                    case .text(let t): rendered = t
                    case .url(let u): rendered = u
                    case .number(let n): rendered = String(n)
                    case .bool(let b): rendered = b ? "yes" : "no"
                    case .date(let d): rendered = Self.recordDateFormatter.string(from: d)
                    case .optionIds(let ids):
                        rendered = ids.compactMap { id in
                            field.options.first(where: { $0.id == id })?.label
                        }.joined(separator: ", ")
                    }
                    if rendered.isEmpty { continue }
                    if title.isEmpty, case .text = value { title = rendered }
                    lines.append("\(field.name): \(rendered)")
                }
                guard !lines.isEmpty else { continue }
                docs.append(SemanticDoc(
                    type: tab.slug, id: record.id,
                    title: title.isEmpty ? "\(tab.name) record" : title,
                    date: record.updatedAt,
                    text: tab.name + "\n" + lines.joined(separator: "\n"),
                    chunkCap: 3
                ))
            }
        }

        for m in s.agentMemories {
            docs.append(SemanticDoc(
                type: "memory", id: m.id,
                title: String(m.content.prefix(64)),
                date: m.updatedAt,
                text: "[\(m.category.rawValue)] " + m.content,
                chunkCap: 2
            ))
        }

        return docs
    }
}
