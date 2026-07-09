import Foundation
import CoreAudio
import AppKit

/// Watches Core Audio's per-process objects to notice when a meeting-capable
/// app starts (or stops) capturing microphone input — the signal that the
/// user joined a meeting in Zoom / Meet / Slack / a browser.
///
/// Detection polls the HAL every `pollInterval` (checking ~40 process objects'
/// `kAudioProcessPropertyIsRunningInput` is microseconds of work), with a
/// process-object-list listener as an accelerator for freshly launched apps.
/// Polling is the backbone because — measured empirically — the HAL does NOT
/// deliver property-changed notifications for per-process IsRunningInput
/// flips; an existing browser process that starts capturing produces no event
/// at all. Only processes matching the `meetingApps` allowlist count — system
/// daemons (dictation's com.apple.CoreSpeech, Siri), voice memos, and other
/// utilities grabbing the mic never trigger a prompt, and Otto's own pid is
/// excluded so the wake-word listener and voice mode can't either.
///
/// Debounce rules:
///   - external mic must stay active ≥ `activationDebounce` before we report it
///     (filters one-shot dictation pops and permission-prompt probes);
///   - it must stay silent ≥ `releaseDebounce` before we report release
///     (mute/unmute and device flaps during a call shouldn't end a recording).
///
/// `onExternalMicActive` fires once per continuous external-mic session; the
/// session resets only after a debounced release, so a dismissed prompt stays
/// dismissed until the next meeting.
final class MeetingDetectionService: @unchecked Sendable {

    // MARK: - Tunables

    /// External mic must be continuously active this long before we prompt.
    private let activationDebounce: TimeInterval = 3
    /// External mic must be continuously inactive this long before we treat
    /// the meeting as over (auto-stops an in-flight recording).
    private let releaseDebounce: TimeInterval = 15
    /// How often to re-check mic-holder state (see class comment for why
    /// polling, not notifications, is the backbone).
    private let pollInterval: TimeInterval = 2

    // MARK: - Callbacks (fired on the main actor)

    /// Another app has been holding the mic for ≥ activationDebounce.
    /// Payload is a human-readable app name ("zoom.us", "Google Chrome", …).
    var onExternalMicActive: ((String) -> Void)?
    /// No external app has held the mic for ≥ releaseDebounce.
    var onExternalMicReleased: (() -> Void)?

    // MARK: - State (all touched on `queue` only)

    private let queue = DispatchQueue(label: "otto.meeting.detection")
    private var monitoring = false
    /// Debounced truth: is a non-Otto process currently in a mic "session"?
    private var externalSessionActive = false
    private var pendingActivation: DispatchWorkItem?
    private var pendingRelease: DispatchWorkItem?
    /// Process objects we've attached an IsRunningInput listener to.
    private var listenedObjects: Set<AudioObjectID> = []

    private var systemListenerBlock: AudioObjectPropertyListenerBlock?
    private var processListenerBlock: AudioObjectPropertyListenerBlock?
    private var pollTimer: DispatchSourceTimer?

    // MARK: - Lifecycle

    func start() {
        queue.async { [weak self] in
            guard let self, !self.monitoring else { return }
            self.monitoring = true

            // Shared block for per-process IsRunningInput flips.
            self.processListenerBlock = { [weak self] _, _ in
                self?.queue.async { self?.evaluate() }
            }
            // Process list changes (apps launching/quitting audio clients).
            self.systemListenerBlock = { [weak self] _, _ in
                self?.queue.async {
                    self?.syncProcessListeners()
                    self?.evaluate()
                }
            }

            var addr = Self.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, self.queue, self.systemListenerBlock!
            )

            self.syncProcessListeners()
            self.evaluate()

            // Poll — the actual detection backbone (see class comment).
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + self.pollInterval, repeating: self.pollInterval)
            timer.setEventHandler { [weak self] in
                self?.syncProcessListeners()
                self?.evaluate()
            }
            timer.resume()
            self.pollTimer = timer

            NSLog("[MeetingDetect] monitoring started (%d audio processes)", self.listenedObjects.count)
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, self.monitoring else { return }
            self.monitoring = false

            self.pollTimer?.cancel()
            self.pollTimer = nil

