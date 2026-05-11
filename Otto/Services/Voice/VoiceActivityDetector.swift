import Foundation
import AVFoundation

/// Energy-based voice activity detector with an adaptive noise floor.
///
/// Feeds mic frames via `process(buffer:)`. Maintains two conceptual modes:
///
/// 1. **Utterance detection** (default, for the listening phase): emits completed
///    utterances as WAV blobs via `onUtterance` when the user finishes speaking
///    (≥ 700ms silence after speech).
///
/// 2. **Barge-in detection** (call `setBargeInMode(true)` during TTS playback):
///    suppresses utterance emission and only fires `onBargeIn` once it detects
///    ≥ 120ms of continuous speech above threshold — used to interrupt Claude
///    mid-sentence.
///
/// Thresholds are exposed as `let` constants near the top of the file for easy tuning.
final class VoiceActivityDetector: @unchecked Sendable {

    // MARK: - Tunables

    /// End-of-utterance: this much continuous silence after speech → emit utterance.
    private let silenceHangoverMs: Double = 500
    /// Reject very short bursts (coughs, lip smacks, key clicks, echo fragments).
    /// Was 600ms. Dropped to 400ms so brief answers ("yes", "no") don't get
    /// silently rejected.
    private let minUtteranceMs: Double = 400
    /// How much pre-onset audio to prepend to the captured segment (don't clip first syllable).
    private let preRollMs: Double = 250
    /// Hard cap to avoid memory runaway if the user speaks for a very long time.
    private let maxUtteranceMs: Double = 30_000
    /// Speech threshold above the rolling noise floor, in dB.
    /// Was 16 dB; relaxed to 12 dB so noisy rooms don't starve speech detection.
    /// (TTS-echo is now filtered by the barge-in absolute floor, not this gate.)
    private let speechAboveNoiseDb: Double = 12
    /// Hard ceiling on the adaptive noise floor. Without this, continuous
    /// background noise (fan, AC, ambient chatter) slowly pushes the EMA up
    /// until speech needs to be impossibly loud to register — and the VAD
    /// silently stops ever seeing speech. Cap keeps detection reachable.
    private let noiseFloorCeilingDb: Double = -32
    /// Absolute floor so we never trigger on total silence + numeric noise.
    private let absoluteSilenceDb: Double = -55
    /// Absolute minimum RMS that must be reached during an utterance for it to
    /// be considered real speech (regardless of adaptive noise floor). Prevents
    /// adaptive floor from drifting so low that whisper-level echo triggers.
    /// Was -35dB; relaxed to -40dB so quieter / farther-from-mic speech passes.
    private let minUtteranceRmsDb: Double = -40
    /// EMA smoothing factor for noise-floor adaptation (low = slow adaptation).
    private let noiseAlpha: Double = 0.02
    /// Barge-in: continuous speech for this long while TTS is playing → fire barge-in.
    /// 300ms is short enough to feel responsive while still filtering brief
    /// echo spikes or single-syllable noise.
    private let bargeInMinMs: Double = 300
    /// Small extra margin above the normal speech threshold for barge-in. The
    /// real gate is `bargeInAbsoluteFloorDb` below — this just catches cases
    /// where the noise floor has adapted very low.
    private let bargeInExtraDb: Double = 4
    /// Absolute dB floor any barge-in RMS must clear — prevents faint echo
    /// (typically -30 to -35 dB at the mic with laptop speakers) from triggering,
    /// while normal user speech at arm's length (~-20 dB) clears easily.
    private let bargeInAbsoluteFloorDb: Double = -25

    // MARK: - Output callbacks (set by owner)

    /// Fires with a WAV-encoded 16 kHz mono blob ready to ship to Wizper.
    var onUtterance: ((Data) -> Void)?
    /// Fires once per speech onset when in barge-in mode.
    var onBargeIn: (() -> Void)?
    /// Fires on every processed buffer (0...1) so the UI can draw a level meter.
    var onLevel: ((Float) -> Void)?

    // MARK: - State

    private enum Phase { case silent, speaking, tailSilence }
    private var phase: Phase = .silent
    private var bargeInMode: Bool = false

    /// Rolling noise floor in dB (initialized to -45 dB, adapts over time).
    private var noiseFloorDb: Double = -45

    /// Buffers captured for the current (or most recent) utterance.
    private var utteranceBuffers: [AVAudioPCMBuffer] = []
    /// Pre-roll ring (trailing preRollMs of silent frames — prepended on onset).
    private var preRoll: [AVAudioPCMBuffer] = []
    private var preRollDurationMs: Double = 0

