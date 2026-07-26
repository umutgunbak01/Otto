import Foundation
import CoreGraphics

// MARK: - Creative canvas data model
//
// The Creative tab is an infinite node canvas: fal.ai model endpoints become
// nodes, their inputs/outputs become typed ports, and edges carry values
// between them. Workflows persist as standalone JSON documents (one file per
// workflow under Application Support/Otto/Creative/) — deliberately outside
// `OttoDataStore`, whose save-everything-per-mutation write path is too heavy
// for drag-a-node-at-60fps canvas interactions.

// MARK: - JSONValue conveniences
//
// The canvas reuses the app-wide `JSONValue` (ChatModels.swift) for node
// params and run results; these accessors make graph plumbing terse.

extension JSONValue {
    var stringValue: String? { if case .string(let s) = self { return s }; return nil }

    var doubleValue: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    var isNull: Bool { if case .null = self { return true }; return false }

    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// Compact human-readable rendering for previews/error strings.
    var displayString: String {
        switch self {
        case .string(let s): return s
        case .number(let n):
            if n.truncatingRemainder(dividingBy: 1) == 0, abs(n) < 1e15 {
                return String(Int64(n))
            }
            return String(n)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .array, .object:
            if let data = try? JSONEncoder().encode(self), let s = String(data: data, encoding: .utf8) {
                return s
            }
            return "…"
        }
    }
}

// MARK: - Port typing

/// Semantic type of a node port. Drives pin colors, editor selection, and
/// connection-time value coercion.
enum CreativePortKind: String, Codable, Hashable {
    case string
    case number
    case boolean
    case enumeration
    case image
    case video
    case audio
    case file
    case object
    case any

    var isMedia: Bool {
        switch self {
        case .image, .video, .audio, .file: return true
        default: return false
        }
    }

    /// Strict "does this pairing make sense" relation — drives which pins
    /// light up (and are droppable) while dragging a wire. Media only pairs
    /// with the same media kind (or the generic file bucket), text with
    /// text, numbers with numbers: an `images` output should guide toward
    /// `image_url(s)`, never `prompt`.
    func sensiblyAccepts(_ source: CreativePortKind) -> Bool {
        if self == .any || source == .any { return true }
        if self == source { return true }
        switch (source, self) {
        // The generic file bucket pairs with every concrete media kind.
        case (.image, .file), (.video, .file), (.audio, .file),
             (.file, .image), (.file, .video), (.file, .audio):
            return true
        // Enum values are strings (model ids, size presets) — allow them
        // into free-text inputs, but not free text into a fixed enum.
        case (.enumeration, .string):
            return true
        case (.object, .object):
            return true
        default:
            return false
        }
    }

    /// Loose compatibility check — the hard floor `connect()` enforces. The
    /// runner still coerces at execution time; this only prevents
    /// obviously-wrong wires.
    func accepts(_ source: CreativePortKind) -> Bool {
        if self == .any || source == .any { return true }
        if self == source { return true }
        switch (source, self) {
        // Any media/file URL can flow into a generic file slot and vice versa.
        case (.image, .file), (.video, .file), (.audio, .file),
             (.file, .image), (.file, .video), (.file, .audio):
            return true
        // Strings interchange with enums and urls; numbers stringify.
        case (.string, .enumeration), (.enumeration, .string),
             (.string, .image), (.string, .video), (.string, .audio), (.string, .file),
             (.image, .string), (.video, .string), (.audio, .string), (.file, .string),
             (.number, .string), (.string, .number),
             (.object, .string):
            return true
        default:
            return false
        }
    }
}

// MARK: - Model specs (parsed from fal OpenAPI — not persisted per node)

/// One input parameter of a fal endpoint.
struct CreativeParamSpec: Identifiable, Hashable {
    let key: String
    let title: String
    let detail: String?
    let kind: CreativePortKind
    /// True when the param takes an array of the kind (e.g. `image_urls`).
    let isArrayInput: Bool
    let required: Bool
    let defaultValue: JSONValue?
    let enumValues: [String]?
    let minimum: Double?
    let maximum: Double?
    let isInteger: Bool
    let multiline: Bool
    /// Featured params render in the card body; the rest live behind the
    /// "Additional settings" expander.
    let featured: Bool

    var id: String { key }
}

/// One output field of a fal endpoint.
struct CreativePortSpec: Identifiable, Hashable {
    let key: String
    let title: String
    let kind: CreativePortKind
    let isArray: Bool

    var id: String { key }
}

/// Parsed node-facing schema of a fal endpoint.
struct CreativeNodeSpec: Hashable {
    let endpointId: String
    let title: String
    let inputs: [CreativeParamSpec]
    let outputs: [CreativePortSpec]

    func input(_ key: String) -> CreativeParamSpec? {
        inputs.first { $0.key == key }
    }

    func output(_ key: String) -> CreativePortSpec? {
        outputs.first { $0.key == key }
    }
}

/// Registry search result (fal.ai/api/models item, trimmed).
struct CreativeModelSummary: Identifiable, Hashable, Codable {
    let id: String              // endpoint id, e.g. "fal-ai/flux/dev"
    let title: String
    let category: String
    let shortDescription: String
    let thumbnailUrl: String?
}

