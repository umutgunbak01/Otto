import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

/// Captures system audio output (everything except Otto's own playback) via a
/// Core Audio process tap — the other participants' side of a meeting.
///
/// Pipeline: global mono tap (excluding Otto) → private aggregate device →
/// IOProc → AVAudioConverter → 16 kHz mono Float32 buffers on `onBuffer`,
/// mirroring `MicCapture`'s output format so the same VAD/STT pipeline works
/// on both streams.
///
/// First use triggers macOS's one-time "System Audio Recording" permission
/// prompt (NSAudioCaptureUsageDescription). If the user declines, `start()`
/// throws and the caller can degrade to mic-only capture.
final class SystemAudioTap: @unchecked Sendable {

    enum TapError: LocalizedError {
        case tapCreationFailed(OSStatus)
        case aggregateCreationFailed(OSStatus)
        case formatUnavailable
        case startFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .tapCreationFailed(let s):
                return "Couldn't create the system-audio tap (status \(s)). Check System Settings → Privacy & Security → Screen & System Audio Recording."
            case .aggregateCreationFailed(let s): return "Couldn't create the tap aggregate device (status \(s))."
            case .formatUnavailable: return "Couldn't read the tap's audio format."
            case .startFailed(let s): return "Couldn't start system-audio capture (status \(s))."
            }
        }
    }

    /// Called on an internal queue with 16 kHz mono Float32 buffers.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    private(set) var isRunning = false

    private let queue = DispatchQueue(label: "otto.meeting.systemtap")
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var converter: AVAudioConverter?
    private var tapFormat: AVAudioFormat?
    private var targetFormat: AVAudioFormat?

    // MARK: - Start / stop

    func start() throws {
        guard !isRunning else { return }

        // Mono mixdown of everything the system plays, except Otto itself
        // (so voice-mode TTS or notification sounds never leak into the
        // meeting transcript as "Them").
        var excluded: [AudioObjectID] = []
        if let own = Self.ownProcessObject() { excluded.append(own) }
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: excluded)
        description.name = "Otto Meeting Tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr, tap != kAudioObjectUnknown else {
            throw TapError.tapCreationFailed(status)
        }
        tapID = tap

        // Private aggregate device anchored on the default output device,
        // carrying the tap. The tap's audio arrives as the aggregate's input.
        let outputUID = Self.defaultOutputDeviceUID() ?? ""
        let aggDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Otto Meeting Capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]

        var aggregate = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggDescription as CFDictionary, &aggregate)
        guard status == noErr, aggregate != kAudioObjectUnknown else {
            cleanupTap()
            throw TapError.aggregateCreationFailed(status)
        }
        aggregateID = aggregate

        guard let format = Self.tapStreamFormat(tapID),
              let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: MicCapture.targetSampleRate,
                channels: 1,
                interleaved: false
              ),
              let conv = AVAudioConverter(from: format, to: target)
        else {
            cleanupAggregate()
            cleanupTap()
            throw TapError.formatUnavailable
        }
        tapFormat = format
        targetFormat = target
        converter = conv

        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) {
            [weak self] _, inInputData, _, _, _ in
            self?.handleIO(inInputData)
        }
        guard status == noErr, let procID else {
            cleanupAggregate()
            cleanupTap()
            throw TapError.startFailed(status)
        }
        ioProcID = procID

        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            ioProcID = nil
            cleanupAggregate()
            cleanupTap()
            throw TapError.startFailed(status)
        }

        isRunning = true
        NSLog("[SystemTap] started (format: %.0f Hz, %d ch)", format.sampleRate, format.channelCount)
    }

    func stop() {
        guard isRunning else { return }
        if let procID = ioProcID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        ioProcID = nil
        cleanupAggregate()
        cleanupTap()
        converter = nil
        tapFormat = nil
        targetFormat = nil
        isRunning = false
        NSLog("[SystemTap] stopped")
    }

    private func cleanupTap() {
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func cleanupAggregate() {
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: - IO

    private func handleIO(_ inputData: UnsafePointer<AudioBufferList>) {
        guard let tapFormat, let targetFormat, let converter else { return }
        guard let inBuf = AVAudioPCMBuffer(
            pcmFormat: tapFormat, bufferListNoCopy: inputData, deallocator: nil
        ), inBuf.frameLength > 0 else { return }

        let ratio = targetFormat.sampleRate / tapFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(inBuf.frameLength) * ratio + 64)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { return }

        var error: NSError?
        var provided = false
        converter.convert(to: outBuf, error: &error) { _, status in
            if provided {
                status.pointee = .noDataNow
                return nil
            }
            provided = true
            status.pointee = .haveData
            return inBuf
        }
        if error != nil || outBuf.frameLength == 0 { return }
        onBuffer?(outBuf)
    }

    // MARK: - Core Audio helpers

    private static func ownProcessObject() -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &pid) { pidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &addr,
                UInt32(MemoryLayout<pid_t>.size), pidPtr, &size, &object
            )
        }
        guard status == noErr, object != kAudioObjectUnknown else { return nil }
        return object
    }

    private static func defaultOutputDeviceUID() -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else { return nil }

        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString? = nil
        var uidSize = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(deviceID, &uidAddr, 0, nil, &uidSize, ptr)
        }
        guard status == noErr, let uid else { return nil }
        return uid as String
    }

    private static func tapStreamFormat(_ tap: AudioObjectID) -> AVAudioFormat? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &asbd) == noErr else { return nil }
        return AVAudioFormat(streamDescription: &asbd)
    }
}
