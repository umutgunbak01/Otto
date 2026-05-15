import SwiftUI

/// Otto-styled sidebar — neural index header, nav items with count badges,
/// dashed dividers, social-feed sub-section, and a sys-block at the bottom
/// reporting neural load / memory / context / model.
struct OttoSidebar: View {
    @Environment(AppState.self) private var appState
    @Binding var showingHome: Bool
    @Binding var showingSettings: Bool
    @Binding var showingIntegrations: Bool

    /// Bound to the AgentService model UserDefaults keys so the sys-block model
    /// label updates the moment the user picks a new preset in Settings. We
    /// observe both keys (and the backend selector) so swapping backends
    /// re-renders the label without an app restart.
    @AppStorage(AgentService.Claude.modelIdDefaultsKey) private var storedClaudeModelId: String = AgentService.Claude.defaultModelId
    @AppStorage(AgentService.Codex.modelIdDefaultsKey) private var storedCodexModelId: String = AgentService.Codex.defaultModelId
    @AppStorage(AgentBackend.defaultsKey) private var rawBackend: String = AgentBackend.claude.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Scrollable nav list — when the window is short, this scrolls so
            // the bottom buttons stay reachable.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 4) {
                    sectionHeader("// NEURAL INDEX")
                        .padding(.bottom, 6)

                    OttoNavItem(
                        icon: AnyView(HexPip(size: 10)),
                        label: "HOME",
                        count: nil,
                        isActive: showingHome,
                        action: { showingHome = true }
                    )

                    ForEach(coreTypes, id: \.self) { type in
                        OttoNavItem(
                            icon: AnyView(navGlyph(type.icon)),
                            label: type.label,
                            count: type.count(appState),
                            isActive: !showingHome && appState.selectedTab == type.tab,
                            action: {
                                showingHome = false
                                appState.selectedTab = type.tab
                            }
                        )
                    }

                }
                .padding(.bottom, 12)
            }
            .frame(maxHeight: .infinity)

            // Pinned bottom block — sys stats + LINKS / SYS buttons.
            sysBlock

            HStack(spacing: 8) {
                Button {
                    showingIntegrations = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "link")
                            .font(.system(size: 10))
                        Text("LINKS")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .tracking(2)
                    }
                    .foregroundStyle(Theme.Colors.textDim)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .overlay(
                        Rectangle().stroke(Theme.Colors.cyan.opacity(0.18), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                Button {
                    showingSettings = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "gear")
                            .font(.system(size: 10))
                        Text("SYS")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .tracking(2)
                    }
                    .foregroundStyle(Theme.Colors.textDim)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .overlay(
                        Rectangle().stroke(Theme.Colors.cyan.opacity(0.18), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 18)
        .frame(maxHeight: .infinity, alignment: .top)
        .angledPanel(.topRight(18))
    }

    // MARK: - Pieces

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .tracking(3.2)
            .foregroundStyle(Theme.Colors.textDim)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                DashedLine()
                    .stroke(
                        Theme.Colors.cyan.opacity(0.18),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                    )
                    .frame(height: 1)
            }
    }

    private func divider() -> some View {
        LinearGradient(
            colors: [.clear, Theme.Colors.cyan.opacity(0.22), .clear],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(height: 1)
    }

    @ViewBuilder
    private func navGlyph(_ ch: String) -> some View {
        Text(ch)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .frame(width: 14, height: 14)
    }

    private var sysBlock: some View {
        VStack(spacing: 6) {
            sysRow("NEURAL LOAD", value: "73%")
            VStack(spacing: 0) { sysBar(progress: 0.73) }
                .padding(.top, 2)
            sysRow("MEMORY", value: memoryLabel)
            sysRow("CONTEXT", value: contextLabel)
            sysRow("MODEL", value: modelLabel)
        }
        .padding(12)
        .overlay(
            Rectangle().stroke(Theme.Colors.cyan.opacity(0.18), lineWidth: 1)
        )
        .background(Theme.Colors.cyan.opacity(0.03))
    }

    private func sysRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(2)
                .foregroundStyle(Theme.Colors.textDim)
            Spacer()
            Text(value)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.5)
                .foregroundStyle(Theme.Colors.cyan)
        }
    }

    private func sysBar(progress: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(Theme.Colors.cyan.opacity(0.1))
                .frame(maxWidth: .infinity)
            GeometryReader { geo in
                LinearGradient(
                    colors: [Theme.Colors.cyanDim, Theme.Colors.cyan],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: geo.size.width * progress)
            }
        }
        .frame(height: 3)
    }

    private var memoryLabel: String {
        // Total items as a stand-in for "indexed neural memory".
        let n = appState.todos.count
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
        let mb = Double(n) * 0.0017 // arbitrary scaling for show
        if mb >= 1.0 {
            return String(format: "%.1f GB", mb)
        }
        return String(format: "%.0f MB", mb * 1024)
    }

    /// Active backend, derived from the AppStorage-bound raw value so the
    /// sidebar re-renders the moment the user flips the backend in Settings.
    private var activeBackend: AgentBackend {
        AgentBackend(rawValue: rawBackend) ?? .claude
    }

    /// Effective model ID for the active backend (preserves `[1m]` suffix for
    /// Claude). Re-derived from the AppStorage values so any write triggers
    /// a recompute.
    private var effectiveModelRaw: String {
        switch activeBackend {
        case .claude:
            return storedClaudeModelId.isEmpty ? AgentService.Claude.defaultModelId : storedClaudeModelId
        case .codex:
            return storedCodexModelId.isEmpty ? AgentService.Codex.defaultModelId : storedCodexModelId
        case .hermes:
            // Hermes picks its model server-side; the label below shows
            // "HERMES" instead of a concrete model id, so this string is
            // never user-visible.
            return "hermes"
        }
    }

    private var modelLabel: String {
        var id = effectiveModelRaw
        switch activeBackend {
        case .claude:
            if id.hasSuffix("[1m]") { id = String(id.dropLast(4)).trimmingCharacters(in: .whitespaces) }
            // claude-opus-4-7 → OPUS-4.7, claude-sonnet-4-6 → SONNET-4.6, etc.
            let stripped = id.hasPrefix("claude-") ? String(id.dropFirst("claude-".count)) : id
            let parts = stripped.split(separator: "-", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return stripped.uppercased() }
            let family = parts[0].uppercased()
            let version = parts[1].replacingOccurrences(of: "-", with: ".")
            return "\(family)-\(version)"
        case .codex:
            // gpt-5.5 → GPT-5.5, gpt-5-codex → GPT-5-CODEX, o3 → O3
            return id.uppercased()
        case .hermes:
            // Hermes config (model + provider) lives in ~/.hermes/config.yaml;
            // we don't surface a model id here.
            return "HERMES"
        }
    }

    private var contextLabel: String {
        switch activeBackend {
        case .claude: return effectiveModelRaw.hasSuffix("[1m]") ? "1M" : "200K"
        case .codex:  return "200K"
        case .hermes: return "—"
        }
    }

    // MARK: - Type maps

    private struct NavType: Hashable {
        let tab: ContentType
        let label: String
        let icon: String
        let counter: String
        // Compare by tab for Hashable
        func hash(into hasher: inout Hasher) { hasher.combine(tab) }
        static func == (l: Self, r: Self) -> Bool { l.tab == r.tab }

        func count(_ s: AppState) -> Int? {
            switch tab {
            case .todo:       return s.todos.filter { !$0.isCompleted }.count
            case .note:       return s.notes.count
            case .idea:       return s.ideas.count
            case .reminder:   return s.reminders.filter { !$0.isCompleted }.count
            case .bookmark:   return s.bookmarks.filter { !$0.isRead }.count
            case .meeting:    return s.meetings.count
            case .email:      return s.emails.filter { !$0.isRead }.count
            case .connection: return s.connections.count
            case .file:       return s.files.count
            case .xPost:      return s.xPosts.count
            case .xFollower:  return s.xFollowers.count
            case .xDm:        return s.xDirectMessages.count
            case .habit:      return s.habits.filter { !$0.isArchived }.count
            }
        }
    }

    private var coreTypes: [NavType] {
        [
            NavType(tab: .todo,       label: "TO-DO",       icon: "▣", counter: "12"),
            NavType(tab: .note,       label: "NOTE",        icon: "≡", counter: "270"),
            NavType(tab: .idea,       label: "IDEA",        icon: "◇", counter: "1"),
            NavType(tab: .reminder,   label: "REMINDER",    icon: "◉", counter: "4"),
            NavType(tab: .bookmark,   label: "BOOKMARK",    icon: "▭", counter: "103"),
            NavType(tab: .habit,      label: "HABITS",      icon: "♨", counter: "—"),
            NavType(tab: .meeting,    label: "MEETING",     icon: "▶", counter: "870"),
            NavType(tab: .email,      label: "EMAIL",       icon: "✉", counter: "8.351"),
            NavType(tab: .connection, label: "CONNECTIONS", icon: "⌬", counter: "4.128"),
            NavType(tab: .file,       label: "FILES",       icon: "◰", counter: "1"),
            NavType(tab: .xPost,      label: "X-POSTS",     icon: "✕", counter: "—"),
            NavType(tab: .xFollower,  label: "X-FOLLOWERS", icon: "⊙", counter: "—"),
            NavType(tab: .xDm,        label: "X-DMS",       icon: "⌖", counter: "—"),
        ]
    }
}

