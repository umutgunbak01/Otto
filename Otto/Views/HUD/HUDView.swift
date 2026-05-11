import SwiftUI

#if os(macOS)
import AppKit
#endif

/// Compact always-on-top status panel. Four pieces of info, in order:
///   1. Current time + live mic level bar
///   2. Next upcoming meeting (title + countdown)
///   3. Current voice phase, when a session is active
///
/// Rendered in a borderless, translucent `Window` scene configured in
/// `OttoApp`. Sits at the top-right corner by default; draggable anywhere.
struct HUDView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var isHovered = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { timeline in
            content(now: timeline.date)
        }
        .onHover { isHovered = $0 }
        #if os(macOS)
        .background(HUDWindowConfigurator())
        #endif
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(clockString(now))
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                Spacer()
                micLevelBar
            }

            if let next = nextMeeting(now: now) {
                Text("\(meetingCountdown(from: now, to: next.startTime)) · \(next.title)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text("No meetings today")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            if let phaseLabel = currentPhaseLabel {
                Text(phaseLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(phaseColor)
                    .textCase(.uppercase)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
                )
        )
        .overlay(alignment: .topTrailing) {
            // Hover-revealed close button. The HUD window has a borderless
            // styleMask so macOS's native traffic-light close button is
            // suppressed — this is the only way out for the user.
            if isHovered {
                Button {
                    dismissWindow(id: "hud")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .background(Circle().fill(.regularMaterial))
                }
                .buttonStyle(.plain)
                .padding(6)
                .help("Close HUD")
                .transition(.opacity)
            }
        }
        .padding(4)
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    // MARK: - Mic bar

    private var micLevelBar: some View {
        // Fill proportional to inputLevel (0..1). Only updates while a voice
        // session is active; idle shows a flat dim bar.
        let level = CGFloat(appState.voice.inputLevel)
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Theme.Colors.accent, Theme.Colors.aiAccent],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(2, geo.size.width * level))
                    .animation(.easeOut(duration: 0.08), value: level)
            }
        }
        .frame(width: 72, height: 4)
    }

    // MARK: - Derived content

    private func clockString(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: date)
    }

    private func nextMeeting(now: Date) -> CalendarEvent? {
        appState.calendarEvents
            .filter { $0.startTime > now }
            .sorted(by: { $0.startTime < $1.startTime })
            .first
    }

    private func meetingCountdown(from now: Date, to target: Date) -> String {
        let delta = target.timeIntervalSince(now)
        if delta < 60 { return "now" }
        let minutes = Int(delta / 60)
        if minutes < 60 { return "in \(minutes)m" }
        let hours = minutes / 60
        let remMin = minutes % 60
        if remMin == 0 { return "in \(hours)h" }
        return "in \(hours)h\(remMin)m"
    }

    private var currentPhaseLabel: String? {
        switch appState.voice.phase {
        case .idle: return nil
        case .listening:    return "Listening"
        case .transcribing: return "Transcribing"
        case .thinking:     return "Thinking"
        case .speaking:     return "Speaking"
        case .error:        return "Error"
        }
    }

    private var phaseColor: Color {
        switch appState.voice.phase {
        case .speaking: return Theme.Colors.aiAccent
        case .error:    return .orange
        default:        return Theme.Colors.accent
        }
    }
}

#if os(macOS)
/// Finds the NSWindow hosting this view and applies floating-panel behavior:
/// always-on-top, non-activating, no titlebar, clear background, movable
/// by dragging anywhere inside. Runs once on first layout.
private struct HUDWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            window.styleMask = [.borderless, .fullSizeContentView]
            window.isMovableByWindowBackground = true
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = true
            // Don't steal focus from whatever app the user's working in.
            window.hidesOnDeactivate = false
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
