import Foundation
import Observation

/// Generates and caches the "person 360" relationship summary shown at the
/// top of a Network Hub entry: a few sentences of who-this-is-to-you plus
/// open loops and suggested next moves, written by the agent from locally
/// pre-gathered context (touchpoints, email/meeting excerpts, profile).
///
/// One-shot, tool-less by instruction (context is fully assembled here, so
/// the model has nothing to fetch), following the MeetingPrep pattern. The
/// result is cached on the entry itself (`aiSummary` + `aiSummaryGeneratedAt`)
/// and refreshed when new touchpoints arrive or the cache ages out.
@MainActor
@Observable
final class PersonDossierService {
    static let shared = PersonDossierService()

    /// Entry ids with a generation in flight — drives per-card spinners.
    private(set) var generating: Set<UUID> = []
    /// Last error per entry (cleared on the next successful run).
    private(set) var lastError: [UUID: String] = [:]

    @ObservationIgnored
    private let sessionKey = UUID()

    private static let maxCacheAge: TimeInterval = 14 * 24 * 3600

    private init() {}

    // MARK: - Staleness

    /// True when the entry has no summary, the summary predates the newest
    /// touchpoint, or it's simply old.
    func isStale(_ entry: NetworkEntry, newestTouchpoint: Date?) -> Bool {
        guard let generated = entry.aiSummaryGeneratedAt, entry.aiSummary != nil else { return true }
        if let newest = newestTouchpoint, newest > generated { return true }
        return Date().timeIntervalSince(generated) > Self.maxCacheAge
    }

    /// Kick off a background refresh if one isn't already running.
    func refreshIfStale(entry: NetworkEntry, touchpoints: [Touchpoint], appState: AppState) {
        guard isStale(entry, newestTouchpoint: touchpoints.first?.date) else { return }
        generate(entry: entry, touchpoints: touchpoints, appState: appState)
    }

    // MARK: - Generation

    func generate(entry: NetworkEntry, touchpoints: [Touchpoint], appState: AppState) {
        guard !generating.contains(entry.id) else { return }
        guard OneShotAgentRunner.usableBackend() != nil else {
            lastError[entry.id] = "No agent backend signed in."
            return
        }

        generating.insert(entry.id)
        lastError[entry.id] = nil

        let userPrompt = Self.contextPrompt(entry: entry, touchpoints: touchpoints, appState: appState)
        let key = sessionKey

        Task { [weak self, weak appState] in
            defer { self?.generating.remove(entry.id) }
            guard let appState else { return }
            do {
                guard let backend = OneShotAgentRunner.usableBackend() else { return }
                let text = try await OneShotAgentRunner.run(
                    backend: backend,
                    sessionKey: key,
                    userPrompt: userPrompt,
                    systemPrompt: Self.systemPrompt,
                    executor: OttoToolExecutor(appState: appState)
                )
                let summary = Self.parseSummary(text)
                guard !summary.isEmpty else {
                    self?.lastError[entry.id] = "The model returned an empty summary."
                    return
                }
                // Re-read the live row — the user may have edited fields
                // while generation ran; only the summary columns change here.
                guard var live = appState.networkEntries.first(where: { $0.id == entry.id }) else { return }
                live.aiSummary = summary
                live.aiSummaryGeneratedAt = Date()
                await appState.updateNetworkEntry(live)
            } catch {
                self?.lastError[entry.id] = error.localizedDescription
            }
        }
    }

    // MARK: - Prompts

    private static let systemPrompt = """
    You write relationship dossiers for the user's personal CRM. You are given \
    everything known about one person: profile fields, notes, and their recent \
    interaction history (emails, meetings, DMs, calendar).

    CRITICAL: Use ONLY the context provided in the message. Do not call any tools.

    Respond with STRICT JSON only — no markdown fences, no prose outside the JSON:
    {
      "summary": "2-4 sentences: who this person is to the user, the state of the relationship, and what's currently in motion. Concrete, grounded in the interaction history — never generic filler.",
      "open_loops": ["unresolved threads: unanswered asks, promised intros, pending decisions — max 3, [] if none"],
      "suggested_next": ["1-2 concrete, low-effort next moves grounded in the history (\\"reply to their question about X\\", \\"congratulate on Y\\") — [] if nothing sensible"]
    }
    Write in the user's working language (match the language of the interaction history; default to English).
    """