// MARK: - Nav item

struct OttoNavItem: View {
    let icon: AnyView
    let label: String
    let count: Int?
    let isActive: Bool
    let action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon
                    .foregroundStyle(isActive ? Theme.Colors.cyan : (hover ? Theme.Colors.text : Theme.Colors.textDim))
                Text(label)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(isActive ? Theme.Colors.cyan : (hover ? Theme.Colors.text : Theme.Colors.textDim))
                Spacer(minLength: 6)
                countChip
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                isActive
                    ? AnyShapeStyle(LinearGradient(
                        colors: [Theme.Colors.cyan.opacity(0.18), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    : (hover
                        ? AnyShapeStyle(Theme.Colors.cyan.opacity(0.04))
                        : AnyShapeStyle(Color.clear))
            )
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(isActive
                          ? Theme.Colors.cyan
                          : (hover ? Theme.Colors.cyan.opacity(0.4) : .clear))
                    .frame(width: 2)
            }
            .shadow(color: isActive ? Theme.Colors.cyanGlow.opacity(0.4) : .clear, radius: 6)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    @ViewBuilder
    private var countChip: some View {
        if let count = count {
            Text(formatted(count))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(0.5)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .foregroundStyle(isActive ? Theme.Colors.cyan : Theme.Colors.textDim)
                .overlay(
                    Rectangle()
                        .stroke(
                            isActive ? Theme.Colors.cyanDim : Theme.Colors.cyan.opacity(0.14),
                            lineWidth: 1
                        )
                )
                .background(
                    Theme.Colors.cyan.opacity(isActive ? 0.15 : 0.07)
                )
        }
    }

    private func formatted(_ n: Int) -> String {
        if n >= 1000 {
            // European-style separator to match the mockup ("8.351").
            let nf = NumberFormatter()
            nf.groupingSeparator = "."
            nf.numberStyle = .decimal
            return nf.string(from: NSNumber(value: n)) ?? "\(n)"
        }
        return "\(n)"
    }
}

// MARK: - Dashed line shape

struct DashedLine: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}
