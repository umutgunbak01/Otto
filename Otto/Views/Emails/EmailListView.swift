import SwiftUI

struct EmailListView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText: String = ""
    @State private var searchScope: SearchScope = .subjectAndSender
    @State private var selectedEmailIds: Set<UUID> = []
    @State private var isSelectionMode: Bool = false
    @State private var navigationPath = NavigationPath()

    enum SearchScope: String, CaseIterable {
        case subjectAndSender = "Subject & Sender"
        case allContent = "All Content"

        var description: String {
            switch self {
            case .subjectAndSender: return "Search subject and sender only"
            case .allContent: return "Search subject, sender, body, and recipients"
            }
        }
    }

    var filteredEmails: [Email] {
        let sorted = appState.emails.sorted { $0.receivedDate > $1.receivedDate }

        if searchText.isEmpty {
            return sorted
        }

        return sorted.filter { email in
            switch searchScope {
            case .subjectAndSender:
                return email.subject.localizedCaseInsensitiveContains(searchText) ||
                       email.sender.localizedCaseInsensitiveContains(searchText) ||
                       (email.senderName?.localizedCaseInsensitiveContains(searchText) ?? false)
            case .allContent:
                return email.subject.localizedCaseInsensitiveContains(searchText) ||
                       email.sender.localizedCaseInsensitiveContains(searchText) ||
                       (email.senderName?.localizedCaseInsensitiveContains(searchText) ?? false) ||
                       email.body.localizedCaseInsensitiveContains(searchText) ||
                       email.recipients.contains { $0.localizedCaseInsensitiveContains(searchText) }
            }
        }
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            listPanel
                .navigationDestination(for: UUID.self) { emailId in
                    if let email = appState.emails.first(where: { $0.id == emailId }) {
                        EmailDetailView(email: email)
                    }
                }
        }
        .onChange(of: appState.locateItemId) { oldValue, newValue in
            if let itemId = newValue,
               appState.emails.contains(where: { $0.id == itemId }) {
                navigationPath.append(itemId)
                appState.locateItemId = nil
            }
        }
        .onAppear {
            if let itemId = appState.locateItemId,
               appState.emails.contains(where: { $0.id == itemId }) {
                navigationPath.append(itemId)
                appState.locateItemId = nil
            }
        }
    }

    // MARK: - List Panel

    private var listPanel: some View {
        VStack(spacing: 0) {
            // Header
            header

            OttoDivider()

            // Content - show emails if we have any (from Gmail)
            if filteredEmails.isEmpty && !appState.isGmailConnected {
                notConnectedState
            } else if filteredEmails.isEmpty {
                emptyState
            } else {
                emailList
            }
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: Theme.Spacing.md) {
            HStack(alignment: .center) {
                Text("⌬ EMAILS")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .tracking(3)
                    .foregroundStyle(Theme.Colors.cyan)
                    .shadow(color: Theme.Colors.cyanGlow, radius: 4)

                Text("\(filteredEmails.count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.Colors.borderSubtle)
                    .overlay(Rectangle().stroke(Theme.Colors.border, lineWidth: 1))

                Spacer()

                if !appState.emails.isEmpty {
                    // Selection mode controls
                    HStack(spacing: Theme.Spacing.sm) {
                        // Delete Selected button (only visible when items selected)
                        if isSelectionMode && !selectedEmailIds.isEmpty {
                            Button {
                                Task {
                                    await appState.deleteEmails(Array(selectedEmailIds))
                                    selectedEmailIds.removeAll()
                                    isSelectionMode = false
                                }
                            } label: {
                                HStack(spacing: Theme.Spacing.xs) {
                                    Image(systemName: "trash")
                                        .font(.system(size: 12))
                                    Text("Delete (\(selectedEmailIds.count))")
                                        .font(Theme.Typography.caption)
                                }
                                .foregroundStyle(Theme.Colors.bg0)
                                .padding(.horizontal, Theme.Spacing.md)
                                .padding(.vertical, Theme.Spacing.xs)
                                .background(Theme.Colors.priorityUrgent)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                            }
                            .buttonStyle(.plain)
                        }

                        // Select All / Deselect All button
                        if isSelectionMode {
                            Button {
                                if selectedEmailIds.count == filteredEmails.count {
                                    selectedEmailIds.removeAll()
                                } else {
                                    selectedEmailIds = Set(filteredEmails.map { $0.id })
                                }
                            } label: {
                                Text(selectedEmailIds.count == filteredEmails.count ? "Deselect All" : "Select All")
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(Theme.Colors.accent)
                            }
                            .buttonStyle(.plain)
                        }

                        // Toggle selection mode button
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isSelectionMode.toggle()
                                if !isSelectionMode {
                                    selectedEmailIds.removeAll()
                                }
                            }
                        } label: {
                            Text(isSelectionMode ? "Cancel" : "Select")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(isSelectionMode ? Theme.Colors.secondaryText : Theme.Colors.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if appState.isGmailConnected {
                    // Loading indicator
                    if appState.isLoadingGmail {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                }
            }

            // Search field (show when we have emails, regardless of Gmail connection)
            if !appState.emails.isEmpty {
                VStack(spacing: Theme.Spacing.sm) {
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Colors.tertiaryText)

                        TextField("Search emails...", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(Theme.Typography.body)

                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.Colors.tertiaryText)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.sm)
                    .background(Theme.Colors.borderSubtle.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))

                    // Search scope picker (visible when searching)
                    if !searchText.isEmpty {
                        HStack(spacing: Theme.Spacing.sm) {
                            Text("Search in:")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.tertiaryText)

                            ForEach(SearchScope.allCases, id: \.self) { scope in
                                Button {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        searchScope = scope
                                    }
                                } label: {
                                    Text(scope.rawValue)
                                        .font(Theme.Typography.caption)
                                        .foregroundStyle(searchScope == scope ? Theme.Colors.bg0 : Theme.Colors.secondaryText)
                                        .padding(.horizontal, Theme.Spacing.md)
                                        .padding(.vertical, Theme.Spacing.xs)
                                        .background(
                                            searchScope == scope
                                                ? Theme.Colors.accent
                                                : Theme.Colors.borderSubtle
                                        )
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }

                            Spacer()
                        }
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, Theme.Spacing.xl)
        .padding(.bottom, Theme.Spacing.md)
    }

    // MARK: - Email List

    private var emailList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredEmails) { email in
                    HStack(spacing: Theme.Spacing.sm) {
                        // Checkbox in selection mode
                        if isSelectionMode {
                            Button {
                                if selectedEmailIds.contains(email.id) {
                                    selectedEmailIds.remove(email.id)
                                } else {
                                    selectedEmailIds.insert(email.id)
                                }
                            } label: {
                                Image(systemName: selectedEmailIds.contains(email.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 20))
                                    .foregroundStyle(selectedEmailIds.contains(email.id) ? Theme.Colors.accent : Theme.Colors.tertiaryText)
                            }
                            .buttonStyle(.plain)
                            .transition(.scale.combined(with: .opacity))
                        }

                        EmailRowView(email: email)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if isSelectionMode {
                            if selectedEmailIds.contains(email.id) {
                                selectedEmailIds.remove(email.id)
                            } else {
                                selectedEmailIds.insert(email.id)
                            }
                        } else {
                            navigationPath.append(email.id)
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
        .animation(.easeInOut(duration: 0.2), value: isSelectionMode)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Image(systemName: "envelope")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(Theme.Colors.tertiaryText)

            VStack(spacing: Theme.Spacing.xs) {
                Text(searchText.isEmpty ? "No emails yet" : "No matching emails")
                    .font(Theme.Typography.title)
                Text("Sync your emails via Integrations")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Not Connected State

    private var notConnectedState: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Image(systemName: "envelope.badge.shield.half.filled")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(Theme.Colors.tertiaryText)

            VStack(spacing: Theme.Spacing.xs) {
                Text("Gmail Not Connected")
                    .font(Theme.Typography.title)
                Text("Connect your Gmail account in Integrations to sync emails")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .multilineTextAlignment(.center)
            }

            Button {
                Task { await appState.connectGmail() }
            } label: {
                HStack {
                    Image(systemName: "link")
                    Text("Connect Gmail")
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.sm)
                .background(Theme.Colors.accent)
                .foregroundStyle(Theme.Colors.bg0)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    EmailListView()
        .environment(AppState())
        .frame(width: 800, height: 500)
}
