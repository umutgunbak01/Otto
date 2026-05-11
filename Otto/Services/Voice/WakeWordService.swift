import Foundation
import AVFoundation

/// Always-on (when the app is backgrounded) wake-word listener.
///
/// Pipeline:
///   MicCapture → ClapDetector (gate) + rolling ring buffer
///      ↓ on clap
///   capture ~2 s post-roll + ~300 ms pre-roll from the ring
///      ↓
///   WAV-encode → Wizper transcription
///      ↓ if transcript lowercased contains "wake up"
///   fire `onWake` on the main actor.
///
/// Only runs while `start()` has been called. `OttoApp` is responsible for calling
/// `start()` when the app resigns active and `stop()` when it becomes active again,
/// so we never contend with `VoiceSessionManager`'s own mic tap.
///
/// All mutable state is touched only from the main actor — MicCapture's tap runs on
/// an arbitrary queue but each `handleBuffer` invocation hops to `@MainActor`.
final class WakeWordService: @unchecked Sendable {

    // MARK: - Tunables

    /// How many seconds of audio to keep in the ring buffer for pre-roll.
    private let ringBufferSeconds: Double = 0.3
    /// How many seconds of audio to collect after a clap and ship to Wizper.
    private let captureSeconds: Double = 2.0
    /// Substring matched (case-insensitive) in the transcription to trigger a wake.
    private let wakePhrase: String = "wake up"

    // MARK: - Callback

    var onWake: (() -> Void)?

    // MARK: - Dependencies

    private let mic = MicCapture()
    private let clap = ClapDetector()
    private let falAI = FalAIService.shared

    // MARK: - State

    private var running: Bool = false
    /// Ring of recent buffers — sized to ~ringBufferSeconds of audio.
    private var ring: [AVAudioPCMBuffer] = []
    private var ringDurationMs: Double = 0
    /// When non-nil, we're actively collecting the post-clap window.
    private var captureBuffers: [AVAudioPCMBuffer]? = nil
    private var captureDurationMs: Double = 0
    /// True while a Wizper call is in flight — suppress further clap handling.
    private var transcribing: Bool = false

    // MARK: - Lifecycle

    init() {
        mic.onBuffer = { [weak self] buf in
            // MicCapture's tap runs on an arbitrary queue; hop to the main actor.
            Task { @MainActor in self?.handleBuffer(buf) }
        }
        clap.onClap = { [weak self] in
            Task { @MainActor in self?.handleClap() }
        }
    }

    func start() {
        guard !running else { return }
        // Request mic permission on first use. If the user has never granted it,
        // this shows the system prompt; if already granted, returns immediately.
        if !MicCapture.isAuthorized {
            Task { [weak self] in
                let granted = await MicCapture.requestPermission()
                if granted {
                    await MainActor.run { self?.startInternal() }
                } else {
                    NSLog("[WakeWord] mic permission denied — wake listener disabled")
                }
            }
            return
        }
        startInternal()
    }

    private func startInternal() {
        guard !running else { return }
        guard falAI.hasAPIKey() else {
            NSLog("[WakeWord] no fal.ai API key set — wake listener disabled")
            return
        }
        do {
            clap.reset()
            ring.removeAll(keepingCapacity: true)
            ringDurationMs = 0
            captureBuffers = nil
            captureDurationMs = 0
            transcribing = false
            try mic.start()
            running = true
            NSLog("[WakeWord] started — clap + say \"wake up\"")
        } catch {
            NSLog("[WakeWord] failed to start mic: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard running else { return }
        mic.stop()
        running = false
        captureBuffers = nil
        captureDurationMs = 0
        NSLog("[WakeWord] stopped")
    }

    // MARK: - Audio pipeline

    private func handleBuffer(_ buffer: AVAudioPCMBuffer) {
        let frameMs = Double(buffer.frameLength) / buffer.format.sampleRate * 1000
        guard frameMs > 0 else { return }

        // Always feed the clap detector — its own refractory period and `transcribing`
        // flag below prevent repeat fires.
        if !transcribing, captureBuffers == nil {
            clap.process(buffer: buffer)
        }

        if captureBuffers != nil {
            captureBuffers?.append(buffer)
            captureDurationMs += frameMs
            if captureDurationMs >= captureSeconds * 1000 {
                flushCapture()
            }
        } else {
            // Maintain a short rolling pre-roll so we don't miss the phrase onset.
            ring.append(buffer)
            ringDurationMs += frameMs
            let budgetMs = ringBufferSeconds * 1000
            while ringDurationMs > budgetMs, !ring.isEmpty {
                let removed = ring.removeFirst()
                ringDurationMs -= Double(removed.frameLength) / removed.format.sampleRate * 1000
            }
        }
    }

    private func handleClap() {
        guard captureBuffers == nil, !transcribing else { return }
        NSLog("[WakeWord] clap detected — listening for phrase")
        // Seed the post-clap window with the ring so we include a bit of audio
        // just before the clap — if the phrase starts immediately after, we
        // won't clip the leading syllable.
        captureBuffers = ring
        captureDurationMs = ringDurationMs
        ring.removeAll(keepingCapacity: true)
        ringDurationMs = 0
    }

    private func flushCapture() {
        guard let bufs = captureBuffers else { return }
        captureBuffers = nil
        captureDurationMs = 0
        transcribing = true
        let wake = wakePhrase.lowercased()

        Task { [weak self, bufs, wake] in
            guard let wav = AudioEncoder.floatBuffersToWav16kMonoWav(bufs) else {
                await MainActor.run { self?.transcribing = false }
                return
            }
            do {
                let text = try await FalAIService.shared.transcribeWizper(wavData: wav)
                NSLog("[WakeWord] transcribed: \"\(text)\"")
                if text.lowercased().contains(wake) {
                    NSLog("[WakeWord] phrase matched — firing onWake")
                    await MainActor.run { self?.onWake?() }
                }
            } catch {
                NSLog("[WakeWord] transcription error: \(error.localizedDescription)")
            }
            await MainActor.run { self?.transcribing = false }
        }
    }
}
