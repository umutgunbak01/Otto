import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct ConnectionDetailView: View {
    @Environment(AppState.self) private var appState
    let connectionId: UUID
    var isSidebarCollapsed: Bool = false
    var onToggleSidebar: (() -> Void)? = nil
    var onClose: (() -> Void)? = nil

    @State private var editedNotes: String = ""
    @State private var editedTags: [String] = []
    @State private var newTag: String = ""
    @State private var isEditingNotes: Bool = false
    @State private var isEditingTags: Bool = false
    @State private var showingFollowerPicker: Bool = false

    // CRM fields — drafted values for the "More info" section.
    @State private var draftEmail: String = ""
    @State private var draftEducation: String = ""
    @State private var draftBirthday: Date = Date()
    @State private var hasBirthday: Bool = false
    @State private var isEditingMoreInfo: Bool = false
    @State private var showRecentTouchpoints: Bool = false

    /// Always reads the latest connection data from appState
    private var connection: Connection {
        appState.connections.first(where: { $0.id == connectionId }) ?? initialConnection
    }

    private let initialConnection: Connection

    init(connection: Connection, isSidebarCollapsed: Bool = false, onToggleSidebar: (() -> Void)? = nil, onClose: (() -> Void)? = nil) {
        self.connectionId = connection.id
        self.initialConnection = connection
        self.isSidebarCollapsed = isSidebarCollapsed
        self.onToggleSidebar = onToggleSidebar
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            headerBar

            OttoDivider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    // Profile header
                    profileHeader

                    // Closeness selector
                    closenessSection

                    OttoDivider()

                    // Contact info
                    contactSection

                    OttoDivider()

                    // More info — CRM additions (birthday, email, education, last contact)
                    moreInfoSection

                    OttoDivider()

                    // Linked X Account
                    linkedXSection

                    OttoDivider()

                    // Custom fields — user-defined CRM columns
                    if !appState.connectionCustomFields.isEmpty {
                        customFieldsSection
                        OttoDivider()
                    }

                    // Tags
                    tagsSection

                    OttoDivider()

                    // Notes
                    notesSection

                    // Delete
                    deleteSection
                }
                .padding(Theme.Spacing.xl)
            }
        }
        .onAppear {
            editedNotes = connection.notes
            editedTags = connection.tags
            draftEmail = connection.email ?? ""
            draftEducation = connection.education ?? ""
            if let bd = connection.birthday {
                draftBirthday = bd
                hasBirthday = true
            } else {
                draftBirthday = Date()
                hasBirthday = false
            }
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 10) {
            // Sidebar toggle button
            if let onToggleSidebar = onToggleSidebar {
                Button {
                    onToggleSidebar()
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 14))
                        .foregroundStyle(isSidebarCollapsed ? Theme.Colors.accent : Theme.Colors.tertiaryText)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isSidebarCollapsed ? "Show sidebar" : "Hide sidebar")
            }

            // Breadcrumb
            HStack(spacing: 6) {
                Image(systemName: "person.2")
                    .font(.system(size: 12))
                    .foregroundStyle(ContentType.connection.color)
                Text("Connections")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.tertiaryText)

                if !connection.fullName.isEmpty {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.Colors.tertiaryText.opacity(0.6))
                    Text(connection.fullName)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .lineLimit(1)
                }
            }

            Spacer()

            // More menu
            Menu {
                if let url = connection.profileUrl, let linkedInURL = URL(string: url) {
                    Button {
                        openURL(linkedInURL)
                    } label: {
                        Label("Open LinkedIn", systemImage: "link")
                    }

                    Divider()
                }

                Button(role: .destructive) {
                    Task {
                        await appState.deleteConnection(connection)
                        onClose?()
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            #if os(macOS)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            #endif
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: - Profile Header

    private var profileHeader: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.lg) {
            // Avatar
            ZStack {
                Circle()
                    .fill(ContentType.connection.color.opacity(0.12))
                    .frame(width: 40, height: 40)

                Text(connection.initials)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ContentType.connection.color)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(connection.fullName)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Colors.text)

                if !connection.headline.isEmpty {
                    Text(connection.headline)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }

                if !connection.company.isEmpty {
                    Text(connection.company)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.accent)
                }

                if !connection.location.isEmpty {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: "mappin")
                            .font(.system(size: 10))
                        Text(connection.location)
                            .font(Theme.Typography.caption)
                    }
                    .foregroundStyle(Theme.Colors.tertiaryText)
                }
            }

            Spacer()
        }
    }

    // MARK: - Closeness Section

    private var closenessSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Relationship")
                .hudLabel()

            HStack(spacing: Theme.Spacing.sm) {
                ForEach(ConnectionCloseness.allCases, id: \.self) { tier in
                    Button {
                        var updated = connection
                        updated.closeness = tier
                        Task {
                            await appState.updateConnection(updated)
                        }
                    } label: {
                        VStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: tier.icon)
                                .font(.system(size: 20))

                            Text(tier.label)
                                .font(.system(size: 10, weight: .medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.Spacing.sm)
                        .foregroundStyle(connection.closeness == tier ? .white : tier.color)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.md)
                                .fill(connection.closeness == tier ? tier.color : tier.color.opacity(0.1))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Contact Section

    private var contactSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Contact Information")
                .hudLabel()

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                // LinkedIn profile — prominent button
                if let profileUrl = connection.profileUrl, let url = URL(string: profileUrl) {
                    Button {
                        openURL(url)
                    } label: {
                        HStack(spacing: Theme.Spacing.md) {
                            Image(systemName: "link.circle.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(Theme.Colors.accentText)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("View LinkedIn Profile")
                                    .font(Theme.Typography.headline)
                                    .foregroundStyle(Theme.Colors.text)

                                Text(profileUrl)
                                    .font(Theme.Typography.monoCaption)
                                    .foregroundStyle(Theme.Colors.tertiaryText)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.Colors.tertiaryText)
                        }
                        .padding(Theme.Spacing.md)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.md)
                                .fill(Theme.Colors.panel)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.md)
                                .strokeBorder(Theme.Colors.border, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }

                // Email
                if let email = connection.email {
                    HStack(spacing: Theme.Spacing.md) {
                        Image(systemName: "envelope")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.Colors.secondaryText)
                            .frame(width: 20)

                        Text(email)
                            .font(Theme.Typography.monoBody)
                            .foregroundStyle(Theme.Colors.text)

                        Spacer()

                        Button {
                            if let url = URL(string: "mailto:\(email)") {
                                openURL(url)
                            }
                        } label: {
                            Text("Send Email")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Connection date
                if let date = connection.connectionDate {
                    HStack(spacing: Theme.Spacing.md) {
                        Image(systemName: "calendar")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.Colors.secondaryText)
                            .frame(width: 20)

                        (Text("Connected ").font(Theme.Typography.body)
                            + Text(formatDate(date)).font(Theme.Typography.monoCaption))
                            .foregroundStyle(Theme.Colors.secondaryText)
                    }
                }

                // No contact info
                if connection.email == nil && connection.profileUrl == nil {
                    Text("No contact information available")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .italic()
                }
            }
        }
    }

    // MARK: - More Info Section (CRM additions)

    private var moreInfoSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack {
                Text("More Info")
                    .hudLabel()
                Spacer()
                Button {
                    if isEditingMoreInfo {
                        saveMoreInfo()
                    }
                    isEditingMoreInfo.toggle()
                } label: {
                    Text(isEditingMoreInfo ? "Done" : "Edit")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.accent)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                if isEditingMoreInfo {
                    moreInfoEditRow(icon: "envelope", label: "Email") {
                        TextField("name@example.com", text: $draftEmail)
                            .textFieldStyle(.plain)
                            .font(Theme.Typography.body)
                    }

                    moreInfoEditRow(icon: "graduationcap", label: "Education") {
                        TextField("e.g. MIT, BS CS, 2018", text: $draftEducation)
                            .textFieldStyle(.plain)
                            .font(Theme.Typography.body)
                    }

                    moreInfoEditRow(icon: "gift", label: "Birthday") {
                        HStack(spacing: 8) {
                            Toggle("", isOn: $hasBirthday)
                                .toggleStyle(.switch)
                                .labelsHidden()
                            if hasBirthday {
                                DatePicker("", selection: $draftBirthday, displayedComponents: .date)
                                    .datePickerStyle(.field)
                                    .labelsHidden()
                            } else {
                                Text("None")
                                    .font(Theme.Typography.body)
                                    .foregroundStyle(Theme.Colors.tertiaryText)
                                    .italic()
                            }
                            Spacer()
                        }
                    }
                } else {
                    moreInfoDisplayRow(icon: "envelope", label: "Email", value: connection.email, placeholder: "Not set", mono: true)
                    moreInfoDisplayRow(icon: "graduationcap", label: "Education", value: connection.education, placeholder: "Not set")
                    moreInfoDisplayRow(
                        icon: "gift",
                        label: "Birthday",
                        value: connection.birthday.map { formatDate($0) },
                        placeholder: "Not set",
                        mono: true
                    )
                    lastContactRow
                }
            }
        }
    }

    private func moreInfoEditRow<Content: View>(icon: String, label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(Theme.Colors.secondaryText)
                .frame(width: 20)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }

    private func moreInfoDisplayRow(icon: String, label: String, value: String?, placeholder: String, mono: Bool = false) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(Theme.Colors.secondaryText)
                .frame(width: 20)
            if let value = value, !value.isEmpty {
                Text(value)
                    .font(mono ? Theme.Typography.monoBody : Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.text)
            } else {
                Text(placeholder)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .italic()
            }
            Spacer()
        }
    }

    private var lastContactRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .frame(width: 20)
                if let date = connection.lastContactedAt {
                    (Text("Last contact: ").font(Theme.Typography.body)
                        + Text(ConnectionDateFormat.relative(date)).font(Theme.Typography.monoCaption))
                        .foregroundStyle(Theme.Colors.text)
                    Text(ConnectionDateFormat.short(date))
                        .font(Theme.Typography.monoCaption)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                } else {
                    Text("No recorded touchpoints")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .italic()
                }
                Spacer()
                if connection.lastContactedAt != nil {
                    Button {
                        showRecentTouchpoints.toggle()
                    } label: {
                        Image(systemName: showRecentTouchpoints ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }
                    .buttonStyle(.plain)
                }
            }

            if showRecentTouchpoints {
                let touchpoints = ContactActivityIndexer.recentTouchpoints(
                    for: connection,
                    emails: appState.emails,
                    calendarEvents: appState.calendarEvents,
                    meetings: appState.meetings,
                    xDMs: appState.xDirectMessages,
                    xFollowers: appState.xFollowers
                )
                if touchpoints.isEmpty {
                    Text("No recent emails or meetings matched.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .padding(.leading, 30)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(touchpoints) { touchpoint in
                            HStack(spacing: 6) {
                                Image(systemName: touchpoint.kind.iconName)
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.Colors.tertiaryText)
                                Text(ConnectionDateFormat.short(touchpoint.date))
                                    .font(Theme.Typography.monoCaption)
                                    .foregroundStyle(Theme.Colors.secondaryText)
                                Text(touchpoint.title)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.Colors.text)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(.leading, 30)
                }
            }
        }
    }

    // MARK: - Custom Fields Section

    private var customFieldsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Custom Fields")
                .hudLabel()

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                ForEach(appState.connectionCustomFields.sorted(by: { $0.sortIndex < $1.sortIndex })) { definition in
                    DetailCustomFieldRow(definition: definition, connection: connection)
                }
            }
        }
    }

    // MARK: - Tags Section

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack {
                Text("Tags")
                    .hudLabel()

                Spacer()

                Button {
                    if isEditingTags {
                        saveTagChanges()
                    }
                    isEditingTags.toggle()
                } label: {
                    Text(isEditingTags ? "Done" : "Edit")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.accent)
                }
                .buttonStyle(.plain)
            }

            if isEditingTags {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    FlowLayout(spacing: Theme.Spacing.xs) {
                        ForEach(editedTags, id: \.self) { tag in
                            HStack(spacing: 4) {
                                Text(tag)
                                    .font(Theme.Typography.monoSmall)

                                Button {
                                    editedTags.removeAll { $0 == tag }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 10))
                                }
                                .buttonStyle(.plain)
                            }
                            .foregroundStyle(ContentType.connection.color)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(ContentType.connection.color.opacity(0.12))
                            )
                        }
                    }

                    HStack {
                        TextField("Add tag...", text: $newTag)
                            .textFieldStyle(.plain)
                            .font(Theme.Typography.caption)
                            .onSubmit { addTag() }

                        Button { addTag() } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(Theme.Colors.accent)
                        }
                        .buttonStyle(.plain)
                        .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, Theme.Spacing.xs)
                    .background(Theme.Colors.bgInput)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                }
            } else {
                if connection.tags.isEmpty {
                    Text("No tags")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .italic()
                } else {
                    FlowLayout(spacing: Theme.Spacing.xs) {
                        ForEach(connection.tags, id: \.self) { tag in
                            Text(tag)
                                .font(Theme.Typography.monoSmall)
                                .foregroundStyle(ContentType.connection.color)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(ContentType.connection.color.opacity(0.12))
                                )
                        }
                    }
                }
            }
        }
    }

    // MARK: - Notes Section

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack {
                Text("Notes")
                    .hudLabel()

                Spacer()

                Button {
                    if isEditingNotes {
                        saveNotesChanges()
                    }
                    isEditingNotes.toggle()
                } label: {
                    Text(isEditingNotes ? "Done" : "Edit")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.accent)
                }
                .buttonStyle(.plain)
            }

            if isEditingNotes {
                TextEditor(text: $editedNotes)
                    .font(Theme.Typography.body)
                    .scrollContentBackground(.hidden)
                    .padding(Theme.Spacing.sm)
                    .frame(minHeight: 100)
                    .background(Theme.Colors.bgInput)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            } else {
                if connection.notes.isEmpty {
                    Text("No notes")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .italic()
                } else {
                    Text(connection.notes)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.text)
                }
            }
        }
    }

    // MARK: - Linked X Section

    private var linkedXSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Linked X Account")
                .hudLabel()

            if let follower = appState.linkedFollower(for: connection) {
                // Show linked X follower
                HStack(spacing: Theme.Spacing.md) {
                    // Avatar
                    ZStack {
                        Circle()
                            .fill(ContentType.xFollower.color.opacity(0.12))
                            .frame(width: 40, height: 40)

                        Text(follower.initials)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(ContentType.xFollower.color)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(follower.displayName)
                            .font(Theme.Typography.headline)

                        Text("@\(follower.username)")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.secondaryText)
                    }

                    Spacer()

                    Button {
                        Task {
                            await appState.unlinkFollowerFromConnection(followerId: follower.id)
                        }
                    } label: {
                        Text("Unlink")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.priorityUrgent)
                    }
                    .buttonStyle(.plain)
                }
                .padding(Theme.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .fill(ContentType.xFollower.color.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .strokeBorder(ContentType.xFollower.color.opacity(0.15), lineWidth: 1)
                )
            } else if appState.isXConnected && !appState.xFollowers.isEmpty {
                // Show link button
                Button {
                    showingFollowerPicker = true
                } label: {
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: "link")
                            .font(.system(size: 14))
                        Text("Link X Account")
                            .font(Theme.Typography.body)
                    }
                    .foregroundStyle(ContentType.xFollower.color)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.md)
                            .fill(ContentType.xFollower.color.opacity(0.1))
                    )
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showingFollowerPicker) {
                    followerPickerSheet
                }
            } else {
                Text("Connect X in Integrations to link accounts")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .italic()
            }
        }
    }

    // MARK: - Follower Picker Sheet

    private var followerPickerSheet: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Link X Follower")
                    .font(Theme.Typography.headline)
                Spacer()
                Button {
                    showingFollowerPicker = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
                .buttonStyle(.plain)
            }
            .padding(Theme.Spacing.lg)

            OttoDivider()

            // Follower list
            if appState.xFollowers.isEmpty {
                VStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "person.2")
                        .font(.system(size: 24, weight: .thin))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                    Text("No X followers available")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(appState.xFollowers.sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }) { follower in
                            Button {
                                Task {
                                    await appState.linkFollowerToConnection(followerId: follower.id, connectionId: connection.id)
                                }
                                showingFollowerPicker = false
                            } label: {
                                HStack(spacing: Theme.Spacing.md) {
                                    ZStack {
                                        Circle()
                                            .fill(ContentType.xFollower.color.opacity(0.12))
                                            .frame(width: 30, height: 30)
                                        Text(follower.initials)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(ContentType.xFollower.color)
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(follower.displayName)
                                            .font(Theme.Typography.headline)
                                            .foregroundStyle(Theme.Colors.text)
                                            .lineLimit(1)
                                        Text("@\(follower.username)")
                                            .font(Theme.Typography.caption)
                                            .foregroundStyle(Theme.Colors.secondaryText)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if follower.isMutual {
                                        Image(systemName: "arrow.left.arrow.right")
                                            .font(.system(size: 10))
                                            .foregroundStyle(ContentType.xFollower.color)
                                    }
                                }
                                .padding(.horizontal, Theme.Spacing.md)
                                .padding(.vertical, Theme.Spacing.sm)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, Theme.Spacing.xs)
                }
            }
        }
        .frame(width: 400, height: 500)
        .background(Theme.Colors.background)
    }

    // MARK: - Delete Section

    private var deleteSection: some View {
        HStack {
            Spacer()

            Button {
                Task {
                    await appState.deleteConnection(connection)
                    onClose?()
                }
            } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "trash")
                    Text("Delete Connection")
                }
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.priorityUrgent)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.sm)
                .background(Theme.Colors.priorityUrgent.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(.top, Theme.Spacing.lg)
    }

    // MARK: - Helper Methods

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        return formatter.string(from: date)
    }

    private func addTag() {
        let tag = newTag.trimmingCharacters(in: .whitespaces)
        guard !tag.isEmpty, !editedTags.contains(tag) else { return }
        editedTags.append(tag)
        newTag = ""
    }

    private func saveTagChanges() {
        var updated = connection
        updated.tags = editedTags
        Task {
            await appState.updateConnection(updated)
        }
    }

    private func saveNotesChanges() {
        var updated = connection
        updated.notes = editedNotes
        Task {
            await appState.updateConnection(updated)
        }
    }

    private func saveMoreInfo() {
        var updated = connection
        let email = draftEmail.trimmingCharacters(in: .whitespaces)
        updated.email = email.isEmpty ? nil : email
        let education = draftEducation.trimmingCharacters(in: .whitespaces)
        updated.education = education.isEmpty ? nil : education
        updated.birthday = hasBirthday ? draftBirthday : nil
        Task {
            await appState.updateConnection(updated)
        }
    }
}

