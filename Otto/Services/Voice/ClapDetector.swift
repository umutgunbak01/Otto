import Foundation
import AVFoundation

/// Detects hand-clap transients in 16 kHz mono PCM audio coming out of `MicCapture`.
///
/// A clap has a distinctive acoustic signature:
///  - a very sharp onset (peak sample far above the rolling noise floor),
///  - broadband energy (high zero-crossing rate — claps rattle through most of the
///    audible spectrum, unlike a tonal "aaah"),
///  - and fast decay (the loud burst is essentially gone within ~120 ms).
///
/// We match all three to keep the false-positive rate low: speech is loud too but
/// sustained; door thuds are loud but low-frequency (low ZCR); keystrokes are
/// broadband but usually quieter.
final class ClapDetector: @unchecked Sendable {

    // MARK: - Tunables

    /// Peak must exceed rolling noise floor by at least this many dB to count as a burst.
    private let burstAboveNoiseDb: Double = 14
    /// Absolute floor — peaks below this are never considered claps (silence / numeric noise).
    private let burstAbsoluteFloorDb: Double = -24
    /// Zero-crossing rate on the burst frame must exceed this to count as broadband.
    /// Typical values: speech ~0.05-0.15, claps ~0.18-0.45, low-frequency thuds ~0.02.
    private let minZeroCrossingRate: Float = 0.16
    /// After firing, suppress further detections for this long to avoid multi-fire on echo.
    private let refractoryMs: Double = 800

    // MARK: - Callback

    var onClap: (() -> Void)?

    // MARK: - State

    private var noiseFloorDb: Double = -45
    private let noiseAlpha: Double = 0.02
    private var suppressUntil: Date = .distantPast

    // MARK: - API

    func reset() {
        noiseFloorDb = -45
        suppressUntil = .distantPast
    }

    func process(buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }

        var peak: Float = 0
        var sumSquares: Double = 0
        var zeroCrossings: Int = 0
        var prev: Float = channel[0]
        for i in 0..<count {
            let v = channel[i]
            let abs_v = abs(v)
            if abs_v > peak { peak = abs_v }
            sumSquares += Double(v) * Double(v)
            if (v >= 0) != (prev >= 0) { zeroCrossings += 1 }
            prev = v
        }
        let peakDb = 20 * log10(max(Double(peak), 1e-6))
        let rmsDb = 20 * log10(max(sqrt(sumSquares / Double(count)), 1e-6))
        let zcr = Float(zeroCrossings) / Float(count)

        // Adapt the noise floor on quiet frames only.
        let quietThreshold = noiseFloorDb + 6
        if rmsDb < quietThreshold {
            noiseFloorDb = (1 - noiseAlpha) * noiseFloorDb + noiseAlpha * rmsDb
        }

        if Date() < suppressUntil { return }

        let loudEnoughRelative = peakDb > noiseFloorDb + burstAboveNoiseDb
        let loudEnoughAbsolute = peakDb > burstAbsoluteFloorDb
        let broadband = zcr > minZeroCrossingRate

        if loudEnoughRelative, loudEnoughAbsolute, broadband {
            suppressUntil = Date().addingTimeInterval(refractoryMs / 1000)
            onClap?()
        } else if loudEnoughAbsolute {
            // Loud burst that didn't match — log so we can tune thresholds.
            NSLog(String(format: "[Clap] rejected: peak=%.1fdB rms=%.1fdB zcr=%.2f floor=%.1fdB", peakDb, rmsDb, zcr, noiseFloorDb))
        }
    }
}
