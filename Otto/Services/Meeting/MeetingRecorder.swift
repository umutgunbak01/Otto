import Foundation
import AVFoundation
import CoreAudio
import Observation
import AppKit

/// Records a meeting as two labeled audio streams and builds a timestamped
/// transcript out of them:
///
///   - "Me"   — the user's mic (`MicCapture`, same pipeline as voice mode)
///   - "Them" — system audio via `SystemAudioTap` (other participants)
///
/// Each stream runs through its own `VoiceActivityDetector`; finished
/// utterances are WAV-encoded and transcribed with the existing fal Scribe
/// endpoint, then merged into one timeline ordered by utterance start time.
/// The transcript is spilled to `~/.otto/meeting_transcripts/` after every
/// line so a crash mid-meeting loses nothing.
///
/// All mutable state is touched on the main actor (audio callbacks hop, same
/// pattern as `WakeWordService`).
@Observable
final class MeetingRecorder: @unchecked Sendable {

    enum StopReason: String {
        case user = "stopped manually"
        case micReleased = "meeting app released the mic"
        case disabled = "meeting detection disabled"
    }

    struct Context {
        var appName: String
        var calendarEvent: CalendarEvent?

        var displayTitle: String {
            calendarEvent?.title ?? "Meeting (\(appName))"
        }
    }

    struct TranscriptLine {
        let at: Date
        let speaker: String   // "Me" | "Them"
        let text: String
    }

    // MARK: - Tunables

    /// Minimum transcript length to bother analyzing. Recording only starts
    /// by explicit user action, so there's no duration floor — even a short
    /// capture becomes a note as long as something was actually said. This
    /// only filters captures where STT produced essentially nothing (mic
    /// check, instant stop, all-silence).
    private let minAnalysisCharacters = 80
    /// How long `stop()` waits for in-flight Scribe calls before finalizing.
    private let sttDrainTimeout: TimeInterval = 20

    /// Fires on the main actor once recording has actually begun — may be
    /// delayed past `start()` when mic permission is requested first.
    @ObservationIgnored var onStarted: (() -> Void)?

    // MARK: - Observable state

    private(set) var isRecording = false
    private(set) var startedAt: Date?
    private(set) var lineCount = 0
    /// False when the system-audio tap couldn't start (permission declined) —
    /// recording continues mic-only and the banner can hint at it.
    private(set) var systemAudioAvailable = true

    // MARK: - Dependencies

    private let mic = MicCapture()
    private let micVAD = VoiceActivityDetector(tuning: .meeting)
    private let tap = SystemAudioTap()
    private let tapVAD = VoiceActivityDetector(tuning: .meeting)
    private let falAI = FalAIService.shared
    private weak var appState: AppState?

    // MARK: - Session state (main actor)

    private var context: Context?
    private var lines: [TranscriptLine] = []
    private var pendingSTT = 0
    private var spillURL: URL?

    init() {
        mic.onBuffer = { [weak self] buf in
            Task { @MainActor in
                self?.trackLevel(buffer: buf, isMic: true)
                self?.micVAD.process(buffer: buf)
            }
        }
        tap.onBuffer = { [weak self] buf in
            Task { @MainActor in
                self?.trackLevel(buffer: buf, isMic: false)
                self?.tapVAD.process(buffer: buf)
            }
        }
        micVAD.onUtterance = { [weak self] wav in
            Task { @MainActor in self?.transcribe(wav: wav, speaker: "Me") }
        }
        tapVAD.onUtterance = { [weak self] wav in
            Task { @MainActor in self?.transcribe(wav: wav, speaker: "Them") }
        }
    }

    func configure(appState: AppState) {
        self.appState = appState
    }

    // MARK: - Start

    @MainActor
    func start(context: Context) {
        guard !isRecording else { return }

        guard MicCapture.isAuthorized else {
            Task { [weak self] in
                let granted = await MicCapture.requestPermission()
                if granted { await MainActor.run { self?.start(context: context) } }
                else { NSLog("[MeetingRec] mic permission denied — cannot record") }
            }
            return
        }

        // The wake-word listener holds its own mic tap while Otto is
        // backgrounded (which it will be, mid-meeting). Stop it for the
        // duration; the coordinator restarts it after stop().
        appState?.wakeWord.stop()

        self.context = context
        lines = []
        lineCount = 0
        pendingSTT = 0
        micVAD.reset()
        tapVAD.reset()
        prepareSpillFile(title: context.displayTitle)

        NSLog("[MeetingRec] default input device: %@", Self.defaultInputDeviceName() ?? "(unknown)")

        // Mic FIRST, tap second. Creating the tap's aggregate device churns
        // the HAL device list; an AVAudioEngine brought up during that churn
        // has been observed binding to a wedged input that delivers pure
        // digital silence for the whole session.
        do {
            try mic.start()
        } catch {
            NSLog("[MeetingRec] mic start failed: %@", error.localizedDescription)
            return
        }

        do {
            try tap.start()
            systemAudioAvailable = true
        } catch {
            systemAudioAvailable = false
            NSLog("[MeetingRec] system-audio tap unavailable, recording mic only: %@", error.localizedDescription)
        }
        NSLog("[MeetingRec] default input device after tap start: %@", Self.defaultInputDeviceName() ?? "(unknown)")

        isRecording = true
        startedAt = Date()
        MenuBarController.shared.refresh()
        NSLog("[MeetingRec] recording started — %@", context.displayTitle)
        onStarted?()
    }

