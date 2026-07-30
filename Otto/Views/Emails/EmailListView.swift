import SwiftUI

struct EmailListView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText: String = ""
    @State private var searchScope: SearchScope = .subjectAndSender
    @State private var selectedEmailIds: Set<UUID> = []
    @State private var isSelectionMode: Bool = false
    @State private var navigationPath = NavigationPath()
    @State private var showNeedsReplyOnly: Bool = false
    @AppStorage(EmailTriageSettings.enabledKey) private var triageEnabled: Bool = EmailTriageSettings.defaultEnabled

    private var replyDrafts: ReplyDraftService { .shared }

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

    /// The needs-reply queue (triage enabled only) — recomputed per render;
    /// a single pass over emails, cheap next to the list body itself.
    private var needsReplyQueue: [Email] {
        guard triageEnabled else { return [] }
        return EmailTriageService.needsReply(emails: appState.emails, blockedSenders: appState.blockedSenders)
    }

    var filteredEmails: [Email] {
        let sorted: [Email]
        if triageEnabled && showNeedsReplyOnly {
            sorted = needsReplyQueue
        } else {
            sorted = appState.emails.sorted { $0.receivedDate > $1.receivedDate }
        }

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
        .sheet(item: Binding(
            get: { replyDrafts.draftingFor },
            set: { if $0 == nil { replyDrafts.dismiss() } }
        )) { email in
            ReplyDraftSheet(email: email, onClose: { replyDrafts.dismiss() })
                .environment(appState)
        }
    }

    // MARK: - List Panel

    private var listPanel: some View {
        VStack(spacing: 0) {
            // Header
            header

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

    /// Toolbar toggle for the needs-reply queue, styled after OttoBarButton
    /// with an active (selected) state the shared primitive doesn't have.
    private var needsReplyChip: some View {
        let count = needsReplyQueue.count
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { showNeedsReplyOnly.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrowshape.turn.up.left.circle")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(showNeedsReplyOnly ? Theme.Colors.accentText : Theme.Colors.tertiaryText)
                Text(count > 0 ? "Needs reply · \(count)" : "Needs reply")
                    .font(.system(size: 11.5))
                    .foregroundStyle(showNeedsReplyOnly ? Theme.Colors.accentText : Theme.Colors.textDim)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .fill(showNeedsReplyOnly ? Theme.Colors.selectTint : Theme.Colors.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .strokeBorder(showNeedsReplyOnly ? Color.clear : Theme.Colors.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Emails")
                .font(Theme.Typography.display)
                .foregroundStyle(Theme.Colors.text)

            OttoCountChip(text: countChipText)

            Spacer(minLength: 8)

            if !appState.emails.isEmpty {
                // Selection mode controls
                if isSelectionMode && !selectedEmailIds.isEmpty {
                    deleteSelectedButton
                }

                // Select All / Deselect All button
                if isSelectionMode {
                    OttoBarButton(label: selectedEmailIds.count == filteredEmails.count ? "Deselect All" : "Select All") {
                        if selectedEmailIds.count == filteredEmails.count {
                            selectedEmailIds.removeAll()
                        } else {
                            selectedEmailIds = Set(filteredEmails.map { $0.id })
                        }
                    }
                }

                // Toggle selection mode button
                OttoBarButton(label: isSelectionMode ? "Cancel" : "Select") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isSelectionMode.toggle()
                        if !isSelectionMode {
                            selectedEmailIds.removeAll()
                        }
                    }
                }

                // Needs-reply queue toggle (email triage, opt-in setting)
                if triageEnabled {
                    needsReplyChip
                }

                // Search scope pills — only affect filtering while a query
                // is typed, so they can stay visible at all times.
                OttoPillRail(
                    options: SearchScope.allCases.map { (value: $0, label: $0.rawValue) },
                    selection: $searchScope
                )

                OttoSearchMini(placeholder: "Search emails…", text: $searchText, width: 200)
            }

            if appState.isGmailConnected {
                // Loading indicator
                if appState.isLoadingGmail {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 28, height: 28)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var countChipText: String {
        let unread = filteredEmails.filter { !$0.isRead }.count
        return "\(filteredEmails.count) · \(unread) unread"
    }

    /// Red-tinted capsule delete button (mockup's danger chip button).
    private var deleteSelectedButton: some View {
        Button {
            Task {
                await appState.deleteEmails(Array(selectedEmailIds))
                selectedEmailIds.removeAll()
                isSelectionMode = false
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "trash")
                    .font(.system(size: 10.5, weight: .medium))
                Text("Delete (\(selectedEmailIds.count))")
                    .font(.system(size: 11.5))
            }
            .foregroundStyle(Theme.Colors.red)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Capsule().fill(Theme.Colors.tintRed))
            .overlay(Capsule().strokeBorder(Theme.Colors.red.opacity(0.2), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Email List

    /// Display-only date grouping over `filteredEmails` — the filtered array
    /// (and its sort order) is the source of truth; this just buckets it for
    /// OttoGroupLabel headers.
    private var groupedEmails: [(label: String, emails: [Email])] {
        let calendar = Calendar.current
        let now = Date()

        var today: [Email] = []
        var yesterday: [Email] = []
        var thisWeek: [Email] = []
        var earlier: [Email] = []

        for email in filteredEmails {
            if calendar.isDateInToday(email.receivedDate) {
                today.append(email)
            } else if calendar.isDateInYesterday(email.receivedDate) {
                yesterday.append(email)
            } else if calendar.isDate(email.receivedDate, equalTo: now, toGranularity: .weekOfYear) {
                thisWeek.append(email)
            } else {
                earlier.append(email)
            }
        }

        var groups: [(label: String, emails: [Email])] = []
        if !today.isEmpty { groups.append(("Today", today)) }
        if !yesterday.isEmpty { groups.append(("Yesterday", yesterday)) }
        if !thisWeek.isEmpty { groups.append(("This week", thisWeek)) }
        if !earlier.isEmpty { groups.append(("Earlier", earlier)) }
        return groups
    }

    private var emailList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(groupedEmails, id: \.label) { group in
                    OttoGroupLabel(text: group.label, count: group.emails.count)

                    ForEach(group.emails) { email in
                        HStack(spacing: Theme.Spacing.sm) {
                            // Checkbox in selection mode
                            if isSelectionMode {
                                selectionCheckbox(for: email)
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
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.xxl)
            .frame(maxWidth: 828)
            .frame(maxWidth: .infinity)
        }
        .animation(.easeInOut(duration: 0.2), value: isSelectionMode)
    }

    /// Rounded-square selection check (mirrors TodoRowView's checkbox).
    private func selectionCheckbox(for email: Email) -> some View {
        let isChecked = selectedEmailIds.contains(email.id)
        return Button {
            if isChecked {
                selectedEmailIds.remove(email.id)
            } else {
                selectedEmailIds.insert(email.id)
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 5.5)
                    .strokeBorder(
                        isChecked ? Theme.Colors.cyan.opacity(0.45) : Color.white.opacity(0.22),
                        lineWidth: 1.5
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 5.5)
                            .fill(isChecked ? Theme.Colors.tintTeal : Color.clear)
                    )
                    .frame(width: 16, height: 16)

                if isChecked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.Colors.cyan)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .transition(.scale.combined(with: .opacity))
    }

    // MARK: - Empty State

    private var emptyState: some View {
        OttoEmptyState(
            systemImage: "envelope",
            title: searchText.isEmpty ? "No emails yet" : "No matching emails",
            message: "Sync your emails via Integrations"
        )
    }

    // MARK: - Not Connected State

    private var notConnectedState: some View {
        OttoEmptyState(
            systemImage: "envelope.badge.shield.half.filled",
            title: "Connect Gmail",
            message: "Connect your Gmail account in Integrations to sync emails"
        ) {
            OttoNewButton(label: "Connect Gmail", systemImage: "link") {
                Task { await appState.connectGmail() }
            }
        }
    }
}

#Preview {
    EmailListView()
        .environment(AppState())
        .frame(width: 800, height: 500)
}
