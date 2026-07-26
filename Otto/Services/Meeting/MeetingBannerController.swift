import Foundation
import AppKit
import SwiftUI

/// Owns the floating top-of-screen meeting banner window.
///
/// The banner is a borderless, non-activating `NSPanel` at status-bar level
/// that joins all Spaces and fullscreen apps — meetings usually run
/// fullscreen, and clicking "Start transcribing" must not steal focus from
/// them. Lifecycle mirrors `MenuBarController`: an imperative singleton the
/// coordinator drives, no SwiftUI `Scene` involved.
@MainActor
final class MeetingBannerController {
    static let shared = MeetingBannerController()

    let model = MeetingBannerModel()

    private var panel: NSPanel?
    private var hostingView: NSHostingView<MeetingBannerView>?

    private init() {}

    // MARK: - Public API

    func showPrompt(appName: String, meetingTitle: String?) {
        // Fresh detection — clear any prep left over from a previous meeting.
        model.resetPrep()
        model.phase = .prompt(appName: appName, meetingTitle: meetingTitle)
        present()
    }

    /// Show the expanded prep panel. `recording: false` = prep-first (opened by
    /// tapping the pill); `recording: true` = recording already underway with
    /// its fields still editable.
    func showExpanded(recording: Bool, startedAt: Date?, systemAudioAvailable: Bool) {
        model.phase = .expanded(
            recording: recording,
            startedAt: startedAt,
            systemAudioAvailable: systemAudioAvailable
        )
        present()
    }

    func hide() {
        model.phase = .hidden
        panel?.orderOut(nil)
    }

    /// Hide only if we're still showing the detection prompt — used when the
    /// meeting app releases the mic before the user reacted.
    func hideIfPrompt() {
        if case .prompt = model.phase { hide() }
    }

    // MARK: - Panel management

    private func present() {
        let panel = ensurePanel()
        relayout()
        // No makeKey — the meeting app keeps focus.
        panel.orderFrontRegardless()
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let hosting = NSHostingView(rootView: MeetingBannerView(model: model))
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false   // the SwiftUI capsule draws its own
        panel.isMovableByWindowBackground = true
        panel.contentView = hosting
        panel.isReleasedWhenClosed = false

        // Keep the banner out of screen shares — the "Transcribing" pill (and
        // the "Meeting detected" prompt) are exactly what the user doesn't want
        // the other party to see. The controller honors the user's setting.
        ScreenCapturePrivacyController.shared.protectBannerPanel(panel)

        self.panel = panel
        self.hostingView = hosting
        return panel
    }

    /// Size to the SwiftUI content and pin to top-center of the main screen,
    /// just under the menu bar / notch. Called on every state change since the
    /// two faces have different widths.
    private func relayout() {
        guard let panel, let hostingView else { return }
        hostingView.rootView = MeetingBannerView(model: model)
        let size = hostingView.fittingSize
        guard size.width > 1, size.height > 1 else { return }

        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - size.height - 6
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}
