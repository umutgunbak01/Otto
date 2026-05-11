import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct IntegrationsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var expandedIntegration: IntegrationType?

    enum IntegrationType: String, CaseIterable {
        case fireflies = "Fireflies"
        case gmail = "Gmail"
        case googleCalendar = "Google Calendar"
        case todoist = "Todoist"
        case notion = "Notion"
        case linkedin = "LinkedIn"
        case twitter = "X (Twitter)"
        case supabase = "Custom Database"
        case genmedia = "GenMedia (fal.ai)"

        var icon: String {
            switch self {
            case .fireflies: return "waveform"
            case .gmail: return "envelope"
            case .googleCalendar: return "calendar"
            case .todoist: return "checkmark.circle"
            case .notion: return "doc.text"
            case .linkedin: return "person.2"
            case .twitter: return "text.bubble"
            case .supabase: return "externaldrive.connected.to.line.below"
            case .genmedia: return "wand.and.stars"
            }
        }

        var description: String {
            switch self {
            case .fireflies: return "Import meeting transcripts and action items"
            case .gmail: return "Sync emails and create tasks from messages"
            case .googleCalendar: return "Import calendar events and meetings"
            case .todoist: return "Sync tasks from your Todoist projects"
            case .notion: return "Sync pages as notes from your Notion workspace"
            case .linkedin: return "Import connections from LinkedIn CSV export"
            case .twitter: return "Import tweets, DMs, followers, and bookmarks"
            case .supabase: return "Read/write your own Supabase projects via the official MCP server"
            case .genmedia: return "Generate images, video, audio, and music with fal.ai models"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            Divider()

            // Integration List
            ScrollView {
                VStack(spacing: Theme.Spacing.md) {
                    ForEach(IntegrationType.allCases, id: \.self) { integration in
                        integrationRow(integration)
                    }
                }
                .padding(Theme.Spacing.xl)
            }
        }
        .frame(width: 600, height: 500)
        .background(Theme.Colors.background)
        .sheet(isPresented: $showingTodoistTokenInput) {
            todoistTokenInputSheet
        }
        .sheet(isPresented: $showingNotionTokenInput) {
            notionTokenInputSheet
        }
        .sheet(isPresented: $showingXClientIdInput) {
            xClientIdInputSheet
        }
        .sheet(isPresented: $showingFirefliesCredentialsInput) {
            firefliesCredentialsInputSheet
        }
        .sheet(isPresented: $showingGoogleClientIdInput) {
            googleClientIdInputSheet
        }
        .sheet(isPresented: $showingSupabaseInput) {
            supabaseProjectInputSheet
        }
        .sheet(isPresented: $showingGenmediaSetup) {
            genmediaSetupSheet
        }
    }

    // MARK: - Todoist Token Input Sheet

    private var todoistTokenInputSheet: some View {
        VStack(spacing: Theme.Spacing.xl) {
            // Header
            HStack {
                Text("Connect Todoist")
                    .font(Theme.Typography.title)

                Spacer()

                Button {
                    showingTodoistTokenInput = false
                    todoistTokenInput = ""
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .frame(width: 24, height: 24)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            // Instructions
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Enter your Todoist API token:")
                    .font(Theme.Typography.body)

                VStack(alignment: .leading, spacing: 2) {
                    Text("1. Open Todoist → Settings → Integrations")
                    Text("2. Scroll down to the Developer section")
                    Text("3. Copy your API token")
                }
                .font(Theme.Typography.small)
                .foregroundStyle(Theme.Colors.tertiaryText)
            }

            // Token Input
            SecureField("Paste your API token here", text: $todoistTokenInput)
                .textFieldStyle(.plain)
                .font(Theme.Typography.body)
                .padding(Theme.Spacing.md)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )

            // Error
            if let error = appState.todoistSyncError {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)

                    Text(error)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.orange)
                }
            }

            // Connect Button
            Button {
                let token = todoistTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !token.isEmpty else { return }
                Task {
                    await appState.connectTodoist(apiToken: token)
                    if appState.isTodoistConnected {
                        showingTodoistTokenInput = false
                        todoistTokenInput = ""
                    }
                }
            } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    if appState.isLoadingTodoist {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 14))
                    }
                    Text("Connect")
                }
                .font(Theme.Typography.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Spacing.md)
                .background(todoistTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.gray.opacity(0.3) : Theme.Colors.accent)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            }
            .buttonStyle(.plain)
            .disabled(todoistTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appState.isLoadingTodoist)

            Spacer()
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 420, height: 380)
        .background(Theme.Colors.background)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Integrations")
                .font(Theme.Typography.title)

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .frame(width: 24, height: 24)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(Theme.Spacing.xl)
    }

    // MARK: - Integration Row

    private func integrationRow(_ integration: IntegrationType) -> some View {
        VStack(spacing: 0) {
            // Main Row
            HStack(spacing: Theme.Spacing.lg) {
                // Icon
                Image(systemName: integration.icon)
                    .font(.system(size: 24))
                    .foregroundStyle(integrationColor(integration))
                    .frame(width: 44, height: 44)
                    .background(integrationColor(integration).opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))

                // Info
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Theme.Spacing.sm) {
                        Text(integration.rawValue)
                            .font(Theme.Typography.headline)

                        if isConnected(integration) {
                            if appState.needsGoogleReauth && (integration == .gmail || integration == .googleCalendar) {
                                Text("Session Expired")
                                    .font(Theme.Typography.small)
                                    .foregroundStyle(.orange)
                                    .padding(.horizontal, Theme.Spacing.sm)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.1))
                                    .clipShape(Capsule())
                            } else {
                                Text("Connected")
                                    .font(Theme.Typography.small)
                                    .foregroundStyle(.green)
                                    .padding(.horizontal, Theme.Spacing.sm)
                                    .padding(.vertical, 2)
                                    .background(Color.green.opacity(0.1))
                                    .clipShape(Capsule())
                            }
                        }
                    }

                    Text(integration.description)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }

                Spacer()

                // Status / Actions
                if isConnected(integration) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if expandedIntegration == integration {
                                expandedIntegration = nil
                            } else {
                                expandedIntegration = integration
                            }
                        }
                    } label: {
                        Image(systemName: expandedIntegration == integration ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.Colors.secondaryText)
                    }
                    .buttonStyle(.plain)
                } else if canConnect(integration) {
                    Button {
                        connectIntegration(integration)
                    } label: {
                        Text("Connect")
                            .font(Theme.Typography.caption)
                            .padding(.horizontal, Theme.Spacing.md)
                            .padding(.vertical, Theme.Spacing.xs)
                            .background(Theme.Colors.accent)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("Coming Soon")
                        .font(Theme.Typography.small)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
            }
            .padding(Theme.Spacing.lg)

            // Expanded Content
            if expandedIntegration == integration && isConnected(integration) {
                Divider()
                    .padding(.horizontal, Theme.Spacing.lg)

                expandedContent(for: integration)
                    .padding(Theme.Spacing.lg)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Theme.Colors.background)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func integrationColor(_ integration: IntegrationType) -> Color {
        switch integration {
        case .fireflies: return .purple
        case .gmail: return .red
        case .googleCalendar: return .blue
        case .todoist: return .red
        case .notion: return .gray
        case .linkedin: return .indigo
        case .twitter: return .primary
        case .supabase: return .green
        case .genmedia: return .pink
        }
    }

    private func isConnected(_ integration: IntegrationType) -> Bool {
        switch integration {
        case .fireflies:
            return FirefliesService.shared.hasAPIKey() && !appState.firefliesSyncSettings.userEmail.isEmpty
        case .gmail:
            return appState.isGmailConnected || appState.needsGoogleReauth
        case .googleCalendar:
            return appState.isCalendarConnected || appState.needsGoogleReauth
        case .todoist:
            return appState.isTodoistConnected
        case .notion:
            return appState.isNotionConnected
        case .linkedin:
            return !appState.connections.isEmpty
        case .twitter:
            return appState.isXConnected
        case .supabase:
            return !SupabaseProjectsService.shared.allProjects().isEmpty
        case .genmedia:
            return FalAIService.shared.hasAPIKey() && GenMediaService.shared.isInstalled()
        }
    }

    private func canConnect(_ integration: IntegrationType) -> Bool {
        switch integration {
        case .fireflies:
            return true // Always can attempt to connect (via Settings)
        case .gmail:
            return true // Can connect via OAuth
        case .googleCalendar:
            return true // Uses same OAuth as Gmail
        case .todoist:
            return true // API token based
        case .notion:
            return true // Integration token based
        case .linkedin:
            return true // CSV import available
        case .twitter:
            return true // OAuth + Client ID
        case .supabase:
            return true // PAT-based, one or more projects
        case .genmedia:
            return true // Existing fal key + CLI install detection
        }
    }

    private func connectIntegration(_ integration: IntegrationType) {
        switch integration {
        case .fireflies:
            // Pre-load existing values so users can edit, not overwrite blindly.
            firefliesApiKeyInput = UserDefaults.standard.string(forKey: "fireflies_api_key") ?? ""
            firefliesUserEmailInput = appState.firefliesSyncSettings.userEmail
            firefliesAutoSyncInput = appState.firefliesSyncSettings.autoSyncEnabled
            showingFirefliesCredentialsInput = true
        case .gmail:
            if GoogleAuthService.shared.hasClientId {
                Task { await appState.connectGmail() }
            } else {
                googleClientIdInput = ""
                googleClientIdNextAction = .gmail
                showingGoogleClientIdInput = true
            }
        case .googleCalendar:
            if GoogleAuthService.shared.hasClientId {
                Task { await appState.connectCalendar() }
            } else {
                googleClientIdInput = ""
                googleClientIdNextAction = .calendar
                showingGoogleClientIdInput = true
            }
        case .todoist:
            showingTodoistTokenInput = true
        case .notion:
            showingNotionTokenInput = true
        case .linkedin:
            // LinkedIn import opens an NSOpenPanel directly instead of
            // SwiftUI's .fileImporter. Reason: this view lives inside a
            // .sheet (MainView), and macOS SwiftUI has a long-standing
            // bug where .fileImporter bindings attached to a sheet's
            // content silently never present. NSOpenPanel sidesteps the
            // sheet-presentation context entirely.
            presentLinkedInImportPanel()
        case .twitter:
            if XAuthService.shared.hasClientId {
                Task { await appState.connectX() }
            } else {
                showingXClientIdInput = true
            }
        case .supabase:
            // Open the add-project sheet with a fresh form. Existing projects
            // are managed inline via the expanded content (`supabaseExpandedContent`).
            resetSupabaseInputs()
            showingSupabaseInput = true
        case .genmedia:
            // The "Connect" button is just a status nudge — the card is fully
            // controlled by external state (fal key + binary presence). Show
            // the install instructions sheet so the user knows what to do.
            showingGenmediaSetup = true
        }
    }

    // MARK: - Expanded Content

    @ViewBuilder
    private func expandedContent(for integration: IntegrationType) -> some View {
        switch integration {
        case .fireflies:
            firefliesExpandedContent
        case .gmail:
            gmailExpandedContent
        case .googleCalendar:
            calendarExpandedContent
        case .todoist:
            todoistExpandedContent
        case .notion:
            notionExpandedContent
        case .linkedin:
            linkedInExpandedContent
        case .twitter:
            twitterExpandedContent
        case .supabase:
            supabaseExpandedContent
        case .genmedia:
            genmediaExpandedContent
        }
    }

    private var firefliesExpandedContent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            // Sync Status
            if let lastResult = appState.lastAutoSyncResult {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)

                    Text(lastResult)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
            }

            // Error State
            if let error = appState.firefliesSyncError {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)

                    Text(error)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
            }

            // Sync Buttons
            HStack(spacing: Theme.Spacing.md) {
                Button {
                    Task { await appState.syncFirefliesNow() }
                } label: {
                    HStack(spacing: Theme.Spacing.xs) {
                        if appState.isLoadingFireflies {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 12))
                        }
                        Text("Sync Recent")
                    }
                    .font(Theme.Typography.caption)
                }
                .buttonStyle(GhostButtonStyle())
                .disabled(appState.isLoadingFireflies)

                Button {
                    Task { await appState.syncAllFirefliesMeetings() }
                } label: {
                    HStack(spacing: Theme.Spacing.xs) {
                        if appState.isLoadingFireflies {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 12))
                        }
                        Text("Sync All Meetings")
                    }
                    .font(Theme.Typography.caption)
                }
                .buttonStyle(GhostButtonStyle())
                .disabled(appState.isLoadingFireflies)

                Spacer()

                // Stats
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(appState.meetings.count) meetings imported")
                        .font(Theme.Typography.small)
                        .foregroundStyle(Theme.Colors.tertiaryText)

                    if let lastSync = appState.firefliesSyncSettings.lastSyncDate {
                        Text("Last sync: \(lastSync.formatted(.relative(presentation: .named)))")
                            .font(Theme.Typography.small)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }
                }
            }
        }
    }

    // MARK: - X (Twitter) State

    @State private var showingXClientIdInput = false
    @State private var xClientIdInput = ""

    // MARK: - Todoist State

    @State private var showingTodoistTokenInput = false
    @State private var todoistTokenInput = ""

    // MARK: - Notion State

    @State private var showingNotionTokenInput = false
    @State private var notionTokenInput = ""

    // MARK: - Fireflies State

    @State private var showingFirefliesCredentialsInput = false
    @State private var firefliesApiKeyInput = ""
    @State private var firefliesUserEmailInput = ""
    @State private var firefliesAutoSyncInput = false

    // MARK: - Google OAuth Client ID State

    @State private var showingGoogleClientIdInput = false
    @State private var googleClientIdInput = ""
    @State private var googleClientIdNextAction: GoogleConnectTarget = .gmail

    enum GoogleConnectTarget { case gmail, calendar }

    // MARK: - Supabase Custom Project State

    @State private var showingSupabaseInput = false
    @State private var supabaseNameInput = ""
    @State private var supabaseRefInput = ""
    @State private var supabasePatInput = ""
    @State private var supabaseNotesInput = ""
    @State private var supabaseError: String?
    /// Re-render trigger after add/remove. SupabaseProjectsService stores in
    /// UserDefaults + Keychain (no @Published source of truth), so we bump
    /// this to invalidate the view tree after a mutation.
    @State private var supabaseProjectsRevision = 0

    // MARK: - GenMedia state

    @State private var showingGenmediaSetup = false
    /// Bumped after the user hits "Verify" in the install sheet so the
    /// `isInstalled()` probe re-runs and the card flips to "connected"
    /// without an app relaunch.
    @State private var genmediaInstallRevision = 0
    /// Surfaces the result of the "Test generation" probe in the expanded
    /// card. nil = haven't tried; non-empty = last test message.
    @State private var genmediaTestMessage: String? = nil
    @State private var genmediaTestIsError = false
    @State private var isRunningGenmediaTest = false

    private func resetSupabaseInputs() {
        supabaseNameInput = ""
        supabaseRefInput = ""
        supabasePatInput = ""
        supabaseNotesInput = ""
        supabaseError = nil
    }

    // MARK: - Todoist Expanded Content

    private var todoistExpandedContent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            // Error State
            if let error = appState.todoistSyncError {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)

                    Text(error)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
            }

            // Sync Button and Stats
            HStack(spacing: Theme.Spacing.md) {
                Button {
                    Task { await appState.syncTodoistTasks() }
                } label: {
                    HStack(spacing: Theme.Spacing.xs) {
                        if appState.isLoadingTodoist {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 12))
                        }
                        Text("Sync Tasks")
                    }
                    .font(Theme.Typography.caption)
                }
                .buttonStyle(GhostButtonStyle())
                .disabled(appState.isLoadingTodoist)

                Spacer()

                // Stats
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(appState.todoistTaskCount) tasks synced")
                        .font(Theme.Typography.small)
                        .foregroundStyle(Theme.Colors.tertiaryText)

                    if let lastSync = appState.lastTodoistSync {
                        Text("Last sync: \(lastSync.formatted(.relative(presentation: .named)))")
                            .font(Theme.Typography.small)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }
                }
            }

            // Info
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Colors.tertiaryText)

                Text("Todoist tasks appear in your To-Do list. Completing them here syncs back to Todoist.")
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }

            // Disconnect option
            HStack {
                Spacer()

                Button {
                    Task { await appState.disconnectTodoist() }
                } label: {
                    Text("Disconnect Todoist")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.priorityUrgent)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Notion Token Input Sheet

    private var notionTokenInputSheet: some View {
        VStack(spacing: Theme.Spacing.xl) {
            // Header
            HStack {
                Text("Connect Notion")
                    .font(Theme.Typography.title)

                Spacer()

                Button {
                    showingNotionTokenInput = false
                    notionTokenInput = ""
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .frame(width: 24, height: 24)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            // Instructions
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Enter your Notion integration token:")
                    .font(Theme.Typography.body)

                VStack(alignment: .leading, spacing: 2) {
                    Text("1. Go to notion.so/my-integrations")
                    Text("2. Create a new internal integration")
                    Text("3. Copy the Internal Integration Secret")
                    Text("4. Share your Notion pages with the integration")
                }
                .font(Theme.Typography.small)
                .foregroundStyle(Theme.Colors.tertiaryText)
            }

            // Token Input
            SecureField("Paste your integration token here", text: $notionTokenInput)
                .textFieldStyle(.plain)
                .font(Theme.Typography.body)
                .padding(Theme.Spacing.md)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )

            // Error
            if let error = appState.notionSyncError {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)

                    Text(error)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.orange)
                }
            }

            // Connect Button
            Button {
                let token = notionTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !token.isEmpty else { return }
                Task {
                    await appState.connectNotion(token: token)
                    if appState.isNotionConnected {
                        showingNotionTokenInput = false
                        notionTokenInput = ""
                    }
                }
            } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    if appState.isLoadingNotion {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 14))
                    }
                    Text("Connect")
                }
                .font(Theme.Typography.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Spacing.md)
                .background(notionTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.gray.opacity(0.3) : Theme.Colors.accent)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            }
            .buttonStyle(.plain)
            .disabled(notionTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appState.isLoadingNotion)

            Spacer()
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 420, height: 400)
        .background(Theme.Colors.background)
    }

    // MARK: - Notion Expanded Content

    private var notionExpandedContent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            // Error State
            if let error = appState.notionSyncError {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)

                    Text(error)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
            }

            // Sync Button and Stats
            HStack(spacing: Theme.Spacing.md) {
                Button {
                    Task { await appState.syncNotionPages() }
                } label: {
                    HStack(spacing: Theme.Spacing.xs) {
                        if appState.isLoadingNotion {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 12))
                        }
                        Text("Sync Pages")
                    }
                    .font(Theme.Typography.caption)
                }
                .buttonStyle(GhostButtonStyle())
                .disabled(appState.isLoadingNotion)

                Spacer()

                // Stats
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(appState.notionNoteCount) pages synced")
                        .font(Theme.Typography.small)
                        .foregroundStyle(Theme.Colors.tertiaryText)

                    if let lastSync = appState.lastNotionSync {
                        Text("Last sync: \(lastSync.formatted(.relative(presentation: .named)))")
                            .font(Theme.Typography.small)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }
                }
            }

            // Info
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Colors.tertiaryText)

                Text("Notion pages appear as Notes. Only pages shared with your integration are synced.")
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }

            // Disconnect option
            HStack {
                Spacer()

                Button {
                    Task { await appState.disconnectNotion() }
                } label: {
                    Text("Disconnect Notion")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.priorityUrgent)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Gmail Expanded Content

    @State private var showingGmailSettings = false

    private var gmailExpandedContent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            // Auth error — needs re-authentication
            if appState.needsGoogleReauth {
                VStack(spacing: Theme.Spacing.sm) {
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.orange)

                        Text("Your Google session has expired. Please sign in again to continue syncing.")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.secondaryText)
                    }

                    Button {
                        Task { await appState.reauthenticateGoogle() }
                    } label: {
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 12))
                            Text("Sign In Again")
                        }
                        .font(Theme.Typography.caption)
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.xs)
                        .background(Theme.Colors.accent)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    }
                    .buttonStyle(.plain)
                }
                .padding(Theme.Spacing.sm)
                .background(Color.orange.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
            }

            // Sync Status (only show if not a re-auth issue)
            if let error = appState.gmailSyncError, !appState.needsGoogleReauth {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)

                    Text(error)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
            }

            // Sync Buttons and Actions
            HStack(spacing: Theme.Spacing.md) {
                Button {
                    Task { await appState.syncGmailEmails() }
                } label: {
                    HStack(spacing: Theme.Spacing.xs) {
                        if appState.isLoadingGmail {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 12))
                        }
                        Text("Sync Recent")
                    }
                    .font(Theme.Typography.caption)
                }
                .buttonStyle(GhostButtonStyle())
                .disabled(appState.isLoadingGmail || appState.needsGoogleReauth)

                Button {
                    Task { await appState.syncAllGmailEmails() }
                } label: {
                    HStack(spacing: Theme.Spacing.xs) {
                        if appState.isLoadingGmail {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 12))
                        }
                        Text("Sync All")
                    }
                    .font(Theme.Typography.caption)
                }
                .buttonStyle(GhostButtonStyle())
                .disabled(appState.isLoadingGmail || appState.needsGoogleReauth)

                Button {
                    showingGmailSettings = true
                } label: {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: "gear")
                            .font(.system(size: 12))
                        Text("Settings")
                    }
                    .font(Theme.Typography.caption)
                }
                .buttonStyle(GhostButtonStyle())

                Spacer()

                // Stats
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(appState.emails.count) emails imported")
                        .font(Theme.Typography.small)
                        .foregroundStyle(Theme.Colors.tertiaryText)

                    if !appState.blockedSenders.isEmpty {
                        Text("\(appState.blockedSenders.count) blocked sender(s)")
                            .font(Theme.Typography.small)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }

                    if let lastSync = appState.lastGmailSync {
                        Text("Last sync: \(lastSync.formatted(.relative(presentation: .named)))")
                            .font(Theme.Typography.small)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }
                }
            }

            // Disconnect option
            HStack {
                Spacer()

                Button {
                    Task { await appState.disconnectGmail() }
                } label: {
                    Text("Disconnect Gmail")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.priorityUrgent)
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $showingGmailSettings) {
            GmailSettingsView()
                .environment(appState)
        }
    }

    // MARK: - Calendar Expanded Content

    private var calendarExpandedContent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            // Auth error — needs re-authentication
            if appState.needsGoogleReauth {
                VStack(spacing: Theme.Spacing.sm) {
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.orange)

                        Text("Your Google session has expired. Please sign in again to continue syncing.")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.secondaryText)
                    }

                    Button {
                        Task { await appState.reauthenticateGoogle() }
                    } label: {
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 12))
                            Text("Sign In Again")
                        }
                        .font(Theme.Typography.caption)
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.xs)
                        .background(Theme.Colors.accent)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    }
                    .buttonStyle(.plain)
                }
                .padding(Theme.Spacing.sm)
                .background(Color.orange.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
            }

            // Sync Status (only show if not a re-auth issue)
            if let error = appState.calendarSyncError, !appState.needsGoogleReauth {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)

                    Text(error)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
            }

            // Sync Button and Stats
            HStack(spacing: Theme.Spacing.md) {
                Button {
                    Task { await appState.syncCalendarEvents() }
                } label: {
                    HStack(spacing: Theme.Spacing.xs) {
                        if appState.isLoadingCalendar {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 12))
                        }
                        Text("Sync Calendar")
                    }
                    .font(Theme.Typography.caption)
                }
                .buttonStyle(GhostButtonStyle())
                .disabled(appState.isLoadingCalendar || appState.needsGoogleReauth)

                Spacer()

                // Stats
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(appState.calendarEvents.count) events synced")
                        .font(Theme.Typography.small)
                        .foregroundStyle(Theme.Colors.tertiaryText)

                    if let lastSync = appState.lastCalendarSync {
                        Text("Last sync: \(lastSync.formatted(.relative(presentation: .named)))")
                            .font(Theme.Typography.small)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }
                }
            }

            // Info about calendar scope
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Colors.tertiaryText)

                Text("Calendar events appear in your To-Do view, organized by day")
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }

            // Disconnect option
            HStack {
                Spacer()

                Button {
                    Task { await appState.disconnectCalendar() }
                } label: {
                    Text("Disconnect Calendar")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.priorityUrgent)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - LinkedIn Expanded Content

    private var linkedInExpandedContent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            // Error State
            if let error = appState.connectionImportError {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)

                    Text(error)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
            }

            // Import Button and Stats
            HStack(spacing: Theme.Spacing.md) {
                Button {
                    presentLinkedInImportPanel()
                } label: {
                    HStack(spacing: Theme.Spacing.xs) {
                        if appState.isLoadingConnections {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 12))
                        }
                        Text("Import CSV")
                    }
                    .font(Theme.Typography.caption)
                }
                .buttonStyle(GhostButtonStyle())
                .disabled(appState.isLoadingConnections)

                Spacer()

                // Stats
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(appState.connections.count) connections imported")
                        .font(Theme.Typography.small)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
            }

            // Instructions
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("How to export from LinkedIn:")
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.secondaryText)

                VStack(alignment: .leading, spacing: 2) {
                    Text("1. Go to LinkedIn > Settings")
                    Text("2. Data Privacy > Get a copy of your data")
                    Text("3. Select \"Connections\" and request archive")
                    Text("4. Download and import the Connections.csv file")
                }
                .font(Theme.Typography.small)
                .foregroundStyle(Theme.Colors.tertiaryText)
            }
            .padding(Theme.Spacing.sm)
            .background(Color.primary.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
        }
    }

    // MARK: - X (Twitter) Client ID Input Sheet

    private var xClientIdInputSheet: some View {
        VStack(spacing: Theme.Spacing.xl) {
            // Header
            HStack {
                Text("Connect X (Twitter)")
                    .font(Theme.Typography.title)

                Spacer()

                Button {
                    showingXClientIdInput = false
                    xClientIdInput = ""
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .frame(width: 24, height: 24)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            // Instructions
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Enter your X Developer Client ID:")
                    .font(Theme.Typography.body)

                VStack(alignment: .leading, spacing: 2) {
                    Text("1. Go to console.x.com and create an app")
                    Text("2. Enable OAuth 2.0 with \"Native App\" type")
                    Text("3. Add redirect URI: otto://x-callback")
                    Text("4. Copy the Client ID from your app settings")
                }
                .font(Theme.Typography.small)
                .foregroundStyle(Theme.Colors.tertiaryText)
            }

            // Client ID Input
            TextField("Paste your Client ID here", text: $xClientIdInput)
                .textFieldStyle(.plain)
                .font(Theme.Typography.body)
                .padding(Theme.Spacing.md)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )

            // Error
            if let error = appState.xSyncError {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)

                    Text(error)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.orange)
                }
            }

            // Connect Button
            Button {
                let clientId = xClientIdInput.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clientId.isEmpty else { return }
                XAuthService.shared.clientId = clientId
                Task {
                    await appState.connectX()
                    if appState.isXConnected {
                        showingXClientIdInput = false
                        xClientIdInput = ""
                    }
                }
            } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    if appState.isLoadingX {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 14))
                    }
                    Text("Connect")
                }
                .font(Theme.Typography.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Spacing.md)
                .background(xClientIdInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.gray.opacity(0.3) : Theme.Colors.accent)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            }
            .buttonStyle(.plain)
            .disabled(xClientIdInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appState.isLoadingX)

            Spacer()
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 420, height: 420)
        .background(Theme.Colors.background)
    }

    // MARK: - Fireflies Credentials Sheet

    private var firefliesCredentialsInputSheet: some View {
        VStack(spacing: Theme.Spacing.xl) {
            HStack {
                Text("Connect Fireflies.ai")
                    .font(Theme.Typography.title)
                Spacer()
                Button {
                    showingFirefliesCredentialsInput = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .frame(width: 24, height: 24)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Enter your Fireflies.ai credentials:")
                    .font(Theme.Typography.body)
                VStack(alignment: .leading, spacing: 2) {
                    Text("1. Get your API key from fireflies.ai/api")
                    Text("2. Your email lets Otto filter to meetings you attended")
                    Text("3. Auto-sync pulls new meetings every 24 hours")
                }
                .font(Theme.Typography.small)
                .foregroundStyle(Theme.Colors.tertiaryText)
            }

            SecureField("Fireflies API key", text: $firefliesApiKeyInput)
                .textFieldStyle(.plain)
                .font(Theme.Typography.body)
                .padding(Theme.Spacing.md)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )

            TextField("Your email (e.g. you@company.com)", text: $firefliesUserEmailInput)
                .textFieldStyle(.plain)
                .font(Theme.Typography.body)
                .padding(Theme.Spacing.md)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )

            Toggle(isOn: $firefliesAutoSyncInput) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Daily auto-sync")
                        .font(Theme.Typography.body)
                    Text("Pull new meetings every 24 hours")
                        .font(Theme.Typography.small)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
            }
            .toggleStyle(.switch)
            .tint(Theme.Colors.hobby)

            Button {
                let key = firefliesApiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                let email = firefliesUserEmailInput.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { return }
                FirefliesService.shared.setAPIKey(key)
                var settings = appState.firefliesSyncSettings
                settings.userEmail = email
                settings.autoSyncEnabled = firefliesAutoSyncInput
                appState.updateSyncSettings(settings)
                showingFirefliesCredentialsInput = false
            } label: {
                Text("Save")
                    .font(Theme.Typography.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Spacing.md)
                    .background(firefliesApiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.gray.opacity(0.3) : Theme.Colors.accent)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            }
            .buttonStyle(.plain)
            .disabled(firefliesApiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Spacer()
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 420, height: 460)
        .background(Theme.Colors.background)
    }

    // MARK: - Google OAuth Client ID Sheet

    private var googleClientIdInputSheet: some View {
        VStack(spacing: Theme.Spacing.xl) {
            HStack {
                Text(googleClientIdNextAction == .gmail ? "Connect Gmail" : "Connect Google Calendar")
                    .font(Theme.Typography.title)
                Spacer()
                Button {
                    showingGoogleClientIdInput = false
                    googleClientIdInput = ""
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .frame(width: 24, height: 24)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Enter your Google OAuth Client ID:")
                    .font(Theme.Typography.body)
                VStack(alignment: .leading, spacing: 2) {
                    Text("1. Open Google Cloud Console → APIs & Services → Credentials")
                    Text("2. Create OAuth client ID → Application type: Desktop app")
                    Text("3. Copy the Client ID — e.g. 1234567890-abc….apps.googleusercontent.com")
                    Text("4. Used for both Gmail and Calendar")
                }
                .font(Theme.Typography.small)
                .foregroundStyle(Theme.Colors.tertiaryText)
            }

            TextField("Paste your Google OAuth Client ID", text: $googleClientIdInput)
                .textFieldStyle(.plain)
                .font(Theme.Typography.body)
                .padding(Theme.Spacing.md)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )

            Button {
                let clientId = googleClientIdInput.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clientId.isEmpty else { return }
                GoogleAuthService.shared.clientId = clientId
                showingGoogleClientIdInput = false
                googleClientIdInput = ""
                Task {
                    switch googleClientIdNextAction {
                    case .gmail: await appState.connectGmail()
                    case .calendar: await appState.connectCalendar()
                    }
                }
            } label: {
                Text("Save & Connect")
                    .font(Theme.Typography.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Spacing.md)
                    .background(googleClientIdInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.gray.opacity(0.3) : Theme.Colors.accent)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            }
            .buttonStyle(.plain)
            .disabled(googleClientIdInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Spacer()
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 460, height: 380)
        .background(Theme.Colors.background)
    }

    // MARK: - X (Twitter) Expanded Content

    private var twitterExpandedContent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            // Error State
            if let error = appState.xSyncError {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)

                    Text(error)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
            }

            // Sync Button and Stats
            HStack(spacing: Theme.Spacing.md) {
                Button {
                    Task { await appState.syncX() }
                } label: {
                    HStack(spacing: Theme.Spacing.xs) {
                        if appState.isLoadingX {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 12))
                        }
                        Text("Sync All")
                    }
                    .font(Theme.Typography.caption)
                }
                .buttonStyle(GhostButtonStyle())
                .disabled(appState.isLoadingX)

                Spacer()

                // Stats
                VStack(alignment: .trailing, spacing: 2) {
                    Text(appState.xSyncStats)
                        .font(Theme.Typography.small)
                        .foregroundStyle(Theme.Colors.tertiaryText)

                    if let lastSync = appState.lastXSync {
                        Text("Last sync: \(lastSync.formatted(.relative(presentation: .named)))")
                            .font(Theme.Typography.small)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }
                }
            }

            // Info
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Colors.tertiaryText)

                    Text("X bookmarks merge into Bookmarks. Posts, followers, and DMs get their own sections.")
                        .font(Theme.Typography.small)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }

                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "creditcard")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Colors.tertiaryText)

                    Text("X removed free reads in 2026. Pay-per-use: ~$0.001/bookmark, ~$0.005/post. Legacy Basic ($200/mo): unlimited reads. Pro ($5k/mo): + DMs.")
                        .font(Theme.Typography.small)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
            }

            // Client ID + Disconnect row
            HStack(spacing: Theme.Spacing.md) {
                if !XAuthService.shared.clientId.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "key")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.Colors.tertiaryText)
                        Text("Client ID: \(xClientIdSuffix)")
                            .font(Theme.Typography.small)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }
                }

                Button {
                    xClientIdInput = XAuthService.shared.clientId
                    showingXClientIdInput = true
                } label: {
                    Text("Change Client ID")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    Task { await appState.disconnectX() }
                } label: {
                    Text("Disconnect X")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.priorityUrgent)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Short visual identifier for the currently-stored X Client ID
    /// (first 4 + last 4 chars). Client IDs aren't secrets, but the full
    /// value is long and noisy in the UI.
    private var xClientIdSuffix: String {
        let id = XAuthService.shared.clientId
        guard id.count > 8 else { return id }
        let prefix = id.prefix(4)
        let suffix = id.suffix(4)
        return "\(prefix)…\(suffix)"
    }

    /// Open a native AppKit file panel for the LinkedIn Connections CSV.
    /// Used in place of SwiftUI's `.fileImporter` because IntegrationsView
    /// is presented inside a `.sheet`, which suppresses `.fileImporter`
    /// presentations on macOS.
    private func presentLinkedInImportPanel() {
        let panel = NSOpenPanel()
        panel.title = "Import LinkedIn Connections"
        panel.message = "Pick the Connections.csv from your LinkedIn data export."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if let csv = UTType(filenameExtension: "csv") {
            panel.allowedContentTypes = [csv, .commaSeparatedText, .plainText]
        } else {
            panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        }

        // Bring the host window forward so the modal panel actually appears
        // attached to a key window rather than hanging behind the sheet.
        let host = NSApp.keyWindow ?? NSApp.mainWindow
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do {
                    try await appState.importConnectionsFromCSV(url: url)
                } catch {
                    print("LinkedIn import error: \(error)")
                }
            }
        }

        if let host {
            panel.beginSheetModal(for: host, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    // MARK: - Supabase Custom Project Expanded Content

    private var supabaseExpandedContent: some View {
        // Read projects fresh — the revision counter is referenced just to
        // make SwiftUI re-evaluate this view after add/remove mutations.
        let _ = supabaseProjectsRevision
        let projects = SupabaseProjectsService.shared.allProjects()
        return VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            if projects.isEmpty {
                Text("Connect one or more Supabase projects so the agent can read and write them directly. Each project becomes an MCP server — the agent gets list_tables, execute_sql, apply_migration, get_logs, deploy_edge_function, and more.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("\(projects.count) project\(projects.count == 1 ? "" : "s") registered. The agent gets one set of Supabase MCP tools per project, namespaced by slug.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.secondaryText)

                VStack(spacing: Theme.Spacing.sm) {
                    ForEach(projects) { project in
                        supabaseProjectRow(project)
                    }
                }
            }

            Button {
                resetSupabaseInputs()
                showingSupabaseInput = true
            } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 13))
                    Text(projects.isEmpty ? "Add your first Supabase project" : "Add another project")
                        .font(Theme.Typography.body)
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.sm)
                .background(Theme.Colors.accent.opacity(0.1))
                .foregroundStyle(Theme.Colors.accent)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            }
            .buttonStyle(.plain)
        }
    }

    private func supabaseProjectRow(_ project: SupabaseProject) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.text)
                Text("project_ref: \(project.projectRef) · MCP: supabase_\(project.slug)")
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .lineLimit(1)
                if !project.schemaNotes.isEmpty {
                    Text(project.schemaNotes)
                        .font(Theme.Typography.small)
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .lineLimit(2)
                }
            }
            Spacer()
            Button(role: .destructive) {
                SupabaseProjectsService.shared.deleteProject(project.id)
                supabaseProjectsRevision &+= 1
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            #if os(macOS)
            .help("Remove project")
            #endif
        }
        .padding(Theme.Spacing.md)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    // MARK: - Supabase Custom Project Input Sheet

    private var supabaseProjectInputSheet: some View {
        VStack(spacing: Theme.Spacing.xl) {
            HStack {
                Text("Add Supabase Project")
                    .font(Theme.Typography.title)
                Spacer()
                Button {
                    showingSupabaseInput = false
                    resetSupabaseInputs()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .frame(width: 24, height: 24)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Connect a Supabase project:")
                    .font(Theme.Typography.body)
                VStack(alignment: .leading, spacing: 2) {
                    Text("1. Go to supabase.com/dashboard/account/tokens")
                    Text("2. Generate a new Personal Access Token (PAT)")
                    Text("3. The project_ref is the subdomain of <ref>.supabase.co")
                    Text("4. Schema notes are optional — a sentence or two helps the agent")
                }
                .font(Theme.Typography.small)
                .foregroundStyle(Theme.Colors.tertiaryText)
            }

            TextField("Name (e.g. CRM)", text: $supabaseNameInput)
                .textFieldStyle(.plain)
                .font(Theme.Typography.body)
                .padding(Theme.Spacing.md)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )

            TextField("project_ref (e.g. abcdefghijklmnopqrst)", text: $supabaseRefInput)
                .textFieldStyle(.plain)
                .font(Theme.Typography.body)
                .padding(Theme.Spacing.md)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )

            SecureField("Personal Access Token (sbp_…)", text: $supabasePatInput)
                .textFieldStyle(.plain)
                .font(Theme.Typography.body)
                .padding(Theme.Spacing.md)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text("Schema notes (optional)")
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                TextEditor(text: $supabaseNotesInput)
                    .font(Theme.Typography.body)
                    .frame(height: 80)
                    .padding(Theme.Spacing.sm)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.md)
                            .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                    )
            }

            if let supabaseError {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                    Text(supabaseError)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.orange)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                supabaseError = nil
                do {
                    _ = try SupabaseProjectsService.shared.addProject(
                        name: supabaseNameInput,
                        projectRef: supabaseRefInput,
                        schemaNotes: supabaseNotesInput,
                        pat: supabasePatInput
                    )
                    supabaseProjectsRevision &+= 1
                    showingSupabaseInput = false
                    resetSupabaseInputs()
                } catch {
                    supabaseError = error.localizedDescription
                }
            } label: {
                Text("Save")
                    .font(Theme.Typography.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Spacing.md)
                    .background(supabaseSaveEnabled ? Theme.Colors.accent : Color.gray.opacity(0.3))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            }
            .buttonStyle(.plain)
            .disabled(!supabaseSaveEnabled)

            Spacer()
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 480, height: 580)
        .background(Theme.Colors.background)
    }

    private var supabaseSaveEnabled: Bool {
        !supabaseNameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !supabaseRefInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !supabasePatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - GenMedia Expanded Content

    private var genmediaExpandedContent: some View {
        // Reading the revision counter forces re-evaluation after "Verify".
        let _ = genmediaInstallRevision
        let installed = GenMediaService.shared.isInstalled()
        let binaryPath = GenMediaService.shared.binaryPath()
        let hasKey = FalAIService.shared.hasAPIKey()

        return VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            // CLI status
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: installed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(installed ? .green : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(installed ? "genmedia CLI installed" : "genmedia CLI not installed")
                        .font(Theme.Typography.caption)
                    if let path = binaryPath {
                        Text(path)
                            .font(Theme.Typography.small)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    } else {
                        Text("Install with: curl https://genmedia.sh/install -fsS | bash")
                            .font(Theme.Typography.small)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }
                }
                Spacer()
                Button("Setup") {
                    showingGenmediaSetup = true
                }
                .buttonStyle(GhostButtonStyle())
            }

            // API key status
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: hasKey ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(hasKey ? .green : .orange)
                Text(hasKey ? "fal API key set" : "No fal key — set in Settings → Voice Mode")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(hasKey ? Theme.Colors.text : .orange)
                Spacer()
            }

            // Test generation button — visible only when both prereqs are met
            if installed && hasKey {
                HStack(spacing: Theme.Spacing.sm) {
                    Button {
                        Task { await runGenmediaTest() }
                    } label: {
                        HStack(spacing: Theme.Spacing.xs) {
                            if isRunningGenmediaTest {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "play.circle")
                                    .font(.system(size: 11))
                            }
                            Text(isRunningGenmediaTest ? "Testing…" : "Test connection")
                                .font(Theme.Typography.caption)
                        }
                    }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(isRunningGenmediaTest)

                    if let msg = genmediaTestMessage {
                        Text(msg)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(genmediaTestIsError ? .orange : .green)
                            .lineLimit(2)
                    }
                    Spacer()
                }
            }

            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Colors.tertiaryText)
                Text("Once connected, ask the chat to generate images, video, audio, or music. Results land in your Files tab. Browse models at fal.ai/models.")
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
        }
    }

    /// Lightweight probe: `genmedia models flux --json --limit 1`. Confirms
    /// the binary + key combo can actually reach fal before the user invests
    /// in a real generation from the chat.
    @MainActor
    private func runGenmediaTest() async {
        isRunningGenmediaTest = true
        genmediaTestMessage = nil
        defer { isRunningGenmediaTest = false }
        do {
            _ = try await GenMediaService.shared.searchModels(query: "flux", limit: 1)
            genmediaTestMessage = "Connection OK"
            genmediaTestIsError = false
        } catch {
            genmediaTestMessage = error.localizedDescription
            genmediaTestIsError = true
        }
    }

    // MARK: - GenMedia Setup Sheet

    private var genmediaSetupSheet: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            // Header
            HStack {
                Text("Install genmedia CLI")
                    .font(Theme.Typography.title)
                Spacer()
                Button {
                    showingGenmediaSetup = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .frame(width: 24, height: 24)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("genmedia is fal.ai's CLI for running generative media models. Otto reuses your existing fal API key (set in Settings → Voice Mode); no extra config needed once the CLI is on your machine.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.secondaryText)

                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text("1. Open Terminal and paste:")
                        .font(Theme.Typography.body)
                    HStack(spacing: Theme.Spacing.sm) {
                        Text("curl https://genmedia.sh/install -fsS | bash")
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(Theme.Spacing.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                        Button {
                            #if os(macOS)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                "curl https://genmedia.sh/install -fsS | bash",
                                forType: .string
                            )
                            #endif
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.Colors.secondaryText)
                                .padding(8)
                                .background(Color.primary.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                        }
                        .buttonStyle(.plain)
                        .help("Copy")
                    }

                    Text("2. Once the install finishes, click Verify below. No restart needed.")
                        .font(Theme.Typography.body)

                    Text("3. (Optional) Run a quick test from Terminal:")
                        .font(Theme.Typography.body)
                    Text("genmedia models flux --json --limit 1")
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(Theme.Spacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                }

                // Verify row
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: GenMediaService.shared.isInstalled()
                          ? "checkmark.circle.fill"
                          : "exclamationmark.triangle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(GenMediaService.shared.isInstalled() ? .green : .orange)
                    Text(GenMediaService.shared.binaryPath()
                         ?? "Binary not detected yet — install above, then click Verify.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.secondaryText)
                    Spacer()
                    Button("Verify") {
                        // Force a re-render of any view reading `isInstalled()`.
                        genmediaInstallRevision &+= 1
                    }
                    .buttonStyle(GhostButtonStyle())
                }
            }

            Spacer()
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 520, height: 480)
        .background(Theme.Colors.background)
    }
}

#Preview {
    IntegrationsView()
        .environment(AppState())
}
