import Foundation

#if os(macOS)
import AppKit

/// Tiny helper for playing short UI chimes. Uses macOS system sounds for v1;
/// if a matching named file is found in the app bundle (e.g. `wake.wav`), that
/// wins over the system sound — lets us swap tones later without code changes.
enum Sounds {

    enum Tone: String {
        case wake          // otto is awake / listening
        case taskComplete  // finished a concrete action (created a todo, etc.)
        case error         // something went wrong
    }

    static func play(_ tone: Tone) {
        if let bundled = NSSound(named: NSSound.Name(tone.rawValue)) {
            bundled.play()
            return
        }
        if let system = NSSound(named: NSSound.Name(tone.systemFallback)) {
            system.play()
        }
    }
}

private extension Sounds.Tone {
    /// Built-in macOS sound used if no custom asset is bundled under `rawValue`.
    /// Names here are the ones shipped at `/System/Library/Sounds/`.
    var systemFallback: String {
        switch self {
        case .wake:         return "Tink"   // short, bright, non-intrusive
        case .taskComplete: return "Glass"  // crisp confirmation
        case .error:        return "Funk"   // classic failure bleat
        }
    }
}
#else
// iOS stub so cross-platform call sites compile. No-op.
enum Sounds {
    enum Tone { case wake, taskComplete, error }
    static func play(_ tone: Tone) {}
}
#endif
