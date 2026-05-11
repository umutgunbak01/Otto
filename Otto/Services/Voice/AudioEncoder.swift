import Foundation
import AVFoundation

/// Encodes PCM audio to WAV format (16-bit signed, little-endian) — the format Wizper accepts
/// via a data URL payload. Keeps everything in memory; no temp files.
enum AudioEncoder {

    /// Convert one or more Float32 PCM buffers (at the given sample rate, mono) to a WAV Data blob.
    /// Assumes all buffers share the same `processingFormat`.
    static func floatBuffersToWav16kMonoWav(_ buffers: [AVAudioPCMBuffer]) -> Data? {
        guard let first = buffers.first else { return nil }
        let sampleRate = Int(first.format.sampleRate)

        // Flatten all samples into one Int16 array.
        var int16Samples: [Int16] = []
        int16Samples.reserveCapacity(buffers.reduce(0) { $0 + Int($1.frameLength) })

        for buf in buffers {
            guard let channelData = buf.floatChannelData else { continue }
            let count = Int(buf.frameLength)
            let ch0 = channelData[0]
            for i in 0..<count {
                // Clamp to [-1, 1] then scale to Int16 range.
                let v = max(-1.0, min(1.0, ch0[i]))
                int16Samples.append(Int16(v * 32767.0))
            }
        }

        return makeWavData(int16Samples: int16Samples, sampleRate: sampleRate, channels: 1)
    }

    /// Build a RIFF/WAVE container around raw little-endian Int16 PCM samples.
    static func makeWavData(int16Samples: [Int16], sampleRate: Int, channels: Int) -> Data {
        let bitsPerSample: UInt16 = 16
        let bytesPerSample: UInt16 = bitsPerSample / 8
        let byteRate = UInt32(sampleRate * channels * Int(bytesPerSample))
        let blockAlign = UInt16(channels * Int(bytesPerSample))
        let dataSize = UInt32(int16Samples.count * Int(bytesPerSample))
        let riffSize = UInt32(36) + dataSize

        var out = Data()
        out.append(contentsOf: Array("RIFF".utf8))
        out.append(le32(riffSize))
        out.append(contentsOf: Array("WAVE".utf8))
        out.append(contentsOf: Array("fmt ".utf8))
        out.append(le32(16))                          // PCM fmt chunk size
        out.append(le16(1))                           // PCM format code
        out.append(le16(UInt16(channels)))
        out.append(le32(UInt32(sampleRate)))
        out.append(le32(byteRate))
        out.append(le16(blockAlign))
        out.append(le16(bitsPerSample))
        out.append(contentsOf: Array("data".utf8))
        out.append(le32(dataSize))

        // Samples — each Int16 as little-endian.
        int16Samples.withUnsafeBufferPointer { ptr in
            out.append(UnsafeBufferPointer(start: ptr.baseAddress, count: ptr.count))
        }
        return out
    }

    private static func le16(_ v: UInt16) -> Data {
        var little = v.littleEndian
        return Data(bytes: &little, count: 2)
    }

    private static func le32(_ v: UInt32) -> Data {
        var little = v.littleEndian
        return Data(bytes: &little, count: 4)
    }
}

extension Data {
    fileprivate mutating func append<T>(_ buffer: UnsafeBufferPointer<T>) {
        buffer.withMemoryRebound(to: UInt8.self) { raw in
            append(raw.baseAddress!, count: raw.count)
        }
    }
}