    /// Milliseconds of speech observed in the current .speaking phase.
    private var speechDurationMs: Double = 0
    /// Milliseconds of silence observed in the current .tailSilence phase.
    private var tailSilenceMs: Double = 0
    /// Consecutive speech frames seen during .tailSilence — requires a small
    /// burst before we bounce back to .speaking, so a single noise blip doesn't
    /// reset the 500 ms silence hangover timer and leave us stuck forever.
    private var tailSilenceReOnsetMs: Double = 0
    /// How much continuous re-onset speech is needed to cancel the tail. Below
    /// this we treat it as noise and keep counting down to end-of-utterance.
    private let tailSilenceReOnsetThresholdMs: Double = 120
    /// Continuous speech duration for barge-in detection.
    private var bargeInSpeechMs: Double = 0
    /// Peak RMS observed during the current utterance (for minUtteranceRmsDb check).
    private var utterancePeakDb: Double = -100

    /// Most recent TTS output peak level (0..1). Barge-in requires user speech
    /// to exceed TTS output by a margin — poor-man's echo cancellation.
    /// Updated by VoiceSessionManager from `TTSPlayer.onLevel`.
    private var currentTTSLevel: Float = 0

    func setCurrentTTSLevel(_ level: Float) { currentTTSLevel = level }

    // MARK: - API

    func setBargeInMode(_ enabled: Bool) {
        bargeInMode = enabled
        bargeInSpeechMs = 0
        if enabled {
            // Don't hold onto a partial utterance while we're listening for barge-in only.
            utteranceBuffers.removeAll(keepingCapacity: true)
            phase = .silent
            speechDurationMs = 0
            tailSilenceMs = 0
        }
    }

    func reset() {
        phase = .silent
        utteranceBuffers.removeAll(keepingCapacity: true)
        preRoll.removeAll(keepingCapacity: true)
        preRollDurationMs = 0
        speechDurationMs = 0
        tailSilenceMs = 0
        tailSilenceReOnsetMs = 0
        bargeInSpeechMs = 0
    }

    /// Ms since last heartbeat log — prints VAD state every ~3 s while listening
    /// so Console shows noise floor, peak, and threshold even if no utterance
    /// ever fires (the invisible stuck-in-listening failure mode).
    private var heartbeatMs: Double = 0
    private var heartbeatPeakDb: Double = -100

    func process(buffer: AVAudioPCMBuffer) {
        let frameMs = Double(buffer.frameLength) / buffer.format.sampleRate * 1000
        guard frameMs > 0 else { return }

        let rmsDb = rmsDb(buffer: buffer)
        onLevel?(levelForMeter(rmsDb: rmsDb))

        let thresholdDb = max(noiseFloorDb + speechAboveNoiseDb, absoluteSilenceDb + 6)
        let isSpeech = rmsDb > thresholdDb

        heartbeatPeakDb = max(heartbeatPeakDb, rmsDb)
        heartbeatMs += frameMs
        if heartbeatMs >= 3000 {
            NSLog(String(format: "[VAD] heartbeat: phase=%@ floor=%.1fdB threshold=%.1fdB peak3s=%.1fdB", String(describing: phase), noiseFloorDb, thresholdDb, heartbeatPeakDb))
            heartbeatMs = 0
            heartbeatPeakDb = -100
        }

        if bargeInMode {
            // Static -25 dB absolute floor + 300 ms minimum duration filters
            // brief echo spikes. User speech at arm's length (~-20 dB peak,
            // sustained) clears easily; speaker echo (typically -30 dB, bursty)
            // doesn't. No TTS-level gate — that raised the bar above what
            // normal speech can reach while Claude is talking.
            let bargeInRelativeDb = max(noiseFloorDb + speechAboveNoiseDb + bargeInExtraDb,
                                        absoluteSilenceDb + 6)
            let bargeInThresholdDb = max(bargeInRelativeDb, bargeInAbsoluteFloorDb)
            let isBargeInSpeech = rmsDb > bargeInThresholdDb
            handleBargeIn(isSpeech: isBargeInSpeech, frameMs: frameMs)
            if !isSpeech { adaptNoiseFloor(rmsDb: rmsDb) }
            return
        }

        switch phase {
        case .silent:
            // Maintain a rolling pre-roll so we don't clip the first syllable.
            preRoll.append(buffer)
            preRollDurationMs += frameMs
            while preRollDurationMs > preRollMs, !preRoll.isEmpty {
                let removed = preRoll.removeFirst()
                preRollDurationMs -= Double(removed.frameLength) / removed.format.sampleRate * 1000
            }

            if isSpeech {
                phase = .speaking
                // Seed utterance with the pre-roll we just accumulated.
                utteranceBuffers = preRoll
                utteranceBuffers.append(buffer)
                speechDurationMs = frameMs
                tailSilenceMs = 0
                utterancePeakDb = rmsDb
            } else {
                adaptNoiseFloor(rmsDb: rmsDb)
            }

        case .speaking:
            utteranceBuffers.append(buffer)
            utterancePeakDb = max(utterancePeakDb, rmsDb)
            if isSpeech {
                speechDurationMs += frameMs
            } else {
                phase = .tailSilence
                tailSilenceMs = frameMs
            }

            if speechDurationMs > maxUtteranceMs {
                emitUtterance()
            }

        case .tailSilence:
            utteranceBuffers.append(buffer)
            utterancePeakDb = max(utterancePeakDb, rmsDb)
            if isSpeech {
                tailSilenceReOnsetMs += frameMs
                if tailSilenceReOnsetMs >= tailSilenceReOnsetThresholdMs {
                    // Sustained re-onset — legitimately back to speaking.
                    phase = .speaking
                    speechDurationMs += tailSilenceMs + tailSilenceReOnsetMs
                    tailSilenceMs = 0
                    tailSilenceReOnsetMs = 0
                }
                // Otherwise: treat as a noise blip — keep counting silence below.
            } else {
                tailSilenceReOnsetMs = 0
                tailSilenceMs += frameMs
                if tailSilenceMs >= silenceHangoverMs {
                    emitUtterance()
                }
            }
        }
    }