extension CreativeModelSummary {
    /// Endpoint-path segments the registry title doesn't convey. Model
    /// families often ship sibling endpoints under one title — both
    /// `fal-ai/nano-banana-2` and `fal-ai/nano-banana-2/edit` are titled
    /// "Nano Banana 2" — so the variant tail is the only thing telling
    /// text-to-image apart from the editor. Nil when the title already says
    /// it (e.g. "Seedance 2 Image to Video").
    var variantHint: String? {
        let comps = id.split(separator: "/")
        guard comps.count >= 3 else { return nil }   // <org>/<family>/<variant…>
        let titleFold = Self.fold(title)
        let missing = comps.dropFirst(2).filter { comp in
            let tokens = comp.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            return !tokens.allSatisfy { raw in
                let token = Self.fold(String(raw))
                if token.isEmpty { return true }
                if titleFold.contains(token) { return true }
                // Version tokens: "v3" is conveyed by a title saying "3.0".
                if token.first == "v", token.count > 1, titleFold.contains(token.dropFirst()) {
                    return true
                }
                return false
            }
        }
        guard !missing.isEmpty else { return nil }
        return missing.joined(separator: "/")
    }

    /// Title with the variant hint folded in — used as the display name in
    /// the library and on node cards so same-titled variants (and generic
    /// registry titles like six endpoints all named "Heygen") read apart:
    /// "Heygen · Avatar4 Image to Video", "Nano Banana 2 · Edit".
    var disambiguatedTitle: String {
        guard let hint = variantHint else { return title }
        let lowercaseWords: Set<String> = ["to", "of", "and", "by", "the"]
        let acronyms: Set<String> = ["tts", "llm", "hd", "api", "sfx", "sdxl"]
        let words = hint
            .replacingOccurrences(of: "/", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .enumerated()
            .map { index, word -> String in
                let lower = word.lowercased()
                if acronyms.contains(lower) { return lower.uppercased() }
                if index > 0, lowercaseWords.contains(lower) { return lower }
                return lower.prefix(1).uppercased() + lower.dropFirst()
            }
        return "\(title) · \(words.joined(separator: " "))"
    }

    private static func fold(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

// MARK: - Media

enum CreativeMediaKind: String, Codable, Hashable {
    case image, video, audio, file

    static func from(fileExtension ext: String) -> CreativeMediaKind {
        switch ext.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "bmp", "avif":
            return .image
        case "mp4", "mov", "m4v", "webm", "avi", "mkv", "mpg", "mpeg":
            return .video
        case "mp3", "wav", "m4a", "aac", "flac", "ogg", "opus", "aiff":
            return .audio
        default:
            return .file
        }
    }

    var portKind: CreativePortKind {
        switch self {
        case .image: return .image
        case .video: return .video
        case .audio: return .audio
        case .file: return .file
        }
    }
}

/// A user-imported file living in the Creative assets directory. The original
/// bytes stay on disk at original quality; `falURL` caches the CDN copy after
/// the first run that needs it.
struct CreativeMediaAsset: Codable, Hashable {
    var fileName: String        // original display name
    var relativePath: String    // under the Creative assets dir
    var kind: CreativeMediaKind
    var byteSize: Int?
    var falURL: String?
}

// MARK: - Graph

struct CreativeNode: Identifiable, Codable, Hashable {
    enum Kind: String, Codable {
        case model      // a fal endpoint
        case media      // an imported local file
    }

    var id: String              // "node-XXXXXXXXXX", referenced as $node-….port
    var kind: Kind
    var endpointId: String?     // model nodes
    var title: String
    var subtitle: String?
    var thumbnailUrl: String?
    var category: String?
    var position: CGPoint       // world coordinates, top-left of the card
    var params: [String: JSONValue]
    var showAllParams: Bool
    /// When true (and a result exists) the card face shows the result
    /// preview layer instead of the parameter editors. Toggled by the eye
    /// button in the header; auto-enabled when a run completes.
    var showPreview: Bool
    var media: CreativeMediaAsset?
    var lastResult: JSONValue?
    var lastRunAt: Date?
    var lastDuration: Double?

    init(
        id: String = CreativeNode.makeId(),
        kind: Kind,
        endpointId: String? = nil,
        title: String,
        subtitle: String? = nil,
        thumbnailUrl: String? = nil,
        category: String? = nil,
        position: CGPoint = .zero,
        params: [String: JSONValue] = [:],
        showAllParams: Bool = false,
        showPreview: Bool = false,
        media: CreativeMediaAsset? = nil
    ) {
        self.id = id
        self.kind = kind
        self.endpointId = endpointId
        self.title = title
        self.subtitle = subtitle
        self.thumbnailUrl = thumbnailUrl
        self.category = category
        self.position = position
        self.params = params
        self.showAllParams = showAllParams
        self.showPreview = showPreview
        self.media = media
    }

    /// Forward-compatible decoding: newer optional fields default rather than
    /// failing the whole workflow document (same convention as OttoDataStore).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .model
        endpointId = try? c.decodeIfPresent(String.self, forKey: .endpointId)
        title = (try? c.decode(String.self, forKey: .title)) ?? "Node"
        subtitle = try? c.decodeIfPresent(String.self, forKey: .subtitle)
        thumbnailUrl = try? c.decodeIfPresent(String.self, forKey: .thumbnailUrl)
        category = try? c.decodeIfPresent(String.self, forKey: .category)
        position = (try? c.decode(CGPoint.self, forKey: .position)) ?? .zero
        params = (try? c.decode([String: JSONValue].self, forKey: .params)) ?? [:]
        showAllParams = (try? c.decode(Bool.self, forKey: .showAllParams)) ?? false
        showPreview = (try? c.decode(Bool.self, forKey: .showPreview)) ?? false
        media = try? c.decodeIfPresent(CreativeMediaAsset.self, forKey: .media)
        lastResult = try? c.decodeIfPresent(JSONValue.self, forKey: .lastResult)
        lastRunAt = try? c.decodeIfPresent(Date.self, forKey: .lastRunAt)
        lastDuration = try? c.decodeIfPresent(Double.self, forKey: .lastDuration)
    }

    static func makeId() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let suffix = String((0..<10).map { _ in alphabet.randomElement()! })
        return "node-\(suffix)"
    }
}

