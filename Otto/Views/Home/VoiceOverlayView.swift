import SwiftUI

/// Full-screen voice-mode overlay presented over OttoChatView.
/// Starts the voice session on appear and tears it down on dismiss.
struct VoiceOverlayView: View {
    @Environment(AppState.self) private var appState

    /// Binding used by the parent to dismiss the overlay.
    @Binding var isPresented: Bool

    /// Animated pulse phase for the idle/listening orb breathing effect.
    @State private var pulsePhase: Double = 0

    var body: some View {
        ZStack {
            // Dimmed background with a faint radial glow.
            Rectangle()
                .fill(Theme.Colors.background)
                .ignoresSafeArea()
                .overlay(
                    RadialGradient(
                        colors: [orbColor.opacity(0.15), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 400
                    )
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                )

            VStack(spacing: Theme.Spacing.xl) {
                HStack {
                    Spacer()
                    Button {
                        appState.voice.stop()
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.Colors.secondaryText)
                            .frame(width: 32, height: 32)
                            .background(Theme.Colors.secondaryBackground)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.top, Theme.Spacing.lg)

                Spacer()

                orb

                phaseLabel

                transcriptView

                Spacer()
            }
        }
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
        let passiveScale = 1.0 + 0.03 * pulsePhase
        let activeScale = 1.0 + 0.35 * level
        let scale = max(passiveScale, activeScale)

        return ZStack {
            // Outer bloom.
            Circle()
                .fill(orbColor.opacity(0.18))
                .frame(width: 260, height: 260)
                .blur(radius: 40)

            // Mid ring.
            Circle()
                .stroke(orbColor.opacity(0.35), lineWidth: 1)
                .frame(width: 200, height: 200)

            // Core gradient.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [orbColor.opacity(0.95), orbColor.opacity(0.25), .clear],
                        center: .center,
                        startRadius: 10,
                        endRadius: 110
                    )
                )
                .frame(width: 180, height: 180)
                .overlay(
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [orbColor.opacity(0.8), orbColor.opacity(0.3)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.5
                        )
                )
                .shadow(color: orbColor.opacity(0.55), radius: 20, x: 0, y: 0)
                .shadow(color: orbColor.opacity(0.30), radius: 50, x: 0, y: 0)
        }
        .scaleEffect(scale)
        .animation(.easeOut(duration: 0.12), value: level)
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
        case .error: return .orange
        default: return Theme.Colors.accent
        }
    }

    // MARK: - Phase label

    private var phaseLabel: some View {
        VStack(spacing: Theme.Spacing.xs) {
            Text(phaseText)
                .font(Theme.Typography.headline)
                .foregroundStyle(orbColor)

            Text(phaseHint)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
    }

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
        case .thinking: return "Working on your request…"
        case .speaking: return "Start talking anytime to interrupt."
        case .error(let msg): return msg
        }
    }

    // MARK: - Transcript

    @ViewBuilder
    private var transcriptView: some View {
        let user = appState.voice.liveTranscript
        let assistant = appState.voice.lastResponse

        VStack(spacing: Theme.Spacing.md) {
            if !user.isEmpty {
                transcriptBubble(label: "You", text: user, color: Theme.Colors.accent)
            }
            if !assistant.isEmpty {
                transcriptBubble(label: "Otto", text: assistant, color: Theme.Colors.aiAccent)
            }
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, Theme.Spacing.xl)
    }

    private func transcriptBubble(label: String, text: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(label.uppercased())
                .font(Theme.Typography.small)
                .foregroundStyle(color.opacity(0.8))
            Text(text)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.text)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .fill(Theme.Colors.secondaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.lg)
                        .strokeBorder(color.opacity(0.2), lineWidth: 0.5)
                )
        )
    }
}
