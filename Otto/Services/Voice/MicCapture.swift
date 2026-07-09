import Foundation
import AVFoundation

/// Captures mic audio as 16 kHz mono Float32 buffers via `AVAudioEngine`.
/// Converts from whatever the hardware delivers (usually 44.1 / 48 kHz stereo) using
/// `AVAudioConverter`. Emits small ~20 ms frames via `onBuffer` for the VAD.
///
/// All public methods are safe to call from the MainActor. The engine itself lives on
/// an internal serial queue so we don't block the UI.
final class MicCapture: @unchecked Sendable {

    /// Target format used by the rest of the voice pipeline (Wizper wants mono PCM ≤ 16 kHz).
    static let targetSampleRate: Double = 16_000
    static let targetFrameSize: AVAudioFrameCount = 320   // ~20ms @ 16kHz

    enum MicError: LocalizedError {
        case permissionDenied
        case engineStartFailed(String)
        case converterSetupFailed

        var errorDescription: String? {
            switch self {
            case .permissionDenied: return "Microphone access denied. Enable it in System Settings → Privacy & Security → Microphone."
            case .engineStartFailed(let s): return "Audio engine failed: \(s)"
            case .converterSetupFailed: return "Failed to set up audio converter."
            }
        }
    }

    /// Lazily created and torn down each `start()` / `stop()` cycle.
    ///
    /// macOS's orange "mic in use" indicator stays lit as long as the process
    /// holds an `AVAudioEngine` whose input node has ever been tapped — even
    /// after `engine.stop()` and `removeTap(onBus:)`. Reusing a single engine
    /// across cycles kept the indicator on after we logically stopped the wake
    /// listener. Dropping the engine reference here lets the HAL release the
    /// input and the menu-bar dot goes away.
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    /// Mono at the hardware rate — the converter's input when the device runs
    /// multi-channel; `handleTap` downmixes into this before rate conversion.
    private var monoHwFormat: AVAudioFormat?

    /// Called on an arbitrary queue for every ~20ms frame of 16kHz mono Float32 audio.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    private(set) var isRunning: Bool = false

    // Capture diagnostics — raw-vs-converted peaks logged every ~3 s, plus
    // cumulative converter failure counters. Splits "the HAL feeds us zeros"
    // from "the converter zeroes a live signal".
    private var lastDiagLog = Date.distantPast
    private var convErrorCount = 0
    private var convEmptyCount = 0

    // MARK: - Permissions

    /// Request mic permission (macOS 14+). Returns true if granted.
    static func requestPermission() async -> Bool {
        // macOS 14+ exposes AVCaptureDevice.requestAccess(for: .audio); fall back for older.
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
    }

    static var isAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    // MARK: - Start / stop

    func start() throws {
        guard !isRunning else { return }

        // Fresh engine every cycle — see comment on `engine` for why.
        let engine = AVAudioEngine()
        self.engine = engine

        let input = engine.inputNode
        // Note: we previously enabled setVoiceProcessingEnabled(true) for AEC, but
        // it suppresses input so aggressively that the VAD never saw user speech
        // above threshold — phase stayed in .listening forever. Echo feedback is
        // handled instead by tightening the barge-in detector in VoiceActivityDetector.
        let hwFormat = input.outputFormat(forBus: 0)
        NSLog("[MicCapture] hw format: %.0f Hz, %d ch", hwFormat.sampleRate, hwFormat.channelCount)
        convErrorCount = 0
        convEmptyCount = 0
        lastDiagLog = Date.distantPast

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else { throw MicError.converterSetupFailed }
        self.targetFormat = target

        // While a meeting app (Safari/Meet, Zoom) holds the mic, macOS runs
        // the MacBook mic array in raw 3-channel mode. AVAudioConverter's
        // default channel map for 3ch→mono resolves to silence (live input,
        // all-zero output, no error), and any single raw channel is ~10 dB
        // quieter than the processed mono mode. So: downmix all channels
        // ourselves in handleTap (coherent speech sums, noise doesn't) and
        // give the converter a mono input at the hardware rate.
        let converterInput: AVAudioFormat
        if hwFormat.channelCount > 1 {
            guard let monoHw = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: hwFormat.sampleRate,
                channels: 1,
                interleaved: false
            ) else { throw MicError.converterSetupFailed }
            self.monoHwFormat = monoHw
            converterInput = monoHw
        } else {
            self.monoHwFormat = nil
            converterInput = hwFormat
        }

