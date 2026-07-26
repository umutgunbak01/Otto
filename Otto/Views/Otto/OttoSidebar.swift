import SwiftUI

/// Left navigation sidebar (mockup .sidebar) — Home + Map, then Library /
/// Network / X sections, with Integrations + Settings pinned at the bottom
/// alongside a small model chip.
struct OttoSidebar: View {
    @Environment(AppState.self) private var appState
    @Binding var showingHome: Bool
    @Binding var showingMap: Bool
    @Binding var showingCreative: Bool
    @Binding var showingSettings: Bool
    @Binding var showingIntegrations: Bool

    /// Bound to the AgentService model UserDefaults keys so the model chip
    /// updates the moment the user picks a new preset in Settings. We
    /// observe both keys (and the backend selector) so swapping backends
    /// re-renders the label without an app restart.
    @AppStorage(AgentService.Claude.modelIdDefaultsKey) private var storedClaudeModelId: String = AgentService.Claude.defaultModelId
    @AppStorage(AgentService.Codex.modelIdDefaultsKey) private var storedCodexModelId: String = AgentService.Codex.defaultModelId
    @AppStorage(AgentBackend.defaultsKey) private var rawBackend: String = AgentBackend.claude.rawValue

    @State private var showingNewTabEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Scrollable nav list — when the window is short, this scrolls so
            // the bottom buttons stay reachable.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    OttoNavItem(
                        systemImage: "house",
                        label: "Home",
                        count: nil,
                        isActive: showingHome && !showingMap && !showingCreative,
                        action: { showingHome = true; showingMap = false; showingCreative = false }
                    )
                    .padding(.top, 2)

                    OttoNavItem(
                        systemImage: "map",
                        label: "Map",
                        count: nil,
                        isActive: showingMap,
                        action: { showingMap = true; showingHome = false; showingCreative = false }
                    )

                    OttoNavItem(
                        systemImage: "wand.and.stars",
                        label: "Creative",
                        count: nil,
                        isActive: showingCreative,
                        action: { showingCreative = true; showingHome = false; showingMap = false }
                    )

                    sectionHeader("Library")
                    ForEach(libraryTypes, id: \.self) { type in
                        navItem(type)
                    }

                    sectionHeader("Network")
                    ForEach(networkTypes, id: \.self) { type in
                        navItem(type)
                    }

                    sectionHeader("X")
                    ForEach(xTypes, id: \.self) { type in
                        navItem(type)
                    }

                    sectionHeader("Tabs")
                    ForEach(appState.customTabs) { tab in
                        customTabItem(tab)
                    }
                    OttoNavItem(
                        systemImage: "plus",
                        label: "New tab",
                        count: nil,
                        isActive: false,
                        action: { showingNewTabEditor = true }
                    )
                }
                .padding(.bottom, 12)
            }
            .frame(maxHeight: .infinity)

            // Pinned bottom block.
            OttoDivider()
                .padding(.bottom, 8)

            OttoNavItem(
                systemImage: "link",
                label: "Integrations",
                count: nil,
                isActive: false,
                action: { showingIntegrations = true }
            )
            OttoNavItem(
                systemImage: "gearshape",
                label: "Settings",
                count: nil,
                isActive: false,
                action: { showingSettings = true }
            )

            // Model chip — quiet mono line showing the active backend/model.
            HStack(spacing: 5) {
                Circle()
                    .fill(Theme.Colors.accent)
                    .frame(width: 5, height: 5)
                Text("\(modelLabel) · \(contextLabel)")
                    .font(Theme.Typography.monoSmall)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.Colors.bg1)
        .overlay(alignment: .trailing) {
            OttoDivider()
                .frame(width: 1)
                .frame(maxHeight: .infinity)
        }
        .sheet(isPresented: $showingNewTabEditor) {
            CustomTabEditorSheet(existing: nil) { tab in
                // Jump straight into the freshly created tab.
                showingHome = false
                showingMap = false
                showingCreative = false
                appState.selectedCustomTabId = tab.id
            }
        }
    }

    // MARK: - Pieces

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(Theme.Typography.label)
            .tracking(Theme.Tracking.xwide)
            .foregroundStyle(Theme.Colors.tertiaryText)
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 6)
    }

    private func navItem(_ type: NavType) -> some View {
        OttoNavItem(
            systemImage: type.icon,
            label: type.label,
            count: type.count(appState),
            isActive: !showingHome && !showingMap && !showingCreative
                && appState.selectedCustomTabId == nil
                && appState.selectedTab == type.tab,
            action: {
                showingHome = false
                showingMap = false
                showingCreative = false
                appState.selectedTab = type.tab
            }
        )
    }

    private func customTabItem(_ tab: CustomTabDefinition) -> some View {
        OttoNavItem(
            systemImage: tab.icon,
            label: tab.name,
            count: appState.customRecords.filter { $0.tabId == tab.id }.count,
            isActive: !showingHome && !showingMap && !showingCreative
                && appState.selectedCustomTabId == tab.id,
            action: {
                showingHome = false
                showingMap = false
                showingCreative = false
                appState.selectedCustomTabId = tab.id
            }
        )
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
            // Hermes picks its model server-side; the chip shows "hermes".
            return "hermes"
        }
    }

    private var modelLabel: String {
        var id = effectiveModelRaw
        switch activeBackend {
        case .claude:
            if id.hasSuffix("[1m]") { id = String(id.dropLast(4)).trimmingCharacters(in: .whitespaces) }
            // claude-opus-4-7 → opus-4.7, claude-sonnet-4-6 → sonnet-4.6, etc.
            let stripped = id.hasPrefix("claude-") ? String(id.dropFirst("claude-".count)) : id
            let parts = stripped.split(separator: "-", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return stripped.lowercased() }
            let family = parts[0].lowercased()
            let version = parts[1].replacingOccurrences(of: "-", with: ".")
            return "\(family)-\(version)"
        case .codex:
            return id.lowercased()
        case .hermes:
            return "hermes"
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
            case .networkHub: return s.networkEntries.count
            case .company:    return s.companies.count
            case .event:      return s.events.count
            case .community:  return s.communities.count
            case .file:       return s.files.count
            case .xPost:      return s.xPosts.count
            case .xFollower:  return s.xFollowers.count
            case .xDm:        return s.xDirectMessages.count
            case .habit:      return s.habits.filter { !$0.isArchived }.count
            }
        }
    }

    private var libraryTypes: [NavType] {
        [
            NavType(tab: .todo,     label: "To-dos",    icon: "checkmark.square"),
            NavType(tab: .note,     label: "Notes",     icon: "doc.text"),
            NavType(tab: .idea,     label: "Ideas",     icon: "bolt"),
            NavType(tab: .reminder, label: "Reminders", icon: "bell"),
            NavType(tab: .bookmark, label: "Bookmarks", icon: "bookmark"),
            NavType(tab: .habit,    label: "Habits",    icon: "repeat"),
            NavType(tab: .meeting,  label: "Meetings",  icon: "video"),
            NavType(tab: .email,    label: "Emails",    icon: "envelope"),
            NavType(tab: .file,     label: "Files",     icon: "folder"),
        ]
    }

    private var networkTypes: [NavType] {
        [
            NavType(tab: .connection, label: "LinkedIn",    icon: "person.2"),
            NavType(tab: .networkHub, label: "Network hub", icon: "globe"),
            NavType(tab: .company,    label: "Companies",   icon: "briefcase"),
            NavType(tab: .event,      label: "Events",      icon: "calendar"),
            NavType(tab: .community,  label: "Communities", icon: "bubble.left.and.bubble.right"),
        ]
    }

    private var xTypes: [NavType] {
        [
            NavType(tab: .xPost,     label: "Posts",     icon: "text.bubble"),
            NavType(tab: .xFollower, label: "Followers", icon: "person.2"),
            NavType(tab: .xDm,       label: "DMs",       icon: "envelope"),
        ]
    }
}

// MARK: - Nav item

struct OttoNavItem: View {
    let systemImage: String
    let label: String
    let count: Int?
    let isActive: Bool
    let action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                    .foregroundStyle(isActive ? Theme.Colors.accentText : Theme.Colors.tertiaryText)
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(isActive ? Theme.Colors.accentText : (hover ? Theme.Colors.text : Theme.Colors.textDim))
                Spacer(minLength: 6)
                if let count = count {
                    Text(formatted(count))
                        .font(Theme.Typography.monoSmall)
                        .foregroundStyle(isActive ? Theme.Colors.accentText.opacity(0.75) : Theme.Colors.tertiaryText)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5.5)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(
                        isActive
                            ? Theme.Colors.selectTint
                            : (hover ? Theme.Colors.hoverTint : Color.clear)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    private func formatted(_ n: Int) -> String {
        OttoFormatters.decimal.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
