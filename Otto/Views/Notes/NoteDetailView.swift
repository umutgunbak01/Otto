import SwiftUI

struct NoteDetailView: View {
    @Environment(AppState.self) private var appState
    let note: Note
    var isSidebarCollapsed: Bool = false
    var onToggleSidebar: (() -> Void)? = nil
    var onClose: (() -> Void)? = nil

    @State private var title: String = ""
    @State private var content: String = ""
    @State private var primaryCategory: PrimaryCategory = .personal
    @State private var isPropertiesExpanded: Bool = false
    @State private var isHoveringTitle: Bool = false
    @FocusState private var isTitleFocused: Bool

    // Get the current note from appState for live updates
    private var currentNote: Note {
        appState.notes.first { $0.id == note.id } ?? note
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

                    // Content editor — clean, Notion-style
                    contentEditor
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, notePadding)
                .padding(.bottom, 80)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { loadNote() }
        .onChange(of: note.id) { loadNote() }
        .onChange(of: title) { saveChanges() }
        .onChange(of: content) { saveChanges() }
        .onChange(of: primaryCategory) { saveChanges() }
    }

    private var notePadding: CGFloat {
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
                    Image(systemName: isSidebarCollapsed ? "sidebar.left" : "sidebar.left")
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
                Image(systemName: "doc.text")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.tertiaryText)
                Text("Notes")
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
                        Task { await appState.convertNote(note, to: .todo) }
                    } label: {
                        Label("To-Do", systemImage: "checkmark.circle")
                    }
                    Button {
                        Task { await appState.convertNote(note, to: .idea) }
                    } label: {
                        Label("Idea", systemImage: "lightbulb")
                    }
                    Button {
                        Task { await appState.convertNote(note, to: .reminder) }
                    } label: {
                        Label("Reminder", systemImage: "bell")
                    }
                }

                Divider()

                Button(role: .destructive) {
                    Task {
                        await appState.deleteNote(note)
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
                    // Category property
                    notionPropertyRow(icon: "folder", label: "Category") {
                        CategorySelector(selection: $primaryCategory)
                    }

                    // Tags property
                    if !note.domainTagIds.isEmpty {
                        notionPropertyRow(icon: "tag", label: "Tags") {
                            FlowLayout(spacing: 4) {
                                ForEach(appState.tags(for: note.domainTagIds)) { tag in
                                    TagChipView(tag: tag)
                                }
                            }
                        }
                    }

                    // Created
                    notionPropertyRow(icon: "calendar", label: "Created") {
                        Text(formatDate(note.createdAt))
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.Colors.secondaryText)
                    }

                    // Last edited
                    notionPropertyRow(icon: "clock", label: "Last edited") {
                        Text(timeAgo(note.updatedAt))
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

    private func notionPropertyRow<Content: View>(
        icon: String,
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 0) {
            // Label column
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.tertiaryText)
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

    private func loadNote() {
        title = note.title
        content = note.content
        primaryCategory = note.primaryCategory
    }

    private func saveChanges() {
        var updated = note
        updated.title = title
        updated.content = content
        updated.primaryCategory = primaryCategory

        Task { await appState.updateNote(updated) }
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

// Flow Layout for tags
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x,
                                       y: bounds.minY + result.positions[index].y),
                          proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            positions.append(CGPoint(x: currentX, y: currentY))
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }

        return (CGSize(width: maxWidth, height: currentY + lineHeight), positions)
    }
}

#Preview {
    NoteDetailView(note: Note(
        title: "Meeting Notes",
        content: "Discussed Q1 goals and team priorities.\n\nAction items:\n- Follow up with design team\n- Schedule review meeting\n- Prepare quarterly report\n\nKey decisions:\n1. Moving to weekly sprints\n2. New design system rollout in March\n3. Hiring two senior engineers",
        primaryCategory: .work
    ))
    .environment(AppState())
    .frame(width: 700, height: 600)
}
