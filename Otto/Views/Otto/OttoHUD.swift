import SwiftUI

/// The home view of the Otto HUD — OttoCore centerpiece, floating data
/// nodes pinned to the four corners, dashed connector lines from each node
/// back to the core, voice-frequency equalizer at the bottom.
struct OttoHUD: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        GeometryReader { geo in
            // Clamp horizontal/vertical insets so the data nodes stay close to
            // the core on ultrawide windows but don't crash into the rings on
            // very narrow ones. Percentage falls within [min, max] absolute px.
            let hInset = max(24, min(geo.size.width * 0.06, 120))
            let vInsetTop = max(28, min(geo.size.height * 0.14, 140))
            let vInsetBottom = max(28, min(geo.size.height * 0.22, 160))
            let coreSize = min(geo.size.width, geo.size.height) * 0.55

            ZStack {
                // Connector lines — dashed gradient strokes from each corner
                // toward the core.
                ConnectorLines()

                // OttoCore (centerpiece).
                OttoCore(size: coreSize)

                // Floating data nodes.
                OttoDataNode(
                    label: "INBOX SCAN",
                    value: "\(unreadEmails)",
                    sub: "unread · \(priorityEmails) priority",
                    tone: unreadEmails > 50 ? .amber : .cyan
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, hInset)
                .padding(.top, vInsetTop)

                OttoDataNode(
                    label: "NEXT EVENT",
                    value: nextEventCountdown,
                    sub: nextEventTitle,
                    tone: .amber
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.trailing, hInset)
                .padding(.top, vInsetTop)

                OttoDataNode(
                    label: "TODOS · COMPLETE",
                    value: todosLabel,
                    sub: todosSub,
                    tone: .green
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.leading, hInset)
                .padding(.bottom, vInsetBottom)

                OttoDataNode(
                    label: "MEETINGS INDEXED",
                    value: "\(appState.meetings.count)",
                    sub: meetingsSub,
                    tone: .cyan
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, hInset)
                .padding(.bottom, vInsetBottom)

                // HUD header + voice freq bar.
                VStack {
                    hudHeader
                        .padding(.top, 24)
                    Spacer()
                    voiceFreqBar
                        .padding(.bottom, 24)
                        .padding(.horizontal, 24)
                }
            }
        }
    }

    // MARK: - Header

    private var hudHeader: some View {
        VStack(spacing: 4) {
            Text("⌬  COGNITIVE OPERATIONS CENTER  ⌬")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(4)
                .foregroundStyle(Theme.Colors.cyan)
                .shadow(color: Theme.Colors.cyanGlow, radius: 6)
            Text(sectorLabel)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(5)
                .foregroundStyle(Theme.Colors.textDim)
        }
    }

    private var sectorLabel: String {
        "SECTOR · \(OttoFormatters.sectorDate.string(from: .now).uppercased())"
    }

    // MARK: - Voice freq

    private var voiceFreqBar: some View {
        HStack(spacing: 12) {
            Text("VOICE FREQ")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(3)
                .foregroundStyle(Theme.Colors.textDim)
            VoiceFreqWave()
                .frame(maxWidth: .infinity)
            Text("432Hz")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(3)
                .foregroundStyle(Theme.Colors.textDim)
        }
    }

    // MARK: - Derived data

    private var unreadEmails: Int { appState.emails.filter { !$0.isRead }.count }

    private var priorityEmails: Int {
        // Heuristic: emails from the last 24h that are unread.
        appState.emails.filter {
            !$0.isRead && $0.receivedDate.timeIntervalSinceNow > -86400
        }.count
    }

    private var nextEvent: CalendarEvent? {
        appState.calendarEvents
            .filter { $0.startTime > .now }
            .sorted { $0.startTime < $1.startTime }
            .first
    }

    private var nextEventCountdown: String {
        guard let n = nextEvent else { return "—" }
        let secs = n.startTime.timeIntervalSinceNow
        let totalMin = Int(secs / 60)
        let h = totalMin / 60
        let m = totalMin % 60
        if h >= 24 {
            return "\(h)h:\(String(format: "%02d", m))m"
        }
        return String(format: "%dh:%02dm", h, m)
    }

    private var nextEventTitle: String {
        nextEvent?.title.uppercased() ?? "NO EVENTS"
    }

    private var todosLabel: String {
        let total = appState.todos.count
        let done = appState.todos.filter(\.isCompleted).count
        return String(format: "%02d/%02d", done, total)
    }

    private var todosSub: String {
        let overdue = appState.todos.filter {
            !$0.isCompleted && ($0.dueDate.map { $0 < .now } ?? false)
        }.count
        if overdue > 0 { return "\(overdue) OVERDUE" }
        return "ON TRACK TODAY"
    }

    private var meetingsSub: String {
        let recent = appState.meetings.filter {
            $0.meetingDate.timeIntervalSinceNow > -86400
        }.count
        if recent > 0 { return "+\(recent) SINCE 06:00" }
        return "ALL INDEXED"
    }
}

// MARK: - Connector lines

private struct ConnectorLines: View {
    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            // Endpoints — corners of the HUD frame, biased inward to where the
            // data nodes sit.
            let topLeft  = CGPoint(x: geo.size.width * 0.13, y: geo.size.height * 0.20)
            let topRight = CGPoint(x: geo.size.width * 0.87, y: geo.size.height * 0.20)
            let botLeft  = CGPoint(x: geo.size.width * 0.13, y: geo.size.height * 0.78)
            let botRight = CGPoint(x: geo.size.width * 0.87, y: geo.size.height * 0.78)

            Canvas { ctx, _ in
                let pts = [topLeft, topRight, botLeft, botRight]
                for p in pts {
                    var path = Path()
                    path.move(to: p)
                    path.addLine(to: center)
                    let g = Gradient(stops: [
                        .init(color: Theme.Colors.cyan.opacity(0), location: 0),
                        .init(color: Theme.Colors.cyan.opacity(0.6), location: 1),
                    ])
                    ctx.stroke(
                        path,
                        with: .linearGradient(
                            g,
                            startPoint: p,
                            endPoint: center
                        ),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 5])
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }
}
