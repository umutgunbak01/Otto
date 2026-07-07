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
        "Brief me on tomorrow",
        "Draft reply to Sam",
        "Show high-priority todos",
        "Summarize last meeting"
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
            ZStack(alignment: .leading) {
                if text.isEmpty && !focused {
                    HStack(spacing: 4) {
                        IdlePhraseText(index: phraseIndex)
                        BlinkingCursor()
                    }
                }
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.Colors.text)
                    .focused($focused)
                    .onSubmit { send() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.xl)
                .fill(Theme.Colors.bgInput)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.xl)
                .strokeBorder(focused ? Theme.Colors.accent : Theme.Colors.borderStrong, lineWidth: 1)
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
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.Colors.onAccent)
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .fill(Theme.Colors.accent)
                )
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
                    .fill(Theme.Colors.bgInput)
                    .overlay(
                        Circle().strokeBorder(Theme.Colors.borderStrong, lineWidth: 1)
                    )
                    .frame(width: 50, height: 50)

                // Either a static mic icon or a small equalizer when active.
                if isIdle {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.Colors.textDim)
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
                    canvas.fill(path, with: .color(Theme.Colors.accent))
                }
            }
            .frame(height: 16)
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
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.Colors.tertiaryText)
        }
    }
}

// MARK: - Blinking cursor

private struct BlinkingCursor: View {
    var body: some View {
        // 1Hz cadence — a 500ms cursor blink looks the same as 250ms.
        TimelineView(.periodic(from: .now, by: 1.0)) { ctx in
            let on = Int(ctx.date.timeIntervalSinceReferenceDate) % 2 == 0
            RoundedRectangle(cornerRadius: 1)
                .fill(Theme.Colors.accent)
                .frame(width: 2, height: 14)
                .opacity(on ? 1 : 0)
        }
    }
}