            if let block = self.systemListenerBlock {
                var addr = Self.address(kAudioHardwarePropertyProcessObjectList)
                AudioObjectRemovePropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject), &addr, self.queue, block
                )
            }
            if let block = self.processListenerBlock {
                var addr = Self.address(kAudioProcessPropertyIsRunningInput)
                for obj in self.listenedObjects {
                    AudioObjectRemovePropertyListenerBlock(obj, &addr, self.queue, block)
                }
            }
            self.listenedObjects.removeAll()
            self.systemListenerBlock = nil
            self.processListenerBlock = nil
            self.pendingActivation?.cancel()
            self.pendingRelease?.cancel()
            self.pendingActivation = nil
            self.pendingRelease = nil
            self.externalSessionActive = false
            NSLog("[MeetingDetect] monitoring stopped")
        }
    }

    // MARK: - Listener bookkeeping (on queue)

    /// Attach IsRunningInput listeners to new process objects, drop dead ones.
    private func syncProcessListeners() {
        guard let block = processListenerBlock else { return }
        let current = Set(Self.processObjectList())
        var addr = Self.address(kAudioProcessPropertyIsRunningInput)

        for obj in current.subtracting(listenedObjects) {
            AudioObjectAddPropertyListenerBlock(obj, &addr, queue, block)
            listenedObjects.insert(obj)
        }
        for obj in listenedObjects.subtracting(current) {
            // Object may already be gone from the HAL; removal errors are moot.
            AudioObjectRemovePropertyListenerBlock(obj, &addr, queue, block)
            listenedObjects.remove(obj)
        }
    }

    // MARK: - Evaluation (on queue)

    /// Recompute "is any non-Otto process capturing mic input" and drive the
    /// debounced session state machine.
    private func evaluate() {
        guard monitoring else { return }
        let holder = Self.externalMicHolder()

        if holder != nil {
            pendingRelease?.cancel()
            pendingRelease = nil

            guard !externalSessionActive, pendingActivation == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.monitoring else { return }
                self.pendingActivation = nil
                // Re-check: still held after the debounce window?
                guard let confirmed = Self.externalMicHolder() else { return }
                self.externalSessionActive = true
                NSLog("[MeetingDetect] external mic active: %@", confirmed)
                Task { @MainActor [weak self] in self?.onExternalMicActive?(confirmed) }
            }
            pendingActivation = work
            queue.asyncAfter(deadline: .now() + activationDebounce, execute: work)
        } else {
            pendingActivation?.cancel()
            pendingActivation = nil

            guard externalSessionActive, pendingRelease == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.monitoring else { return }
                self.pendingRelease = nil
                guard Self.externalMicHolder() == nil else { return }
                self.externalSessionActive = false
                NSLog("[MeetingDetect] external mic released")
                Task { @MainActor [weak self] in self?.onExternalMicReleased?() }
            }
            pendingRelease = work
            queue.asyncAfter(deadline: .now() + releaseDebounce, execute: work)
        }
    }

    // MARK: - Core Audio property plumbing

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func processObjectList() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size
        ) == noErr, size > 0 else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &list
        ) == noErr else { return [] }
        return list
    }

    private static func pid(of object: AudioObjectID) -> pid_t? {
        var addr = address(kAudioProcessPropertyPID)
        var value: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func isRunningInput(_ object: AudioObjectID) -> Bool {
        var addr = address(kAudioProcessPropertyIsRunningInput)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    private static func bundleID(of object: AudioObjectID) -> String? {
        var addr = address(kAudioProcessPropertyBundleID)
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let value else { return nil }
        let str = value as String
        return str.isEmpty ? nil : str
    }

    // MARK: - Meeting-app allowlist

    /// Apps whose mic use means "you're probably in a meeting": dedicated
    /// meeting clients plus browsers (Meet, Teams web, …). Prefix-matched
    /// against the capturing process's bundle id, so helper processes
    /// ("com.google.Chrome.helper", "com.apple.WebKit.GPU") resolve to their
    /// app. `display` overrides the shown name when the capturing process
    /// isn't a resolvable app of its own.
    private static let meetingApps: [(prefix: String, display: String?)] = [
        // Dedicated meeting / call apps
        ("us.zoom.xos", "Zoom"),
        ("com.microsoft.teams", "Microsoft Teams"),
        ("com.cisco.webex", "Webex"),
        ("com.webex", "Webex"),
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.hnc.Discord", "Discord"),
        ("com.apple.FaceTime", "FaceTime"),
        // Browsers — Meet, Teams web, Zoom web, …
        ("com.google.Chrome", nil),
        ("com.apple.Safari", "Safari"),
        ("com.apple.WebKit", "Safari"),   // Safari captures in WebKit helpers
        ("org.mozilla.firefox", "Firefox"),
        ("com.brave.Browser", "Brave"),
        ("com.microsoft.edgemac", "Microsoft Edge"),
        ("company.thebrowser.Browser", "Arc"),
        ("company.thebrowser.dia", "Dia"),
        ("com.operasoftware.Opera", "Opera"),
        ("com.vivaldi.Vivaldi", "Vivaldi"),
    ]

    /// Non-allowlisted mic holders already logged — evaluate() runs every few
    /// seconds and always-on daemons (com.apple.CoreSpeech) would otherwise
    /// spam the log forever. Touched only on the detection queue.
    private static var loggedIgnoredHolders = Set<String>()

    /// The display name of a meeting-capable app currently capturing mic
    /// input, or nil when none is. Non-allowlisted mic holders (dictation,
    /// Siri, voice memos, …) don't trigger the banner — this has no effect
    /// on what gets recorded once transcription is running.
    static func externalMicHolder() -> String? {
        let ownPid = getpid()
        for object in processObjectList() {
            guard isRunningInput(object),
                  let p = pid(of: object), p != ownPid else { continue }
            guard let bid = bundleID(of: object)
                    ?? NSRunningApplication(processIdentifier: p)?.bundleIdentifier
            else { continue }
            guard let match = meetingApps.first(where: {
                bid == $0.prefix || bid.hasPrefix($0.prefix)
            }) else {
                if loggedIgnoredHolders.insert(bid).inserted {
                    NSLog("[MeetingDetect] %@ uses the mic but isn't a meeting app — not prompting (add it to meetingApps if it should)", bid)
                }
                continue
            }
            if let display = match.display { return display }
            return appName(pid: p, bundleID: bid) ?? match.prefix
        }
        return nil
    }

    /// Resolve a nice app name. Mic capture often happens in a helper process
    /// (e.g. "Google Chrome Helper"), so fall back to matching the helper's
    /// bundle id against running applications' bundle ids.
    private static func appName(pid: pid_t, bundleID bid: String) -> String? {
        if let app = NSRunningApplication(processIdentifier: pid), let name = app.localizedName {
            return name
        }
        let lower = bid.lowercased()
        if let match = NSWorkspace.shared.runningApplications.first(where: { app in
            guard let appBid = app.bundleIdentifier?.lowercased(), !appBid.isEmpty else { return false }
            return lower == appBid || lower.hasPrefix(appBid + ".")
        }), let name = match.localizedName {
            return name
        }
        return nil
    }
}