    private static func contextPrompt(entry: NetworkEntry, touchpoints: [Touchpoint], appState: AppState) -> String {
        var lines: [String] = []
        lines.append("Write the relationship dossier for this person.")
        lines.append("")
        lines.append("## Person")
        lines.append("Name: \(entry.name.isEmpty ? "(org) " + entry.company : entry.name)")
        if !entry.displayInfo.isEmpty { lines.append("Role: \(entry.displayInfo)") }
        if !entry.industry.isEmpty { lines.append("Industry: \(entry.industry)") }
        if !entry.location.isEmpty { lines.append("Location: \(entry.location)") }
        lines.append("Relationship closeness: \(entry.closeness.label)")
        if let cadence = entry.followUpCadence { lines.append("Keep-in-touch cadence: \(cadence.label)") }
        if let last = entry.lastContactedAt {
            lines.append("Last contact: \(dayFormatter.string(from: last))")
        }
        if !entry.notes.isEmpty { lines.append("User's notes: \(String(entry.notes.prefix(600)))") }

        if let profile = entry.profile, !profile.isEmpty {
            lines.append("")
            lines.append("## LinkedIn")
            if !profile.headline.isEmpty { lines.append("Headline: \(profile.headline)") }
            if !profile.summary.isEmpty { lines.append("Summary: \(String(profile.summary.prefix(500)))") }
            for experience in profile.experiences.prefix(3) {
                lines.append("- \(experience.title) at \(experience.company) (\(experience.dateRange))")
            }
        }

        let linkedCompanies = appState.companies.filter { $0.linkedNetworkEntryIds.contains(entry.id) }
        if !linkedCompanies.isEmpty {
            lines.append("")
            lines.append("## Linked companies (user's CRM)")
            for company in linkedCompanies.prefix(3) {
                var line = "- \(company.name)"
                if company.isCustomer { line += " (customer)" }
                if !company.notes.isEmpty { line += ": \(String(company.notes.prefix(200)))" }
                lines.append(line)
            }
        }

        lines.append("")
        lines.append("## Interaction history (newest first)")
        if touchpoints.isEmpty {
            lines.append("No recorded interactions.")
        }
        let emailById = Dictionary(uniqueKeysWithValues: appState.emails.map { ($0.id, $0) })
        let meetingById = Dictionary(uniqueKeysWithValues: appState.meetings.map { ($0.id, $0) })
        let dmById = Dictionary(uniqueKeysWithValues: appState.xDirectMessages.map { ($0.id, $0) })

        for touchpoint in touchpoints.prefix(12) {
            let day = dayFormatter.string(from: touchpoint.date)
            var line = "- [\(day)] \(touchpoint.kind.label): \(touchpoint.title)"
            switch touchpoint.kind {
            case .email:
                if let id = touchpoint.sourceId, let email = emailById[id] {
                    let direction = email.labels.contains("SENT") ? "from user" : "from \(email.displaySender)"
                    line += " (\(direction)) — \(String(SemanticIndexService.normalize(email.body).prefix(350)))"
                }
            case .meeting:
                if let id = touchpoint.sourceId, let meeting = meetingById[id] {
                    let gist = meeting.overview.isEmpty ? meeting.content : meeting.overview
                    line += " — \(String(SemanticIndexService.normalize(gist).prefix(350)))"
                }
            case .dm:
                if let id = touchpoint.sourceId, let dm = dmById[id] {
                    line += " — \(String(dm.text.prefix(200)))"
                }
            case .calendar:
                break
            }
            lines.append(line)
        }

        return lines.joined(separator: "\n")
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    // MARK: - Parsing

    private struct Payload: Decodable {
        var summary: String?
        var openLoops: [String]?
        var suggestedNext: [String]?

        enum CodingKeys: String, CodingKey {
            case summary
            case openLoops = "open_loops"
            case suggestedNext = "suggested_next"
        }
    }

    /// Compose the cached display text: summary paragraph, then labeled
    /// bullet groups. Falls back to raw text when the JSON doesn't parse
    /// (still useful, never blank-on-success).
    static func parseSummary(_ text: String) -> String {
        guard let data = OneShotAgentRunner.jsonSlice(of: text),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var parts: [String] = []
        if let summary = payload.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            parts.append(summary)
        }
        let loops = (payload.openLoops ?? []).filter { !$0.isEmpty }
        if !loops.isEmpty {
            parts.append("Open loops:\n" + loops.map { "• \($0)" }.joined(separator: "\n"))
        }
        let next = (payload.suggestedNext ?? []).filter { !$0.isEmpty }
        if !next.isEmpty {
            parts.append("Next:\n" + next.map { "• \($0)" }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }
}
