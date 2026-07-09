import SwiftUI

/// Compact voice-mode panel floating at the bottom of the window. The regular
/// chat interface stays visible (and interactive) behind it — the voice
/// session mirrors its turns into a chat conversation, so text, tool chips,
/// and preview cards stream into the chat while Otto speaks.
/// Starts the voice session on appear and tears it down on dismiss.
struct VoiceOverlayView: View {
    @Environment(AppState.self) private var appState

    /// Binding used by the parent to dismiss the overlay.
    @Binding var isPresented: Bool

    /// Animated pulse phase for the idle/listening orb breathing effect.
    @State private var pulsePhase: Double = 0

    var body: some View {
        VStack {
            Spacer()
            panel
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await appState.voice.start(appState: appState)
            updatePulseAnimation(for: appState.voice.phase)
        }
        .onChange(of: appState.voice.phase) { _, newPhase in
            updatePulseAnimation(for: newPhase)
        }
        .onDisappear {
            appState.voice.stop()
        }
    }

    // MARK: - Panel

    private var panel: some View {
        HStack(spacing: Theme.Spacing.md) {
            orb

            VStack(alignment: .leading, spacing: 2) {
                Text(phaseText)
                    .font(Theme.Typography.headline)
                    .foregroundStyle(orbColor)
                Text(phaseHint)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .lineLimit(2)
            }
            .frame(maxWidth: 340, alignment: .leading)

            if canInterrupt {
                Button {
                    appState.voice.interrupt()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(orbColor)
                        .frame(width: 26, height: 26)
                        .background(orbColor.opacity(0.15))
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(orbColor.opacity(0.4), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Interrupt Otto — back to listening")
            }

            Button {
                appState.voice.stop()
                isPresented = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .frame(width: 26, height: 26)
                    .background(Theme.Colors.secondaryBackground)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("End voice mode")
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .fill(Theme.Colors.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.lg)
                        .strokeBorder(orbColor.opacity(0.25), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.35), radius: 24, x: 0, y: 8)
        )
    }

    private func updatePulseAnimation(for phase: VoiceSessionManager.Phase) {
        switch phase {
        case .listening, .speaking:
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                pulsePhase = 1
            }
        default:
            withAnimation(.easeOut(duration: 0.3)) {
                pulsePhase = 0
            }
        }
    }

    // MARK: - Orb

    private var orb: some View {
        let level = CGFloat(currentLevel)
        let passiveScale = 1.0 + 0.04 * pulsePhase
        let activeScale = 1.0 + 0.30 * level
        let scale = max(passiveScale, activeScale)

        return ZStack {
            Circle()
                .fill(orbColor.opacity(0.20))
                .frame(width: 52, height: 52)
                .blur(radius: 8)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [orbColor.opacity(0.95), orbColor.opacity(0.30), .clear],
                        center: .center,
                        startRadius: 3,
                        endRadius: 26
                    )
                )
                .frame(width: 42, height: 42)
                .overlay(
                    Circle()
                        .stroke(orbColor.opacity(0.6), lineWidth: 1)
                )
                .shadow(color: orbColor.opacity(0.5), radius: 8, x: 0, y: 0)
        }
        .frame(width: 52, height: 52)
        .scaleEffect(scale)
        .animation(.easeOut(duration: 0.12), value: level)
    }

    /// Interrupt is only meaningful while a turn is in flight.
    private var canInterrupt: Bool {
        switch appState.voice.phase {
        case .thinking, .speaking: return true
        default: return false
        }
    }

    private var currentLevel: Float {
        switch appState.voice.phase {
        case .speaking: return appState.voice.outputLevel
        case .listening, .transcribing, .thinking: return appState.voice.inputLevel
        default: return 0
        }
    }

    private var orbColor: Color {
        switch appState.voice.phase {
        case .speaking: return Theme.Colors.aiAccent
        case .error: return Theme.Colors.amber
        default: return Theme.Colors.accent
        }
    }

    // MARK: - Phase label

    private var phaseText: String {
        switch appState.voice.phase {
        case .idle: return "Starting…"
        case .listening: return "Listening"
        case .transcribing: return "Transcribing"
        case .thinking: return "Thinking"
        case .speaking: return "Speaking"
        case .error: return "Voice error"
        }
    }

    private var phaseHint: String {
        switch appState.voice.phase {
        case .idle: return "Waking up the mic…"
        case .listening: return "Just start talking — Otto will reply when you pause."
        case .transcribing: return "Catching what you said…"
        case .thinking: return "Working on your request — hit stop to cancel."
        case .speaking: return "Hit stop to interrupt."
        case .error(let msg): return msg
        }
    }
}
