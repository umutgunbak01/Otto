import Foundation

/// Deterministic intent matcher that runs before the user's turn is sent to
/// Claude. Handles a small set of "side-effect first, summary second" flows
/// where we don't want to rely on the model deciding to call `open_url` — the
/// page opens (or state changes) immediately, then Claude just summarizes.
///
/// Add new intents as cases on `Action`. Keep detection cheap — substring or
/// small-regex matching on lower-cased input. Anything ambiguous should fall
/// through to the model.
enum IntentRouter {

    enum Action: Equatable {
        /// Open worldmonitor.app, ask Claude for a crisp spoken world-status summary.
        case worldMonitor
        /// Open a lofi / focus music stream in the browser.
        case playFocusMusic
        /// Open the user's recent Figma files.
        case openFigma
        /// Silence non-critical notifications for N minutes.
        case silenceFor(minutes: Int)
        /// Compile a spoken brief about the named person from Otto data.
        case briefPerson(name: String)
        /// Capture the active display and have Claude describe what's on it.
        case screenVision
    }

    // MARK: - Canonical URLs

    static let worldMonitorURL = URL(string: "https://www.worldmonitor.app/")!
    /// Lofi Girl's ever-playing focus stream — good default until we wire a
    /// user-settable pinned URL.
    static let focusMusicURL = URL(string: "https://www.youtube.com/watch?v=jfKfPfyJRdk")!
    static let figmaURL = URL(string: "https://www.figma.com/files/recent")!

    // MARK: - Phrase triggers

    /// World-monitor is a substring match — multiple phrasings route here.
    /// "brief me" intentionally removed: bare "brief me" was ambiguous with
    /// `briefPerson`; user says "what's going on in the world" etc. for this.
    private static let worldMonitorTriggers: [String] = [
        "world monitor",
        "what's going on in the world",
        "whats going on in the world",
        "what's happening in the world",
        "whats happening in the world",
        "monitor the situation",
        "monitor the world",
        "morning briefing",
        "catch me up on the news",
        "catch me up on news",
        "what's the news",
        "whats the news"
    ]

    private static let focusMusicTriggers: [String] = [
        "play focus music", "focus music", "put on lofi", "play some lofi",
        "play lofi", "play my focus playlist"
    ]

    private static let figmaTriggers: [String] = [
        "open figma", "my figma", "open my figma", "figma project"
    ]

    private static let screenVisionTriggers: [String] = [
        "what's on my screen", "whats on my screen",
        "what am i looking at",
        "read my screen", "summarize my screen", "describe my screen",
        "tell me about my screen"
    ]

    /// Things that match "brief me on X" regex but shouldn't be treated as a
    /// person. Keeps briefPerson from eating world-news style asks.
    private static let nonPersonBriefSubjects: Set<String> = [
        "the news", "news", "the world", "the situation", "today",
        "everything", "yourself", "me", "myself"
    ]

    // MARK: - Detection

    /// Order matters: more-specific patterns (regex with captured args) come
    /// before loose substring matches, so "brief me on Sarah" resolves to
    /// `.briefPerson("Sarah")` rather than being chewed by a broader trigger.
    static func detect(userInput: String) -> Action? {
        let lower = userInput.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. "brief me on <name>" / "pull up <name>['s file]"
        if let name = captureBriefPersonName(from: lower) {
            return .briefPerson(name: name)
        }

        // 2. "silence for N minutes" / "mute for N min"
        if let minutes = captureSilenceMinutes(from: lower) {
            return .silenceFor(minutes: minutes)
        }

        // 3. Screen vision
        for t in screenVisionTriggers where lower.contains(t) {
            return .screenVision
        }

        // 4. Focus music
        for t in focusMusicTriggers where lower.contains(t) {
            return .playFocusMusic
        }

        // 5. Figma
        for t in figmaTriggers where lower.contains(t) {
            return .openFigma
        }

        // 6. World monitor (broadest)
        for t in worldMonitorTriggers where lower.contains(t) {
            return .worldMonitor
        }

        return nil
    }

    // MARK: - Apply (side-effects)