struct CreativeEdge: Identifiable, Codable, Hashable {
    var id: UUID
    var fromNode: String
    var fromPort: String        // output key on the source ("images", "video", "url", …)
    var toNode: String
    var toParam: String         // input param key on the target

    init(id: UUID = UUID(), fromNode: String, fromPort: String, toNode: String, toParam: String) {
        self.id = id
        self.fromNode = fromNode
        self.fromPort = fromPort
        self.toNode = toNode
        self.toParam = toParam
    }

    /// The reference string shown in connected inputs, mirroring fal's
    /// workflow syntax: `$node-abc123.images`.
    var referenceLabel: String {
        "$\(fromNode).\(fromPort)"
    }
}

struct CreativeWorkflow: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var nodes: [CreativeNode]
    var edges: [CreativeEdge]
    var canvasOffset: CGPoint   // pan, in screen points
    var canvasZoom: CGFloat
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String = "Untitled",
        nodes: [CreativeNode] = [],
        edges: [CreativeEdge] = [],
        canvasOffset: CGPoint = .zero,
        canvasZoom: CGFloat = 1.0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.nodes = nodes
        self.edges = edges
        self.canvasOffset = canvasOffset
        self.canvasZoom = canvasZoom
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? "Untitled"
        nodes = (try? c.decode([CreativeNode].self, forKey: .nodes)) ?? []
        edges = (try? c.decode([CreativeEdge].self, forKey: .edges)) ?? []
        canvasOffset = (try? c.decode(CGPoint.self, forKey: .canvasOffset)) ?? .zero
        canvasZoom = (try? c.decode(CGFloat.self, forKey: .canvasZoom)) ?? 1.0
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
        updatedAt = (try? c.decode(Date.self, forKey: .updatedAt)) ?? Date()
    }

    func node(_ id: String) -> CreativeNode? {
        nodes.first { $0.id == id }
    }

    func edges(into nodeId: String) -> [CreativeEdge] {
        edges.filter { $0.toNode == nodeId }
    }

    func edges(outOf nodeId: String) -> [CreativeEdge] {
        edges.filter { $0.fromNode == nodeId }
    }

    func edge(into nodeId: String, param: String) -> CreativeEdge? {
        edges.first { $0.toNode == nodeId && $0.toParam == param }
    }

    /// IDs of nodes that must produce output before `nodeId` can run.
    func upstreamIds(of nodeId: String) -> Set<String> {
        Set(edges(into: nodeId).map(\.fromNode))
    }

    /// True if adding fromNode→toNode would create a cycle.
    func wouldCycle(from fromNode: String, to toNode: String) -> Bool {
        if fromNode == toNode { return true }
        // Walk upstream from `fromNode`; if we can reach `toNode`, the new
        // edge would close a loop.
        var visited: Set<String> = []
        var stack: [String] = [fromNode]
        while let current = stack.popLast() {
            guard visited.insert(current).inserted else { continue }
            if current == toNode { return true }
            stack.append(contentsOf: upstreamIds(of: current))
        }
        return false
    }
}

// MARK: - Transient run state (not persisted)

enum CreativeRunState: Equatable {
    case idle
    case uploading
    case queued(position: Int?)
    case running
    case succeeded(duration: Double)
    case failed(message: String)
    case skipped(reason: String)

    var isActive: Bool {
        switch self {
        case .uploading, .queued, .running: return true
        default: return false
        }
    }

    var failureMessage: String? {
        if case .failed(let m) = self { return m }
        return nil
    }
}

// MARK: - Port references (canvas geometry bookkeeping)

struct CreativePortRef: Hashable {
    enum Side: Hashable {
        case input
        case output
    }

    var nodeId: String
    var portKey: String
    var side: Side
}
