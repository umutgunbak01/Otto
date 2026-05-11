import SwiftUI

/// Bottom dock — mic button on the left, prompt input in the middle, send
/// button on the right. Suggestion chips float above the bar.
///
/// Performance notes
/// -----------------
/// Each of the small animated bits (orbit ring, equalizer, blinking cursor,
/// rotating idle phrase) is in its own scoped subview so its TimelineView
/// only redraws *that* element, not the whole dock.
struct OttoDock: View {
    @Environment(AppState.self) private var appState
    @State private var text: String = ""
    @State private var phraseIndex: Int = 0
    @FocusState private var focused: Bool

    var onSend: ((String) -> Void)?
    var onMic: (() -> Void)?

    var suggestions: [String] = [
        "▸ Brief me on tomorrow",
        "▸ Draft reply to Sam",
        "▸ Show high-priority todos",
        "▸ Summarize last meeting"
    ]

    var body: some View {
        ZStack(alignment: .top) {
            // Floating chips above the dock. Scroll horizontally when the
            // window is too narrow to fit all chips on one row.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(suggestions, id: \.self) { s in
                        OttoChip(text: s) {
                            text = s.replacingOccurrences(of: "▸ ", with: "")
                            focused = true
                        }
                    }
                }
                .padding(.horizontal, 80)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .offset(y: -42)

            // Dock body.
            HStack(spacing: 14) {
                MicButton(phase: appState.voice.phase, action: { onMic?() })
                promptField
                sendButton
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 80)
            .angledPanel(.dockTop(14))
        }
    }

    // MARK: - Prompt

    private var promptField: some View {
        HStack(spacing: 12) {
            Text("OTTO >")
                .font(.system(size: 12, weight: .heavy, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(Theme.Colors.cyan)
                .shadow(color: Theme.Colors.cyanGlow, radius: 4)

            ZStack(alignment: .leading) {
                if text.isEmpty && !focused {
                    HStack(spacing: 4) {
                        IdlePhraseText(index: phraseIndex)
                        BlinkingCursor()
                    }
                }
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(Theme.Colors.text)
                    .focused($focused)
                    .onSubmit { send() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            AngledPanelShape(cut: .parallelogram(8))
                .fill(Theme.Colors.bg1.opacity(0.5))
        )
        .overlay(
            AngledPanelShape(cut: .parallelogram(8))
                .stroke(focused ? Theme.Colors.cyan : Theme.Colors.cyan.opacity(0.25), lineWidth: 1)
        )
        .onAppear {
            // Rotate the idle phrase every 3.5s — driven by a timeline scoped
            // inside `IdlePhraseText` so it doesn't re-tick the whole prompt.
            startPhraseRotation()
        }
    }

    private func startPhraseRotation() {
        // Note: this is a one-shot install — we just kick the index forward.
        // The `IdlePhraseText` view has its own internal cadence.
        phraseIndex = 0
    }

    // MARK: - Send

    private var sendButton: some View {
        Button {
            send()
        } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.Colors.cyan)
                .frame(width: 44, height: 44)
                .background(
                    AngledPanelShape(cut: .topRightBottomLeft(8))
                        .fill(Theme.Colors.cyan.opacity(0.12))
                )
                .overlay(
                    AngledPanelShape(cut: .topRightBottomLeft(8))
                        .stroke(Theme.Colors.cyan, lineWidth: 1)
                )
                .shadow(color: Theme.Colors.cyanGlow, radius: 10)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
        .opacity(text.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
    }

    private func send() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSend?(trimmed)
        text = ""
    }
}

// MARK: - Mic button (own subview for scoped animations)

private struct MicButton: View {
    let phase: VoiceSessionManager.Phase
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                // Static base.
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Theme.Colors.cyan.opacity(0.2), .clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 28
                        )
                    )
                    .overlay(
                        Circle().stroke(Theme.Colors.cyan, lineWidth: 1.5)
                    )
                    .shadow(color: Theme.Colors.cyanGlow, radius: 14)
                    .frame(width: 50, height: 50)

                // Rotating dashed orbit — scoped TimelineView, 12fps.
                OrbitRing()

                // Either a static mic icon or a small equalizer when active.
                if isIdle {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.Colors.cyan)
                } else {
                    MicEqualizer()
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var isIdle: Bool {
        if case .idle = phase { return true }
        return false
    }
}

private struct OrbitRing: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let angle = (t.truncatingRemainder(dividingBy: 8) / 8) * 360
            Circle()
                .strokeBorder(
                    Theme.Colors.cyan.opacity(0.4),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                )
                .frame(width: 62, height: 62)
                .rotationEffect(.degrees(angle))
        }
    }
}

private struct MicEqualizer: View {
    var body: some View {
        // Single Canvas — five bars in one paint pass at 24fps.
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { ctx in
            Canvas { canvas, size in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let barW: CGFloat = 2
                let spacing: CGFloat = 2
                let totalW = barW * 5 + spacing * 4
                let startX = (size.width - totalW) / 2
                let baseY = size.height
                for i in 0..<5 {
                    let phase = (t + Double(i) * 0.1).truncatingRemainder(dividingBy: 0.9) / 0.9
                    let h = 4.0 + abs(sin(phase * .pi)) * 12
                    let x = startX + CGFloat(i) * (barW + spacing)
                    let rect = CGRect(x: x, y: baseY - h, width: barW, height: h)
                    let path = Path(roundedRect: rect, cornerRadius: 1)
                    canvas.fill(path, with: .color(Theme.Colors.cyan))
                }
            }
            .frame(height: 16)
            .shadow(color: Theme.Colors.cyanGlow, radius: 2)
        }
    }
}

// MARK: - Idle phrase (rotates inside its own scoped timeline)

private struct IdlePhraseText: View {
    var index: Int
    private static let phrases = [
        "awaiting directive…",
        "what do you need, boss?",
        "try: \"brief me on today\"",
        "try: \"draft reply to Sam\"",
        "all systems nominal."
    ]

    var body: some View {
        // 3.5s rotation, cheap.
        TimelineView(.periodic(from: .now, by: 3.5)) { ctx in
            let bucket = Int(ctx.date.timeIntervalSinceReferenceDate / 3.5)
            let i = (bucket + index) % Self.phrases.count
            Text(Self.phrases[abs(i)])
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .tracking(1.0)
                .foregroundStyle(Theme.Colors.textDim)
        }
    }
}

// MARK: - Blinking cursor

private struct BlinkingCursor: View {
    var body: some View {
        // 1Hz cadence — a 500ms cursor blink looks the same as 250ms.
        TimelineView(.periodic(from: .now, by: 1.0)) { ctx in
            let on = Int(ctx.date.timeIntervalSinceReferenceDate) % 2 == 0
            Rectangle()
                .fill(Theme.Colors.cyan)
                .frame(width: 8, height: 14)
                .opacity(on ? 1 : 0)
        }
    }
}
