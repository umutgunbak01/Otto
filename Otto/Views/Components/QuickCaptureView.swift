import SwiftUI

#if os(macOS)
import AppKit

// MARK: - Model

/// Shared between `QuickCaptureController` (which clears text and bumps the
/// focus epoch on every show) and the SwiftUI face below.
@Observable
@MainActor
final class QuickCaptureModel {
    var text: String = ""
    /// Incremented after the panel becomes key — the view responds by
    /// re-requesting field focus. A plain Bool wouldn't retrigger on the
    /// second show.
    var focusEpoch: Int = 0
    /// "See my screen" toggle — when armed, submit screenshots the panel's
    /// display and stages it for the agent. Reset to off on every show so a
    /// screenshot only ever leaves the machine when explicitly asked for.
    var includeScreen: Bool = false
}

// MARK: - Panel face

/// The Spotlight-style input row: brand glyph, a single-line prompt field,
/// and a ⏎ hint. Kept deliberately spare — the panel exists for the two
/// seconds it takes to type a thought.
struct QuickCaptureView: View {
    @Bindable var model: QuickCaptureModel
    let controller: QuickCaptureController

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Spacing.md) {
                brandGlyph

                TextField("Ask Otto — it runs in the background", text: $model.text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Theme.Colors.text)
                    .focused($focused)
                    .onSubmit { controller.submit() }

                screenToggle

                returnHint
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, 14)

            if controller.runningCaptureCount > 0 {
                runningFooter
            }
        }
        .frame(width: 640)
        .background(Theme.Colors.bg1)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xxl))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.xxl)
                .strokeBorder(Theme.Colors.borderStrong, lineWidth: 1)
        )
        .onExitCommand { controller.hidePanel() }
        .onAppear { focused = true }
        .onChange(of: model.focusEpoch) { _, _ in focused = true }
    }

    /// Same mark as the About pane: "O" on an accent-tinted rounded square.
    private var brandGlyph: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Colors.selectTint)
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .strokeBorder(Theme.Colors.cyan.opacity(0.3), lineWidth: 1)
            Text("O")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.Colors.accentText)
        }
        .frame(width: 28, height: 28)
    }

    /// "See my screen" arm switch. Armed → ⏎ screenshots the display this
    /// panel is on and hands it to the agent alongside the prompt.
    private var screenToggle: some View {
        Button {
            model.includeScreen.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: model.includeScreen ? "eye.fill" : "eye")
                    .font(.system(size: 11, weight: .medium))
                Text("Screen")
                    .font(Theme.Typography.caption)
            }
            .foregroundStyle(model.includeScreen ? Theme.Colors.accentText : Theme.Colors.tertiaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(model.includeScreen ? Theme.Colors.selectTint : Theme.Colors.borderSubtle)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .strokeBorder(
                        model.includeScreen ? Theme.Colors.cyan.opacity(0.4) : Color.clear,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .help("Send a screenshot of this screen to Otto with your prompt")
    }

    private var returnHint: some View {
        Text("⏎")
            .font(Theme.Typography.monoCaption)
            .foregroundStyle(Theme.Colors.tertiaryText)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(Theme.Colors.borderSubtle)
            )
    }

    private var runningFooter: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Theme.Colors.cyan)
                .frame(width: 5, height: 5)
            Text(footerLabel)
                .font(Theme.Typography.monoSmall)
                .foregroundStyle(Theme.Colors.textDim)
            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
        .background(Theme.Colors.bg0.opacity(0.6))
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.Colors.borderSubtle).frame(height: 1)
        }
    }

    private var footerLabel: String {
        let count = controller.runningCaptureCount
        return count == 1
            ? "1 capture running in the background"
            : "\(count) captures running in the background"
    }
}

// MARK: - Shortcut recorder (Settings)

/// Click-to-record control for the quick-capture chord. While recording, the
/// registered global hotkey is suspended so pressing the current chord
/// redefines it instead of toggling the panel. Esc cancels; chords without a
/// real modifier (⌘/⌃/⌥ or an F-key) are rejected with a beep.
struct QuickCaptureShortcutRecorder: View {
    @State private var shortcut = QuickCaptureSettings.currentShortcut
    @State private var isRecording = false
    @State private var keyMonitor: Any?

    var body: some View {
        Button {
            isRecording ? stopRecording() : startRecording()
        } label: {
            Text(isRecording ? "Press shortcut…" : shortcut.display)
                .font(Theme.Typography.monoCaption)
                .foregroundStyle(isRecording ? Theme.Colors.accentText : Theme.Colors.text)
                .frame(minWidth: 90)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, 7)
                .background(Theme.Colors.bgInput)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(
                            isRecording ? Theme.Colors.cyan.opacity(0.6) : Theme.Colors.border,
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
        .onDisappear { if isRecording { stopRecording() } }
    }

    private func startRecording() {
        isRecording = true
        QuickCaptureController.shared.setSuspended(true)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {  // Esc — keep the existing chord
                stopRecording()
                return nil
            }
            guard let recorded = QuickCaptureShortcut(event: event) else {
                NSSound.beep()
                return nil
            }
            QuickCaptureSettings.save(recorded)
            shortcut = recorded
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        isRecording = false
        // Re-registers from UserDefaults, so a freshly saved chord (or the
        // untouched old one on cancel) goes live immediately.
        QuickCaptureController.shared.setSuspended(false)
    }
}
#endif
