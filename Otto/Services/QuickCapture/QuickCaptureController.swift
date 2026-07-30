import Foundation

#if os(macOS)
import AppKit
import SwiftUI
import UserNotifications

// MARK: - Panel

/// Borderless Spotlight-style panel that can become key without activating
/// Otto — the whole point is capturing a thought from inside another app
/// without yanking focus away from it. `.nonactivatingPanel` handles the
/// activation side; `canBecomeKey` is required on top because borderless
/// windows refuse key status by default (no typing otherwise).
private final class QuickCapturePanel: NSPanel {
    var onEscape: (() -> Void)?
    var onResignKey: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    /// While Otto is inactive its main menu isn't in the key-equivalent path,
    /// so ⌘V/⌘C/⌘X/⌘A/⌘Z would dead-end. Route the standard edit commands
    /// down the responder chain (the field editor) by hand.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .command, let key = event.charactersIgnoringModifiers?.lowercased() {
            let action: Selector?
            switch key {
            case "v": action = #selector(NSText.paste(_:))
            case "c": action = #selector(NSText.copy(_:))
            case "x": action = #selector(NSText.cut(_:))
            case "a": action = #selector(NSText.selectAll(_:))
            case "z": action = Selector(("undo:"))
            default:  action = nil
            }
            if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        }
        if mods == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "z",
           NSApp.sendAction(Selector(("redo:")), to: nil, from: self) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Controller

/// Owns the quick-capture feature: the global shortcut registration and the
/// floating input panel it summons. Press the chord anywhere → panel appears
/// over the current app → type → ⏎ → panel vanishes and the prompt runs as a
/// normal background chat turn (`ChatRunController.send`), so it lands in
/// chat history, uses the full tool belt, and survives the panel having no
/// UI attached — the same headless mechanism voice mode uses.
///
/// Lifecycle mirrors `MenuBarController`: an imperative singleton `OttoApp`
/// installs/uninstalls when the Settings toggle flips.
@Observable
@MainActor
final class QuickCaptureController {
    static let shared = QuickCaptureController()

    /// True when the last `RegisterEventHotKey` attempt was refused — almost
    /// always another app holding the chord. Settings shows a warning and the
    /// recorder stays usable so the user can pick a different chord.
    private(set) var registrationFailed = false
    /// Captures still running in the background — shown as a hint in the
    /// panel so firing several in a row feels accounted for. Counts only
    /// sessions this panel started, not chats sent from the main window.
    var runningCaptureCount: Int {
        guard let appState else { return 0 }
        return captureSessionIds.filter { appState.chatRuns.isRunning($0) }.count
    }

    let model = QuickCaptureModel()

    /// Sessions minted by `submit` — membership only changes while the panel
    /// is hidden, so the ignored-observation wrapper is safe: the visible
    /// count re-derives from each run's observable `isRunning`.
    @ObservationIgnored private var captureSessionIds: Set<UUID> = []
    /// Display the panel was last summoned on — the one the user is looking
    /// at, so it's the one the "Screen" toggle captures.
    @ObservationIgnored private var lastShownDisplayID: CGDirectDisplayID?
    @ObservationIgnored private weak var appState: AppState?
    @ObservationIgnored private var panel: QuickCapturePanel?
    @ObservationIgnored private var hostingView: NSHostingView<QuickCaptureView>?
    @ObservationIgnored private var isInstalled = false

    private init() {}

    // MARK: Install / uninstall

    /// Hand over AppState without touching hotkey registration — lets the
    /// menu-bar entry open the panel even while the global shortcut is
    /// toggled off in Settings.
    func configure(appState: AppState) {
        self.appState = appState
    }

    func install(appState: AppState) {
        configure(appState: appState)
        isInstalled = true
        QuickCaptureHotKey.shared.onPressed = { [weak self] in self?.togglePanel() }
        reloadShortcut()
    }

    func uninstall() {
        isInstalled = false
        QuickCaptureHotKey.shared.unregister()
        hidePanel()
    }

    /// Re-register from the persisted shortcut — called after install and
    /// whenever the Settings recorder saves a new chord.
    func reloadShortcut() {
        guard isInstalled else { return }
        registrationFailed = !QuickCaptureHotKey.shared.register(QuickCaptureSettings.currentShortcut)
    }

    /// The Settings recorder needs the next keystroke for itself — while it
    /// records, the registered chord must not fire (or pressing the current
    /// shortcut to redefine it would toggle the panel instead).
    func setSuspended(_ suspended: Bool) {
        guard isInstalled else { return }
        if suspended {
            QuickCaptureHotKey.shared.unregister()
        } else {
            reloadShortcut()
        }
    }

    // MARK: Panel

    func togglePanel() {
        if panel?.isVisible == true {
            hidePanel()
        } else {
            showPanel()
        }
    }

    func showPanel() {
        guard appState != nil else { return }
        let panel = ensurePanel()
        model.text = ""
        model.includeScreen = false
        layout(panel)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        // Ask the field for focus after key status settles — bumping the
        // epoch inside this async hop is what makes focus land reliably in a
        // just-created nonactivating panel.
        DispatchQueue.main.async { [model] in model.focusEpoch += 1 }
    }