    // MARK: - Helpers

    private func handleBargeIn(isSpeech: Bool, frameMs: Double) {
        if isSpeech {
            bargeInSpeechMs += frameMs
            if bargeInSpeechMs >= bargeInMinMs {
                bargeInSpeechMs = 0
                NSLog("[VAD] barge-in fired after %.0fms of speech", bargeInMinMs)
                onBargeIn?()
            }
        } else {
            bargeInSpeechMs = 0
        }
    }

    private func emitUtterance() {
        let durMs = speechDurationMs
        let peakDb = utterancePeakDb
        let floor = noiseFloorDb
        defer {
            utteranceBuffers.removeAll(keepingCapacity: true)
            preRoll.removeAll(keepingCapacity: true)
            preRollDurationMs = 0
            phase = .silent
            speechDurationMs = 0
            tailSilenceMs = 0
            utterancePeakDb = -100
        }

        // Reject noise artifacts via three gates:
        // 1. Duration — coughs, clicks, brief echo fragments.
        if durMs < minUtteranceMs {
            NSLog(String(format: "[VAD] utterance rejected: too short (%.0fms < %.0fms) peak=%.1fdB", durMs, minUtteranceMs, peakDb))
            return
        }
        // 2. Absolute loudness — if the loudest frame never reaches real-speech
        //    volume, this is almost certainly mic noise or TTS bleed, not the user.
        if peakDb < minUtteranceRmsDb {
            NSLog(String(format: "[VAD] utterance rejected: too quiet (peak=%.1fdB < %.1fdB) dur=%.0fms", peakDb, minUtteranceRmsDb, durMs))
            return
        }
        // 3. Relative loudness (re-check peak vs. noise floor) — guards against
        //    cases where adaptive floor drifted low during quiet passages.
        if peakDb < floor + speechAboveNoiseDb {
            NSLog(String(format: "[VAD] utterance rejected: not above noise (peak=%.1fdB, floor=%.1fdB, margin=%.1fdB < %.1fdB) dur=%.0fms", peakDb, floor, peakDb - floor, speechAboveNoiseDb, durMs))
            return
        }

        guard let wav = AudioEncoder.floatBuffersToWav16kMonoWav(utteranceBuffers) else { return }
        NSLog(String(format: "[VAD] utterance emitted: dur=%.0fms peak=%.1fdB floor=%.1fdB", durMs, peakDb, floor))
        onUtterance?(wav)
    }

    private func adaptNoiseFloor(rmsDb: Double) {
        // Ignore silence from the numeric floor when adapting.
        guard rmsDb > absoluteSilenceDb else { return }
        let next = (1 - noiseAlpha) * noiseFloorDb + noiseAlpha * rmsDb
        // Ceiling prevents adaptation from making speech detection impossible
        // in noisy environments (see comment on noiseFloorCeilingDb).
        noiseFloorDb = min(next, noiseFloorCeilingDb)
    }

    private func rmsDb(buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.floatChannelData else { return absoluteSilenceDb }
        let count = Int(buffer.frameLength)
        if count == 0 { return absoluteSilenceDb }
        let ch = data[0]
        var sumSquares: Double = 0
        for i in 0..<count {
            let v = Double(ch[i])
            sumSquares += v * v
        }
        let mean = sumSquares / Double(count)
        let rms = sqrt(max(mean, 1e-12))
        return 20 * log10(rms)
    }

    /// Map RMS dB to 0...1 for the UI meter (clamped so the orb doesn't flicker on noise).
    private func levelForMeter(rmsDb: Double) -> Float {
        let minDb = -50.0
        let maxDb = -10.0
        let clamped = max(minDb, min(maxDb, rmsDb))
        return Float((clamped - minDb) / (maxDb - minDb))
    }
}
