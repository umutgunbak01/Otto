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

                    // Linked X Account
                    linkedXSection

                    OttoDivider()

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
                    .frame(width: 64, height: 64)

                Text(connection.initials)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(ContentType.connection.color)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(connection.fullName)
                    .font(Theme.Typography.largeTitle)

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
                .font(Theme.Typography.headline)

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
                .font(Theme.Typography.headline)

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                // LinkedIn profile — prominent button
                if let profileUrl = connection.profileUrl, let url = URL(string: profileUrl) {
                    Button {
                        openURL(url)
                    } label: {
                        HStack(spacing: Theme.Spacing.md) {
                            Image(systemName: "link.circle.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(.blue)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("View LinkedIn Profile")
                                    .font(Theme.Typography.headline)
                                    .foregroundStyle(Theme.Colors.text)

                                Text(profileUrl)
                                    .font(Theme.Typography.caption)
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
                                .fill(Color.blue.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.md)
                                .strokeBorder(Color.blue.opacity(0.15), lineWidth: 1)
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
                            .font(Theme.Typography.body)
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

                        Text("Connected \(formatDate(date))")
                            .font(Theme.Typography.body)
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

    // MARK: - Tags Section

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack {
                Text("Tags")
                    .font(Theme.Typography.headline)

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
                                    .font(Theme.Typography.caption)

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
                                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                                    .fill(ContentType.connection.color.opacity(0.1))
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
                    .background(Theme.Colors.borderSubtle.opacity(0.5))
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
                                .font(Theme.Typography.caption)
                                .foregroundStyle(ContentType.connection.color)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                                        .fill(ContentType.connection.color.opacity(0.1))
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
                    .font(Theme.Typography.headline)

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
                    .background(Theme.Colors.borderSubtle.opacity(0.5))
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
                .font(Theme.Typography.headline)

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