    func hidePanel() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
    }

    // MARK: Submit

    /// Enter pressed: dismiss instantly, then run the prompt as a fresh
    /// background conversation. The audible tick is the "got it" — the panel
    /// is already gone by the time the agent starts working. With the
    /// "Screen" toggle armed, the display the panel was on is screenshotted
    /// (after the panel is out of the shot) and staged for the agent via the
    /// same `pendingScreenshotPath` handoff the screen-vision intent uses.
    func submit() {
        let text = model.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let wantsScreen = model.includeScreen
        hidePanel()
        guard !text.isEmpty, let appState else { return }
        Sounds.play(.wake)

        let controller = appState.chatRuns.openController(for: nil, appState: appState)
        // Drop finished ids so the set stays bounded across a long app run.
        captureSessionIds = captureSessionIds.filter { appState.chatRuns.isRunning($0) }
        captureSessionIds.insert(controller.sessionId)

        let displayID = lastShownDisplayID
        Task {
            var contextNote: String?
            if wantsScreen {
                // Give the window server a beat to take the panel down so the
                // shot shows what's behind it, not the capture box itself.
                try? await Task.sleep(nanoseconds: 150_000_000)
                do {
                    let url = try await ScreenCaptureService.shared.captureMainDisplay(preferring: displayID)
                    appState.pendingScreenshotPath = url.path
                    contextNote = Self.screenshotContextNote
                } catch {
                    // Send the prompt anyway — but tell the user Otto is
                    // working blind (likely a Screen Recording permission
                    // denial on first use).
                    NSLog("[QuickCapture] screen capture failed: %@", error.localizedDescription)
                    await Self.postNotification(
                        title: "Couldn't capture your screen",
                        body: "\(error.localizedDescription) Your prompt was sent without it.",
                        sessionId: controller.sessionId
                    )
                }
            }
            controller.send(text: text, attachments: [], appState: appState, contextNote: contextNote)
            watchForCompletion(of: controller, prompt: text, appState: appState)
        }
    }

    /// Mirrors `IntentRouter.contextNote(for: .screenVision)`'s mechanics but
    /// neutral in tone — quick-capture prompts are typed, not spoken, and the
    /// user's request (not a canned summary) drives what happens next.
    private static let screenshotContextNote = """
    [A screenshot of the user's screen, taken the moment they sent this, is saved as `./screenshot.png` in your current working directory. Use the `Read` tool on that exact path — it loads as visual input. The request above refers to what's visible there. Don't describe the screenshot mechanics unless asked.]
    """

    // MARK: Completion notification

    /// Poll the run until it settles, then post a local notification with the
    /// agent's final answer (or the failure). Skipped when the user is
    /// already looking at that conversation in Otto. Polling is fine here:
    /// runs last seconds-to-minutes and one sleeping task per capture is
    /// cheap; a 20-minute cap abandons watching runaway runs.
    private func watchForCompletion(of controller: ChatRunController, prompt: String, appState: AppState) {
        Task { [weak appState] in
            // First ask is a no-op if permission was already decided; doing it
            // here (not at install) means the system prompt appears right
            // after the user's first capture, when it makes obvious sense.
            _ = await NotificationService.shared.requestAuthorization()

            let deadline = Date().addingTimeInterval(20 * 60)
            while controller.isRunning, Date() < deadline {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard !controller.isRunning, let appState else { return }

            // User already watching this conversation → banner is noise.
            if NSApp.isActive, appState.activeChatSessionId == controller.sessionId { return }

            let body: String
            if let error = controller.error {
                body = "Couldn't finish: \(error)"
            } else {
                body = Self.completionSummary(from: controller.turns)
            }
            await Self.postNotification(
                title: Self.truncated(prompt, to: 60),
                body: body,
                sessionId: controller.sessionId
            )
        }
    }

    /// Last assistant text of the run — what the user would see as the final
    /// chat bubble — squeezed into notification size.
    private static func completionSummary(from turns: [ChatTurn]) -> String {
        for turn in turns.reversed() where turn.role == "assistant" {
            let texts = turn.blocks.compactMap { block -> String? in
                if case .text(let s) = block {
                    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }
                return nil
            }
            if let last = texts.last {
                return truncated(last, to: 180)
            }
        }
        return "Done — open Otto to see the result."
    }

    private static func truncated(_ s: String, to limit: Int) -> String {
        s.count <= limit ? s : String(s.prefix(limit - 1)) + "…"
    }

    private static func postNotification(title: String, body: String, sessionId: UUID) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["chatSessionId": sessionId.uuidString]
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil  // deliver immediately
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    // MARK: Panel construction

    private func ensurePanel() -> QuickCapturePanel {
        if let panel { return panel }

        let hosting = NSHostingView(rootView: QuickCaptureView(model: model, controller: self))
        let panel = QuickCapturePanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.animationBehavior = .utilityWindow
        panel.contentView = hosting
        panel.isReleasedWhenClosed = false
        panel.onEscape = { [weak self] in self?.hidePanel() }
        // Click-away anywhere (or the OS taking key for any reason) dismisses,
        // matching Spotlight. `isVisible` guards the resign that orderOut
        // itself triggers.
        panel.onResignKey = { [weak self] in
            guard let self, self.panel?.isVisible == true else { return }
            self.hidePanel()
        }

        self.panel = panel
        self.hostingView = hosting
        return panel
    }

    /// Fixed 640-pt column, horizontally centered, top third of whichever
    /// screen the pointer is on — Spotlight geometry, on the display the
    /// user is actually working on.
    private func layout(_ panel: QuickCapturePanel) {
        guard let hostingView else { return }
        let size = hostingView.fittingSize
        guard size.width > 1, size.height > 1 else { return }

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        lastShownDisplayID = (screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber)?.uint32Value
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - visible.height * 0.26 - size.height
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}
#endif
