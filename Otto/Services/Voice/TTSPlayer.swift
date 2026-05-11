import Foundation
import AVFoundation

/// Plays a queue of audio blobs (MP3 from ElevenLabs v3) sequentially via AVAudioEngine.
///
/// Each enqueued chunk is decoded into a PCM buffer and — critically — **converted
/// to a fixed target format** (44.1 kHz stereo Float32) before being scheduled. The
/// player node is connected with this explicit format, so every scheduled buffer
/// matches. Without the conversion, scheduling a buffer whose channel count or
/// sample rate differs from the node's output format crashes AVAudioEngine with:
///   `required condition is false: _outputFormat.channelCount == buffer.format.channelCount`
///
/// On `stop()` we apply a short volume ramp (fade-out) then tear down the node —
/// this avoids an audible click when the user barges in mid-sentence.
final class TTSPlayer: @unchecked Sendable {

    /// Fixed target format for the player node's output. All decoded chunks are
    /// converted to this before scheduling.
    private static let targetFormat: AVAudioFormat = {
        AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    }()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let mixer: AVAudioMixerNode

    /// Called on an arbitrary queue whenever a chunk finishes playing.
    var onChunkCompleted: (() -> Void)?
    /// 0...1 peak level of what's currently playing, for the UI orb.
    var onLevel: ((Float) -> Void)?

    private var levelTap: Bool = false
    private var pendingCount: Int = 0
    private let queue = DispatchQueue(label: "otto.tts.player")

    init() {
        mixer = engine.mainMixerNode
        engine.attach(player)
        // Connect with an explicit known format so scheduled buffers' formats are
        // validated against a stable target (not whatever the first chunk happened to be).
        engine.connect(player, to: mixer, format: Self.targetFormat)
    }

    var isPlaying: Bool {
        queue.sync { pendingCount > 0 }
    }

    /// Decode MP3 bytes and queue them for playback. Returns after scheduling (not after playback).
    func enqueue(_ mp3: Data) async throws {
        // Write to a temp file — AVAudioFile is the easy decode path for compressed audio.
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("otto-tts-\(UUID().uuidString).mp3")
        try mp3.write(to: tmpURL)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let file = try AVAudioFile(forReading: tmpURL)
        let sourceFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)

        guard frameCount > 0,
              let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount)
        else { return }
        try file.read(into: sourceBuffer)

        let target = Self.targetFormat
        let playableBuffer: AVAudioPCMBuffer
        if sourceFormat == target {
            playableBuffer = sourceBuffer
        } else {
            // Convert to target format (handles sample-rate, channel-count, and bit-depth diffs).
            guard let converter = AVAudioConverter(from: sourceFormat, to: target) else {
                throw NSError(domain: "TTSPlayer", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Failed to create audio converter"])
            }
            let ratio = target.sampleRate / sourceFormat.sampleRate
            let outCapacity = AVAudioFrameCount(Double(frameCount) * ratio + 1024)
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCapacity) else {
                return
            }
            var convError: NSError?
            var provided = false
            converter.convert(to: outBuffer, error: &convError) { _, status in
                if provided {
                    status.pointee = .endOfStream
                    return nil
                }
                provided = true
                status.pointee = .haveData
                return sourceBuffer
            }
            if let convError { throw convError }
            if outBuffer.frameLength == 0 { return }
            playableBuffer = outBuffer
        }

        try await schedule(buffer: playableBuffer)
    }

    private func schedule(buffer: AVAudioPCMBuffer) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self = self else {
                    cont.resume()
                    return
                }
                do {
                    if !self.engine.isRunning {
                        self.installLevelTapIfNeeded()
                        self.player.volume = 1.0
                        try self.engine.start()
                        self.player.play()
                    }
                    self.pendingCount += 1
                    self.player.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
                        guard let self = self else { return }
                        self.queue.async {
                            self.pendingCount = max(0, self.pendingCount - 1)
                            self.onChunkCompleted?()
                        }
                    }
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Stop playback immediately with an 80ms fade to avoid clicks.
    func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }
            // Short volume ramp for a clean cutoff.
            let steps = 8
            for i in 0..<steps {
                self.player.volume = Float(steps - i - 1) / Float(steps)
                Thread.sleep(forTimeInterval: 0.010)
            }
            self.player.stop()
            if self.engine.isRunning {
                self.engine.stop()
            }
            self.pendingCount = 0
            self.player.volume = 1.0
        }
    }

    // MARK: - Level meter

    private func installLevelTapIfNeeded() {
        guard !levelTap else { return }
        levelTap = true
        // Tap the output of the player node — matches the target format we connected with.
        player.installTap(onBus: 0, bufferSize: 512, format: Self.targetFormat) { [weak self] buffer, _ in
            guard let self = self, let ch = buffer.floatChannelData?.pointee else { return }
            let count = Int(buffer.frameLength)
            if count == 0 { return }
            var peak: Float = 0
            for i in 0..<count { peak = max(peak, abs(ch[i])) }
            self.onLevel?(min(1.0, peak * 1.5))
        }
    }
}
