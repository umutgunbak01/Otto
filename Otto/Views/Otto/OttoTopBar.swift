import SwiftUI

/// Top bar of the Otto HUD — brand mark on the left, status stats on the right.
///
/// Performance: a single TimelineView at 1Hz wraps the uptime stat and feeds
/// it the current date. Everything else is static, so the bulk of the bar
/// never re-evaluates.
struct OttoTopBar: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 0) {
            // Brand
            HStack(spacing: 14) {
                BrandMark(size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("OTTO")
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .tracking(2.5)
                        .foregroundStyle(Theme.Colors.cyan)
                        .shadow(color: Theme.Colors.cyanGlow, radius: 6)
                    Text("SECOND-CORTEX v4.7")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .tracking(2.5)
                        .foregroundStyle(Theme.Colors.textDim)
                }
            }
            .layoutPriority(1)

            Spacer()

            // Status stats
            HStack(spacing: 24) {
                StatColumn(label: "USER", value: userLabel, tone: .normal)
                StatColumn(label: "SYNC", value: "LIVE", tone: .ok) {
                    PulseDot(size: 8)
                }
                UptimeStat(launchDate: appState.launchDate)
                StatColumn(label: "STATUS", value: statusLabel, tone: .ok)
                StatColumn(label: "INDEX", value: indexLabel, tone: .normal)
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 64)
        .angledPanel(.topbar(22), innerBorder: true)
    }

    // MARK: - Derived data

    private var userLabel: String {
        "USER"
    }

    private var statusLabel: String {
        if appState.errorMessage != nil { return "DEGRADED" }
        return "NOMINAL"
    }

    private var indexLabel: String {
        let total = appState.todos.count
            + appState.notes.count
            + appState.ideas.count
            + appState.reminders.count
            + appState.bookmarks.count
            + appState.meetings.count
            + appState.emails.count
            + appState.connections.count
            + appState.files.count
            + appState.xPosts.count
            + appState.xFollowers.count
            + appState.xDirectMessages.count
        return OttoFormatters.decimal.string(from: NSNumber(value: total)) ?? "\(total)"
    }
}

// MARK: - Uptime — own subview so its 1Hz tick doesn't ripple the bar

private struct UptimeStat: View {
    let launchDate: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            StatColumn(label: "UPTIME", value: format(ctx.date), tone: .normal)
        }
    }

    private func format(_ now: Date) -> String {
        let interval = now.timeIntervalSince(launchDate)
        let h = Int(interval) / 3600
        let m = (Int(interval) % 3600) / 60
        let s = Int(interval) % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}

// MARK: - Stat column

enum StatTone { case normal, ok, warn, alert }

struct StatColumn<Lead: View>: View {
    let label: String
    let value: String
    let tone: StatTone
    let leading: () -> Lead

    init(label: String, value: String, tone: StatTone, @ViewBuilder leading: @escaping () -> Lead) {
        self.label = label
        self.value = value
        self.tone = tone
        self.leading = leading
    }

    var color: Color {
        switch tone {
        case .normal: return Theme.Colors.text
        case .ok:     return Theme.Colors.green
        case .warn:   return Theme.Colors.amber
        case .alert:  return Theme.Colors.red
        }
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(2)
                .foregroundStyle(Theme.Colors.textDim)
            HStack(spacing: 6) {
                leading()
                Text(value)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(color)
            }
        }
    }
}

extension StatColumn where Lead == EmptyView {
    init(label: String, value: String, tone: StatTone) {
        self.init(label: label, value: value, tone: tone, leading: { EmptyView() })
    }
}
