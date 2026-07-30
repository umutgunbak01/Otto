import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Left navigation sidebar (mockup .sb) — brand, then Home / Map / Creative,
/// then Library / Network / X Platform sections with counts, then custom
/// tabs, with Integrations + Settings and the user card pinned at the
/// bottom. Runs full window height; the traffic lights float over its top
/// padding.
struct OttoSidebar: View {
    @Environment(AppState.self) private var appState
    @Binding var showingHome: Bool
    @Binding var showingMap: Bool
    @Binding var showingCreative: Bool
    @Binding var showingSettings: Bool
    @Binding var showingIntegrations: Bool

    /// Bound to the AgentService model UserDefaults keys so the user card
    /// updates the moment the user picks a new preset in Settings. We
    /// observe both keys (and the backend selector) so swapping backends
    /// re-renders the label without an app restart.
    @AppStorage(AgentService.Claude.modelIdDefaultsKey) private var storedClaudeModelId: String = AgentService.Claude.defaultModelId
    @AppStorage(AgentService.Codex.modelIdDefaultsKey) private var storedCodexModelId: String = AgentService.Codex.defaultModelId
    @AppStorage(AgentBackend.defaultsKey) private var rawBackend: String = AgentBackend.claude.rawValue

    @State private var showingNewTabEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Brand — sits below the window traffic lights.
            HStack(spacing: 9) {
                BrandMark(size: 22)
                Text("Otto")
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Theme.Colors.text)
            }
            .padding(.horizontal, 18)
            .padding(.top, 38)
            .padding(.bottom, 10)

            // Scrollable nav list — when the window is short, this scrolls so
            // the bottom buttons stay reachable.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 1) {
                    OttoNavItem(
                        systemImage: "house",
                        label: "Home",
                        count: nil,
                        isActive: showingHome && !showingMap && !showingCreative
                            && !showingSettings && !showingIntegrations,
                        action: { showingHome = true; showingMap = false; showingCreative = false; showingSettings = false; showingIntegrations = false }
                    )
                    .padding(.top, 2)

                    OttoNavItem(
                        systemImage: "map",
                        label: "Map",
                        count: nil,
                        isActive: showingMap && !showingSettings && !showingIntegrations,
                        action: { showingMap = true; showingHome = false; showingCreative = false; showingSettings = false; showingIntegrations = false }
                    )

                    OttoNavItem(
                        systemImage: "sparkles",
                        label: "Creative",
                        count: nil,
                        isActive: showingCreative && !showingSettings && !showingIntegrations,
                        action: { showingCreative = true; showingHome = false; showingMap = false; showingSettings = false; showingIntegrations = false }
                    )

                    sectionHeader("Library")
                    ForEach(libraryTypes, id: \.self) { type in
                        navItem(type)
                    }

                    sectionHeader("Network")
                    ForEach(networkTypes, id: \.self) { type in
                        navItem(type)
                    }

                    sectionHeader("X Platform")
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
                .padding(.horizontal, 4)
                .padding(.bottom, 8)

            OttoNavItem(
                systemImage: "link",
                label: "Integrations",
                count: nil,
                isActive: showingIntegrations,
                action: {
                    showingIntegrations = true
                    showingSettings = false
                }
            )
            OttoNavItem(
                systemImage: "gearshape",
                label: "Settings",
                count: nil,
                isActive: showingSettings,
                action: {
                    showingSettings = true
                    showingIntegrations = false
                }
            )

            // User card — avatar, name, backend status, context chip
            // (mockup .ucard).
            HStack(spacing: 9) {
                OttoUserAvatar(size: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(Self.firstName)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.Colors.text)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        PulseDot(color: Theme.Colors.green, size: 5)
                        Text("\(modelLabel) · connected")
                            .font(.system(size: 9, weight: .regular, design: .monospaced))
                            .tracking(0.4)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if contextLabel != "—" {
                    Text(contextLabel)
                        .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(Theme.Colors.accentText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Theme.Colors.tintTeal)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(Theme.Colors.cyan.opacity(0.22), lineWidth: 1)
                        )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 11)
                    .fill(Theme.Colors.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(Theme.Colors.border, lineWidth: 1)
            )
            .padding(.top, 10)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.Colors.panelWash)
        .sheet(isPresented: $showingNewTabEditor) {
            CustomTabEditorSheet(existing: nil) { tab in
                // Jump straight into the freshly created tab.
                showingHome = false
                showingMap = false
                showingCreative = false
                showingSettings = false
                showingIntegrations = false
                appState.selectedCustomTabId = tab.id
            }
        }
    }

    // MARK: - Pieces

    private static var firstName: String {
        #if os(macOS)
        let full = NSFullUserName()
        if let first = full.split(separator: " ").first, !first.isEmpty {
            return String(first)
        }
        #endif
        return "You"
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
            .tracking(Theme.Tracking.xxwide)
            .foregroundStyle(Theme.Colors.tertiaryText)
            .padding(.horizontal, 10)
            .padding(.top, 18)
            .padding(.bottom, 7)
    }

    private func navItem(_ type: NavType) -> some View {
        OttoNavItem(
            systemImage: type.icon,
            label: type.tab.pluralTitle,
            count: type.count(appState),
            isActive: !showingHome && !showingMap && !showingCreative
                && !showingSettings && !showingIntegrations
                && appState.selectedCustomTabId == nil
                && appState.selectedTab == type.tab,
            action: {
                showingHome = false
                showingMap = false
                showingCreative = false
                showingSettings = false
                showingIntegrations = false
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
                && !showingSettings && !showingIntegrations
                && appState.selectedCustomTabId == tab.id,
            action: {
                showingHome = false
                showingMap = false
                showingCreative = false
                showingSettings = false
                showingIntegrations = false
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
            case .email:
                // With triage on, the badge is the needs-reply queue — the
                // number that actually demands action — not raw unread.
                if EmailTriageSettings.isEnabled {
                    return EmailTriageService.needsReplyCount(emails: s.emails, blockedSenders: s.blockedSenders)
                }
                return s.emails.filter { !$0.isRead }.count
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
            case .automation: return s.scheduledTasks.count
            }
        }
    }

    private var libraryTypes: [NavType] {
        [
            NavType(tab: .todo,     icon: "checkmark.square"),
            NavType(tab: .note,     icon: "doc.text"),
            NavType(tab: .idea,     icon: "bolt"),
            NavType(tab: .reminder, icon: "bell"),
            NavType(tab: .bookmark, icon: "bookmark"),
            NavType(tab: .habit,    icon: "repeat"),
            NavType(tab: .meeting,  icon: "video"),
            NavType(tab: .email,    icon: "envelope"),
            NavType(tab: .file,     icon: "folder"),
            NavType(tab: .automation, icon: "cpu"),
        ]
    }

    private var networkTypes: [NavType] {
        [
            NavType(tab: .connection, icon: "person.crop.square"),
            NavType(tab: .networkHub, icon: "globe"),
            NavType(tab: .company,    icon: "building.2"),
            NavType(tab: .event,      icon: "calendar"),
            NavType(tab: .community,  icon: "bubble.left.and.bubble.right"),
        ]
    }

    private var xTypes: [NavType] {
        [
            NavType(tab: .xPost,     icon: "text.bubble"),
            NavType(tab: .xFollower, icon: "person.2"),
            NavType(tab: .xDm,       icon: "envelope"),
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
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                    .foregroundStyle(
                        isActive
                            ? Theme.Colors.accentText
                            : (hover ? Theme.Colors.textDim : Theme.Colors.tertiaryText)
                    )
                Text(label)
                    .font(.system(size: 13, weight: isActive ? .medium : .regular))
                    .foregroundStyle(isActive ? Theme.Colors.text : (hover ? Theme.Colors.text : Theme.Colors.textDim))
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let count = count {
                    Text(formatted(count))
                        .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .opacity(count == 0 ? 0.38 : 1)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 31)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .fill(
                        isActive
                            ? Theme.Colors.panel2
                            : (hover ? Theme.Colors.panel : Color.clear)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .strokeBorder(
                        isActive ? Color.white.opacity(0.05) : Color.clear,
                        lineWidth: 1
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
