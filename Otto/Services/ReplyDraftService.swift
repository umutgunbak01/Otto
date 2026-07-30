import Foundation
import Observation

/// Drafts a reply to an email thread in the user's own voice — a background
/// one-shot run over locally assembled context (the thread tail plus a few of
/// the user's real sent messages as style reference). Gmail stays read-only:
/// the draft lands in an editable sheet with copy + open-thread actions,
/// never in the user's outbox.
@MainActor
@Observable
final class ReplyDraftService {
    static let shared = ReplyDraftService()

    enum Phase: Equatable {
        case idle
        case generating
        case ready(String)
        case failed(String)
    }

    /// The email a draft sheet is currently open for (drives `.sheet(item:)`).
    var draftingFor: Email?
    var phase: Phase = .idle

    @ObservationIgnored
    private let sessionKey = UUID()
    @ObservationIgnored
    private var task: Task<Void, Never>?

    private init() {}

    // MARK: - Entry

    func beginDraft(for email: Email, appState: AppState) {
        draftingFor = email
        phase = .generating
        task?.cancel()

        guard OneShotAgentRunner.usableBackend() != nil else {
            phase = .failed("No agent backend signed in — connect Claude, Codex, or Hermes in Settings.")
            return
        }

        let userPrompt = Self.contextPrompt(for: email, appState: appState)
        let key = sessionKey
        task = Task { [weak self, weak appState] in
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
                if Task.isCancelled { return }
                let cleaned = Self.cleanDraft(text)
                self?.phase = cleaned.isEmpty ? .failed("The model returned an empty draft.") : .ready(cleaned)
            } catch {
                if Task.isCancelled { return }
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    func dismiss() {
        task?.cancel()
        task = nil
        draftingFor = nil
        phase = .idle
    }

    // MARK: - Prompts

    private static let systemPrompt = """
    You draft email replies for the user, in the user's own voice. You are given \
    the thread (newest message last) and a few real messages the user previously \
    sent, as style reference — mirror their tone, greeting/sign-off habits, \
    directness, and typical length. Reply in the same language the thread uses.

    CRITICAL: Use ONLY the context provided. Do not call any tools.

    Output the reply BODY ONLY — no subject line, no commentary, no markdown \
    fences, no "Here's a draft". Start directly with the greeting (or first \
    sentence, if the user's style skips greetings). Keep it as short as the \
    thread allows. If the latest message asks something you can't know, leave \
    a [square-bracket placeholder] rather than inventing facts.
    """

    private static func contextPrompt(for email: Email, appState: AppState) -> String {
        var lines: [String] = []

        let selfAddrs = EmailTriageService.selfAddresses(in: appState.emails)

        // Style reference: recent short-ish messages the user actually sent.
        let sentSamples = appState.emails
            .filter { $0.labels.contains("SENT") && !EmailTriageService.isAutomated($0) }
            .sorted { $0.receivedDate > $1.receivedDate }
            .prefix(20)
            .filter { (80...2_500).contains($0.body.count) }
            .prefix(3)
        if !sentSamples.isEmpty {
            lines.append("## How the user writes (real sent messages — style reference only)")
            for sample in sentSamples {
                lines.append("---")
                lines.append(String(SemanticIndexService.normalize(sample.body).prefix(600)))
            }
            lines.append("")
        }

        // The thread, oldest → newest, capped to the last 5 messages.
        let thread = appState.emails
            .filter { $0.threadId == email.threadId }
            .sorted { $0.receivedDate < $1.receivedDate }
            .suffix(5)
        lines.append("## Thread (oldest first)")
        for message in thread {
            let from = EmailTriageService.isFromSelf(message, selfAddrs: selfAddrs) || message.labels.contains("SENT")
                ? "the user"
                : message.displaySender
            lines.append("--- From: \(from) — \(message.receivedDate.formatted(date: .abbreviated, time: .shortened))")
            if message.id == thread.last?.id {
                lines.append("Subject: \(message.subject)")
            }
            lines.append(String(SemanticIndexService.normalize(message.body).prefix(1_400)))
        }

        lines.append("")
        lines.append("Write the user's reply to the latest message above.")
        return lines.joined(separator: "\n")
    }

    /// Strip fences/quotes the model might add despite instructions.
    static func cleanDraft(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            cleaned = cleaned
                .replacingOccurrences(of: #"^```[a-z]*\n?"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\n?```$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
    }
}
