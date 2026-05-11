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

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?

    /// Called on an arbitrary queue for every ~20ms frame of 16kHz mono Float32 audio.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    private(set) var isRunning: Bool = false

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

        let input = engine.inputNode
        // Note: we previously enabled setVoiceProcessingEnabled(true) for AEC, but
        // it suppresses input so aggressively that the VAD never saw user speech
        // above threshold — phase stayed in .listening forever. Echo feedback is
        // handled instead by tightening the barge-in detector in VoiceActivityDetector.
        let hwFormat = input.outputFormat(forBus: 0)

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else { throw MicError.converterSetupFailed }
        self.targetFormat = target

        guard let conv = AVAudioConverter(from: hwFormat, to: target) else {
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
            throw MicError.engineStartFailed(error.localizedDescription)
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    // MARK: - Conversion

    private func handleTap(buffer: AVAudioPCMBuffer) {
        guard let converter = converter, let target = targetFormat else { return }

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

        if error != nil { return }
        if outBuf.frameLength == 0 { return }

        onBuffer?(outBuf)
    }
}