        guard let conv = AVAudioConverter(from: converterInput, to: target) else {
            throw MicError.converterSetupFailed
        }
        self.converter = conv

        // Tap on the hardware format. Buffer size of 1024 frames @ 48kHz ≈ 21ms — close enough
        // to our 20ms target frame after conversion; we don't need exact alignment for VAD.
        input.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] buffer, _ in
            self?.handleTap(buffer: buffer)
        }

        do {
            engine.prepare()
            try engine.start()
            isRunning = true
        } catch {
            input.removeTap(onBus: 0)
            self.engine = nil
            self.converter = nil
            self.targetFormat = nil
            throw MicError.engineStartFailed(error.localizedDescription)
        }
    }

    func stop() {
        guard isRunning else { return }
        if let engine = engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            // Resetting the input node before dropping the reference helps the
            // HAL clean up immediately; otherwise the orange mic indicator
            // sometimes lingers until the next runloop tick.
            engine.inputNode.reset()
            engine.reset()
        }
        engine = nil
        converter = nil
        targetFormat = nil
        monoHwFormat = nil
        isRunning = false
    }

    // MARK: - Conversion

    private func handleTap(buffer rawBuffer: AVAudioPCMBuffer) {
        guard let converter = converter, let target = targetFormat else { return }
        guard let buffer = downmixIfNeeded(rawBuffer) else { return }

        // Estimate output capacity based on sample-rate ratio.
        let ratio = target.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)

        guard let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCapacity) else {
            return
        }

        var error: NSError?
        var provided = false
        converter.convert(to: outBuf, error: &error) { _, status in
            if provided {
                status.pointee = .noDataNow
                return nil
            }
            provided = true
            status.pointee = .haveData
            return buffer
        }

        if error != nil { convErrorCount += 1 }
        if outBuf.frameLength == 0 { convEmptyCount += 1 }

        let now = Date()
        if now.timeIntervalSince(lastDiagLog) >= 3 {
            lastDiagLog = now
            NSLog("[MicCapture] raw peak=%.1fdB (%.0fHz/%dch %d frames) → converted peak=%.1fdB (%d frames), convErrors=%d, convEmpties=%d",
                  Self.peakDb(rawBuffer), rawBuffer.format.sampleRate, rawBuffer.format.channelCount, rawBuffer.frameLength,
                  Self.peakDb(outBuf), outBuf.frameLength, convErrorCount, convEmptyCount)
        }

        if error != nil { return }
        if outBuf.frameLength == 0 { return }

        onBuffer?(outBuf)
    }

    /// Sum a multi-channel buffer into mono, scaled by 1/√N: coherent speech
    /// picked up by all array channels gains ~+4.8 dB (3ch) over any single
    /// channel while incoherent noise doesn't — partial recovery of the level
    /// the processed mono mode would have delivered. Single-channel buffers
    /// pass through untouched.
    private func downmixIfNeeded(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.format.channelCount > 1 else { return buffer }
        guard let monoHw = monoHwFormat,
              let mixed = AVAudioPCMBuffer(pcmFormat: monoHw, frameCapacity: buffer.frameLength),
              let src = buffer.floatChannelData,
              let dst = mixed.floatChannelData
        else { return nil }

        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let out = dst[0]
        let first = src[0]
        for i in 0..<frames { out[i] = first[i] }
        for c in 1..<channels {
            let ch = src[c]
            for i in 0..<frames { out[i] += ch[i] }
        }
        let scale = 1.0 / Float(channels).squareRoot()
        for i in 0..<frames { out[i] *= scale }
        mixed.frameLength = buffer.frameLength
        return mixed
    }

    private static func peakDb(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return -120 }
        let ch = data[0]
        var maxAbs: Float = 0
        for i in 0..<Int(buffer.frameLength) { maxAbs = max(maxAbs, abs(ch[i])) }
        return 20 * log10(Double(max(maxAbs, 1e-6)))
    }
}