    // MARK: - Stop

    @MainActor
    func stop(reason: StopReason) async {
        guard isRecording else { return }
        let started = startedAt ?? Date()

        NSLog("[MeetingRec] default input device at stop: %@", Self.defaultInputDeviceName() ?? "(unknown)")
        mic.stop()
        tap.stop()
        micVAD.reset()
        tapVAD.reset()
        isRecording = false
        MenuBarController.shared.refresh()
        // Placeholder row in the Meetings tab from this moment until the
        // analyzed Meeting lands (or the capture turns out too short).
        MeetingAnalysisService.shared.beginPending(title: context?.displayTitle ?? "Meeting")
        NSLog("[MeetingRec] recording stopped (%@) — waiting for %d in-flight transcriptions", reason.rawValue, pendingSTT)

        // Let in-flight Scribe calls land so the tail of the meeting isn't lost.
        let deadline = Date().addingTimeInterval(sttDrainTimeout)
        while pendingSTT > 0 && Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        let duration = Date().timeIntervalSince(started)
        let transcript = transcriptText()
        let ctx = context
        context = nil
        startedAt = nil

        // Hand the mic back to the wake-word listener if it should be running.
        if let appState,
           UserDefaults.standard.object(forKey: WakeWordSettings.enabledKey) as? Bool ?? WakeWordSettings.defaultEnabled,
           !NSApp.isActive {
            appState.wakeWord.start()
        }

        guard transcript.count >= minAnalysisCharacters else {
            NSLog("[MeetingRec] transcript too small (%.0fs, %d chars) — skipping analysis", duration, transcript.count)
            MeetingAnalysisService.shared.endPending()
            return
        }
        guard let appState else {
            MeetingAnalysisService.shared.endPending()
            return
        }

        MeetingAnalysisService.shared.analyze(
            transcript: transcript,
            context: ctx,
            startedAt: started,
            duration: Int(duration),
            appState: appState
        )
    }

    // MARK: - Transcription

    @MainActor
    private func transcribe(wav: Data, speaker: String) {
        guard isRecording || pendingSTT > 0 else { return }
        // Approximate utterance start from the WAV length (16 kHz mono Int16).
        let seconds = Double(max(0, wav.count - 44)) / 2.0 / MicCapture.targetSampleRate
        let at = Date().addingTimeInterval(-seconds)

        pendingSTT += 1
        Task { [weak self] in
            defer { Task { @MainActor in self?.pendingSTT -= 1 } }
            do {
                let text = try await FalAIService.shared.transcribeWizper(wavData: wav)
                await MainActor.run { self?.append(TranscriptLine(at: at, speaker: speaker, text: text)) }
            } catch {
                // Empty / hallucinated / failed chunks are dropped silently —
                // same policy as voice mode.
            }
        }
    }

    @MainActor
    private func append(_ line: TranscriptLine) {
        lines.append(line)
        lines.sort { $0.at < $1.at }
        lineCount = lines.count
        spill()
    }

    @MainActor
    private func transcriptText() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        return lines
            .map { "[\(fmt.string(from: $0.at))] \($0.speaker): \($0.text)" }
            .joined(separator: "\n")
    }

    // MARK: - Diagnostics

    /// Labeled per-stream level meter, logged every ~3 s — distinguishes
    /// "mic hears nothing" from "VAD rejected it" without touching the
    /// shared VoiceActivityDetector.
    @ObservationIgnored private var micPeakDb: Double = -120
    @ObservationIgnored private var tapPeakDb: Double = -120
    @ObservationIgnored private var lastLevelLog = Date()

    @MainActor
    private func trackLevel(buffer: AVAudioPCMBuffer, isMic: Bool) {
        let db = Self.quickPeakDb(buffer)
        if isMic { micPeakDb = max(micPeakDb, db) } else { tapPeakDb = max(tapPeakDb, db) }
        if Date().timeIntervalSince(lastLevelLog) >= 3 {
            NSLog("[MeetingRec] levels: mic peak=%.1fdB, system peak=%.1fdB", micPeakDb, tapPeakDb)
            micPeakDb = -120
            tapPeakDb = -120
            lastLevelLog = Date()
        }
    }

    private static func quickPeakDb(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return -120 }
        let ch = data[0]
        var maxAbs: Float = 0
        for i in 0..<Int(buffer.frameLength) { maxAbs = max(maxAbs, abs(ch[i])) }
        return 20 * log10(Double(max(maxAbs, 1e-6)))
    }

    private static func defaultInputDeviceName() -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev
        ) == noErr, dev != kAudioObjectUnknown else { return nil }

        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString? = nil
        var nameSize = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &name) { ptr in
            AudioObjectGetPropertyData(dev, &nameAddr, 0, nil, &nameSize, ptr)
        }
        guard status == noErr, let name else { return nil }
        return name as String
    }

    // MARK: - Crash-safety spill

    @MainActor
    private func prepareSpillFile(title: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".otto/meeting_transcripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        spillURL = dir.appendingPathComponent("\(stamp).txt")
        try? "# \(title)\n\n".write(to: spillURL!, atomically: true, encoding: .utf8)
    }

    @MainActor
    private func spill() {
        guard let spillURL else { return }
        let header = "# \(context?.displayTitle ?? "Meeting")\n\n"
        try? (header + transcriptText() + "\n").write(to: spillURL, atomically: true, encoding: .utf8)
    }
}
