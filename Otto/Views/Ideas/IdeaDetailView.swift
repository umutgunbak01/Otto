import SwiftUI

struct IdeaDetailView: View {
    @Environment(AppState.self) private var appState
    let idea: Idea
    var isSidebarCollapsed: Bool = false
    var onToggleSidebar: (() -> Void)? = nil
    var onClose: (() -> Void)? = nil

    @State private var title: String = ""
    @State private var content: String = ""
    @State private var primaryCategory: PrimaryCategory = .personal
    @State private var status: Idea.Status = .raw
    @State private var isPropertiesExpanded: Bool = false
    @FocusState private var isTitleFocused: Bool

    // Get the current idea from appState for live updates
    private var currentIdea: Idea {
        appState.ideas.first { $0.id == idea.id } ?? idea
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top breadcrumb bar
            topBar
                .padding(.horizontal, 20)
                .padding(.vertical, 10)

            OttoDivider()

            // Notion-style full-page editor
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Title area — large Notion-style
                    titleArea
                        .padding(.top, 40)
                        .padding(.bottom, 4)

                    // Properties (collapsible, like Notion)
                    propertiesSection
                        .padding(.bottom, 16)

                    // Divider before content
                    OttoDivider()
                        .padding(.bottom, 20)

                    // Content editor — clean, Notion-style with block editor
                    contentEditor
                }
                .padding(.horizontal, ideaPadding)
                .padding(.bottom, 80)
            }
        }
        .onAppear { loadIdea() }
        .onChange(of: idea.id) { loadIdea() }
        .onChange(of: title) { saveChanges() }
        .onChange(of: content) { saveChanges() }
        .onChange(of: primaryCategory) { saveChanges() }
        .onChange(of: status) { saveChanges() }
    }

    private var ideaPadding: CGFloat {
        #if os(macOS)
        return 28
        #else
        return 20
        #endif
    }

    // MARK: - Top Bar

    private var topBar: some View {
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
                Image(systemName: "lightbulb")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.hobby)
                Text("Ideas")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.tertiaryText)

                if !title.isEmpty {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.Colors.tertiaryText.opacity(0.6))
                    Text(title)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .lineLimit(1)
                }
            }

            Spacer()

            // More menu
            Menu {
                // Convert type
                Menu("Convert to...") {
                    Button {
                        Task { await appState.convertIdea(idea, to: .todo) }
                    } label: {
                        Label("To-Do", systemImage: "checkmark.circle")
                    }
                    Button {
                        Task { await appState.convertIdea(idea, to: .note) }
                    } label: {
                        Label("Note", systemImage: "doc.text")
                    }
                    Button {
                        Task { await appState.convertIdea(idea, to: .reminder) }
                    } label: {
                        Label("Reminder", systemImage: "bell")
                    }
                }

                Divider()

                Button(role: .destructive) {
                    Task {
                        await appState.deleteIdea(idea)
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
    }

    // MARK: - Title Area

    private var titleArea: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Untitled", text: $title, axis: .vertical)
                .font(.system(size: 36, weight: .bold))
                .textFieldStyle(.plain)
                .foregroundStyle(Theme.Colors.text)
                .focused($isTitleFocused)
                .lineLimit(1...4)
        }
    }

    // MARK: - Properties Section (Notion-style)

    private var propertiesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Toggle button
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isPropertiesExpanded.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isPropertiesExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Properties")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Theme.Colors.tertiaryText)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)

            if isPropertiesExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    // Status property
                    ideaPropertyRow(icon: "circle.fill", label: "Status", iconColor: statusColor) {
                        IdeaStatusPicker(selection: $status)
                    }

                    // Category property
                    ideaPropertyRow(icon: "folder", label: "Category") {
                        CategorySelector(selection: $primaryCategory)
                    }

                    // Tags property
                    if !idea.domainTagIds.isEmpty {
                        ideaPropertyRow(icon: "tag", label: "Tags") {
                            FlowLayout(spacing: 4) {
                                ForEach(appState.tags(for: idea.domainTagIds)) { tag in
                                    TagChipView(tag: tag)
                                }
                            }
                        }
                    }

                    // Created
                    ideaPropertyRow(icon: "calendar", label: "Created") {
                        Text(formatDate(idea.createdAt))
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.Colors.secondaryText)
                    }

                    // Last edited
                    ideaPropertyRow(icon: "clock", label: "Last edited") {
                        Text(timeAgo(idea.updatedAt))
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.Colors.secondaryText)
                    }
                }
                .padding(.top, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.top, 8)
    }

    private func ideaPropertyRow<Content: View>(
        icon: String,
        label: String,
        iconColor: Color = Theme.Colors.tertiaryText,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 0) {
            // Label column
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: icon == "circle.fill" ? 6 : 12))
                    .foregroundStyle(iconColor)
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
            .frame(width: 120, alignment: .leading)

            // Value column
            content()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }

    // MARK: - Content Editor

    private var contentEditor: some View {
        NoteBlockEditor(content: $content)
            .frame(minHeight: 400)
    }

    // MARK: - Helpers

    private var statusColor: Color {
        switch status {
        case .raw: return Theme.Colors.tertiaryText
        case .researched: return Theme.Colors.work
        case .validated: return Theme.Colors.personal
        case .archived: return Theme.Colors.priorityHigh
        }
    }

    private func loadIdea() {
        title = idea.title
        content = idea.content
        primaryCategory = idea.primaryCategory
        status = idea.status
    }

    private func saveChanges() {
        var updated = idea
        updated.title = title
        updated.content = content
        updated.primaryCategory = primaryCategory
        updated.status = status

        Task { await appState.updateIdea(updated) }
    }

    private func timeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        else if interval < 3600 { return "\(Int(interval / 60))m ago" }
        else if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        else { return "\(Int(interval / 86400))d ago" }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter.string(from: date)
    }
}

#Preview {
    IdeaDetailView(idea: Idea(
        title: "AI-powered habit tracker",
        content: "An app that uses AI to analyze user behavior patterns and suggest optimal times for habit completion.",
        primaryCategory: .personal,
        status: .raw
    ))
    .environment(AppState())
    .frame(width: 700, height: 600)
}
