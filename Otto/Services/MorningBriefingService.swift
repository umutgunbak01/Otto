import Foundation

/// Controls the "first clap of the day" status report. Stateless — persists a
/// single UserDefaults timestamp so the briefing fires once per calendar day.
///
/// The greeting prompt is handed to `VoiceSessionManager.start` as a synthetic
/// user turn; Claude runs it through the normal tool loop (search_items +
/// WebSearch + WebFetch) and the answer streams into TTS.
enum MorningBriefingService {

    private static let lastShownKey = "morning.briefing.lastShownDate"

    /// `true` if no briefing has fired yet today (user's local calendar day).
    static func shouldShowToday() -> Bool {
        let today = Calendar.current.startOfDay(for: Date())
        guard let last = UserDefaults.standard.object(forKey: lastShownKey) as? Date else {
            return true
        }
        return !Calendar.current.isDate(last, inSameDayAs: today)
    }

    static func markShownToday() {
        UserDefaults.standard.set(Date(), forKey: lastShownKey)
    }

    /// Resets the daily marker so the next wake fires a fresh briefing.
    /// Not called in v1; exposed for manual debugging / a future "run again" button.
    static func resetForTesting() {
        UserDefaults.standard.removeObject(forKey: lastShownKey)
    }

    /// Synthetic user-turn text that tells Otto what to compose.
    ///
    /// Phrasing carefully avoids the `IntentRouter` triggers ("morning briefing",
    /// "world monitor", "catch me up on the news") — those would fire
    /// side-effects like opening worldmonitor.app in the browser, which we
    /// don't want for a voice-only greeting.
    static func composeGreetingPrompt() -> String {
        return """
        Compose my status report for today, boss. Voice-friendly — 2 to 4 spoken sentences total, no bullets, no headers. Cover exactly these, in this order:
          (1) Meetings today: how many I have, and the title + time of the very next upcoming one. Use `search_items` with `types=["meeting"]` and a `since` of today's start to get them.
          (2) My single most overdue or urgent todo. Use `search_items` with `types=["todo"]`, `include_completed=false`, `sort="due_soonest"`. Mention just the most important one.
          (3) Today's weather in my city (inferable from my timezone in the system context). Use `WebSearch` — query "weather today in <city>".
          (4) One top world-news headline. Use `WebFetch` on https://www.worldmonitor.app/ and pick the single most significant story.
        Open with "Good morning, boss." then lead with what matters most. Keep it tight — this is spoken, not written.
        """
    }
}