    /// Perform the deterministic side-effect for a detected action. Async
    /// because `.screenVision` has to go through ScreenCaptureKit. All other
    /// cases complete synchronously; callers just `await` once.
    static func apply(_ action: Action, appState: AppState) async {
        switch action {
        case .worldMonitor:
            openURL(worldMonitorURL)
        case .playFocusMusic:
            openURL(focusMusicURL)
        case .openFigma:
            openURL(figmaURL)
        case .silenceFor(let minutes):
            appState.quietUntil = Date().addingTimeInterval(TimeInterval(minutes * 60))
        case .briefPerson:
            break // no side-effect; Claude does the compilation via contextNote
        case .screenVision:
            #if os(macOS)
            do {
                let url = try await ScreenCaptureService.shared.captureMainDisplay()
                appState.pendingScreenshotPath = url.path
            } catch {
                NSLog("[IntentRouter] screen capture failed: \(error.localizedDescription)")
            }
            #endif
        }
    }

    // MARK: - Context note

    /// Text appended to the user's message so Claude knows what the app has
    /// already done and what it should do in response. Keeps the original
    /// user text intact above the bracketed note.
    static func contextNote(for action: Action) -> String {
        switch action {
        case .worldMonitor:
            return """

            [Side-effect already done by the app: \(worldMonitorURL.absoluteString) has been opened in the user's browser. Do NOT call `open_url` again. Use WebFetch on that URL to read the top stories, then give a crisp 2–3 sentence spoken summary. Keep it voice-friendly — no bullet lists, no headline dumps.]
            """

        case .playFocusMusic:
            return """

            [Side-effect already done by the app: the focus music stream has been opened in the user's browser. Do NOT call `open_url` again. Just confirm in one short voice-friendly sentence (e.g. "Playing, boss.").]
            """

        case .openFigma:
            return """

            [Side-effect already done by the app: the user's recent Figma files list has been opened in the browser. Do NOT call `open_url` again. Just confirm in one short sentence.]
            """

        case .silenceFor(let minutes):
            return """

            [Side-effect already done by the app: notifications are silenced for the next \(minutes) minutes. Just confirm in one short sentence (e.g. "Silencing for \(minutes) minutes, boss.").]
            """

        case .briefPerson(let name):
            return """

            [User wants a spoken brief about "\(name)". Use `search_items` with types=["email","meeting","connection","note"] and query="\(name)" to gather everything Otto knows. Then synthesize a 2–3 sentence voice-friendly brief covering: who they are (role/company from Connection if found), the most recent interaction (email or meeting), and anything actionable. No bullets, no long lists.]
            """

        case .screenVision:
            return """

            [A screenshot of the user's main display has been saved to `./screenshot.png` in your current working directory. Use the `Read` tool on that path — it will load the image as visual input. Then give a crisp 2–3 sentence spoken summary: what's the user doing / looking at, and one useful observation. Voice-friendly, no bullets. Do NOT call `open_url` or any other tool; just Read and summarize.]
            """
        }
    }

    // MARK: - Regex helpers

    private static func captureBriefPersonName(from lower: String) -> String? {
        // "brief me on <name>"
        if let match = regexCapture(#"\bbrief\s+me\s+on\s+(.+)$"#, in: lower) {
            return sanitizeBriefName(match)
        }
        // "pull up <name>['s] file" / "pull up <name>'s info"
        if let match = regexCapture(#"\bpull\s+up\s+(.+?)(?:'s)?\s+(?:file|info|details|card)\b"#, in: lower) {
            return sanitizeBriefName(match)
        }
        return nil
    }

    private static func sanitizeBriefName(_ raw: String) -> String? {
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".?!,"))
        guard !trimmed.isEmpty, !nonPersonBriefSubjects.contains(trimmed) else {
            return nil
        }
        return trimmed
    }

    private static func captureSilenceMinutes(from lower: String) -> Int? {
        // "silence for 25 minutes" / "mute notifications for 10 min" / "quiet for 5"
        guard let match = regexCapture(
            #"(?:silence|mute|quiet)(?:\s+(?:everything|all|notifications?|stuff|me))?\s+for\s+(\d+)"#,
            in: lower
        ) else { return nil }
        return Int(match)
    }

    /// Returns the first capture group of `pattern` matched anywhere in `text`.
    private static func regexCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges >= 2,
              let captureRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captureRange])
    }
}