// MARK: - Detail-view wrapper around CustomFieldCell that holds its own edit state.

private struct DetailCustomFieldRow: View {
    @Environment(AppState.self) private var appState
    let definition: CustomFieldDefinition
    let connection: Connection

    @State private var isEditing: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            HStack(spacing: 4) {
                Image(systemName: definition.kind.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Colors.tertiaryText)
                Text(definition.name)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }
            .frame(width: 140, alignment: .leading)

            CustomFieldCell(
                definition: definition,
                value: connection.customFields[definition.id],
                isEditing: isEditing,
                onBeginEdit: { isEditing = true },
                onEndEdit: { isEditing = false },
                onCommit: { newValue in
                    Task {
                        await appState.setCustomFieldValue(
                            on: connection.id,
                            fieldId: definition.id,
                            value: newValue
                        )
                    }
                    isEditing = false
                }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    ConnectionDetailView(
        connection: Connection(
            firstName: "John",
            lastName: "Doe",
            headline: "Software Engineer",
            company: "Google",
            location: "San Francisco, CA",
            email: "john.doe@gmail.com",
            profileUrl: "https://linkedin.com/in/johndoe",
            connectionDate: Date().addingTimeInterval(-86400 * 180),
            notes: "Met at Google I/O conference. Interested in AI/ML projects.",
            tags: ["engineering", "tech", "ai"],
            closeness: .friendly
        )
    )
    .environment(AppState())
    .frame(width: 600, height: 800)
}
