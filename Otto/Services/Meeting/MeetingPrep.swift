import Foundation

/// Pre-meeting context the user provides in the notch prep panel.
///
/// Every field is optional — a meeting still analyzes fine when this is left
/// blank. The prep is usually filled *while recording* (the notch panel opens
/// the moment recording starts), so it is threaded through
/// `MeetingRecorder.Context` and read at analysis time, not baked in at start.
struct MeetingPrep: Equatable {
    /// Names the user typed in so the analysis can attribute "who said what"
    /// even when there's no calendar invite to resolve against.
    var participantNames: [String] = []
    /// Why the meeting is happening — free text ("investor intro for Vialoom").
    var purpose: String = ""
    /// Anything the user wants Otto to pay special attention to in the notes.
    var focusPoints: String = ""
    /// Which note template shapes the generated notes.
    var noteStyle: MeetingNoteStyle = .general

    var isEmpty: Bool {
        participantNames.isEmpty
            && purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && focusPoints.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && noteStyle == .general
    }
}

/// A small fixed set of note "templates" that shape how the analysis agent
/// structures its notes. Otto suggests one from the meeting purpose (the single
/// "smart" step in the otherwise-fixed prep flow); the user can override it.
///
/// Kept as a lightweight enum rather than a persisted model — the built-in set
/// covers the common cases and nothing new needs storing.
enum MeetingNoteStyle: String, CaseIterable, Equatable {
    case general
    case oneOnOne
    case investor
    case sales
    case teamSync
    case interview

    /// Turkish label shown in the prep panel's template picker.
    var displayName: String {
        switch self {
        case .general:   return "Genel"
        case .oneOnOne:  return "Birebir (1:1)"
        case .investor:  return "Yatırımcı Görüşmesi"
        case .sales:     return "Satış / Müşteri"
        case .teamSync:  return "Ekip Senkron"
        case .interview: return "Mülakat"
        }
    }

    /// English guidance appended to the analysis prompt to shape the note
    /// sections. Heading names are given in English; the LANGUAGE rules in
    /// MeetingAnalysisService.analysisSystemPrompt tell the agent to render
    /// them in whatever the primary notes language is (the user's
    /// MeetingNotesLanguageSettings choice).
    var promptGuidance: String {
        switch self {
        case .general:
            return "General meeting — organize the notes under natural ## topic headings."
        case .oneOnOne:
            return "1:1 meeting — use ## headings for Updates, Blockers, Feedback, and Next steps."
        case .investor:
            return "Investor meeting — use ## headings for Company/traction, Questions asked, Objections/concerns, Asks & next steps, and call out any figures mentioned (round size, valuation, key metrics)."
        case .sales:
            return "Sales/customer call — use ## headings for Need/problem, Product fit, Objections, Pricing, and Next steps."
        case .teamSync:
            return "Team sync — use one ## heading per person or workstream, plus Decisions and Blockers."
        case .interview:
            return "Interview — use ## headings for Background/experience, Strengths, Concerns, and Assessment/recommendation."
        }
    }

    /// Cheap offline suggestion from the meeting purpose text — the one "smart"
    /// touch in the fixed prep flow. Matches Turkish and English keywords.
    static func suggest(purpose: String) -> MeetingNoteStyle {
        let p = purpose.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { p.contains($0) } }

        if has(["yatırım", "yatirim", "investor", "tohum", "seed", "pre-seed", "vc", "melek", "fon", "valuation", "değerleme"]) {
            return .investor
        }
        if has(["mülakat", "mulakat", "interview", "aday", "işe alım", "ise alim", "candidate", "hiring", "röportaj"]) {
            return .interview
        }
        if has(["satış", "satis", "müşteri", "musteri", "sales", "customer", "demo", "lead", "teklif", "sözleşme", "sozlesme"]) {
            return .sales
        }
        if has(["birebir", "1:1", "1-1", "one on one", "one-on-one", "bire bir"]) {
            return .oneOnOne
        }
        if has(["sync", "senkron", "standup", "stand-up", "sprint", "haftalık", "haftalik", "ekip", "team", "toplantısı"]) {
            return .teamSync
        }
        return .general
    }
}
