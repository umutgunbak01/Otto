import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct NoteDetailView: View {
    @Environment(AppState.self) private var appState
    let note: Note
    var isSidebarCollapsed: Bool = false
    var onToggleSidebar: (() -> Void)? = nil
    var onClose: (() -> Void)? = nil
    /// Navigate to another note (used by "Duplicate" / "Edit a local copy").
    var onOpenNote: ((UUID) -> Void)? = nil

    @State private var controller: NoteEditorController?
    @State private var title: String = ""
    @State private var primaryCategory: PrimaryCategory = .personal
    @State private var isPropertiesExpanded: Bool = false
    @State private var showIconPicker: Bool = false
    @State private var isHoveringTitleArea: Bool = false
    @FocusState private var isTitleFocused: Bool

    // Save pipeline
    @State private var hasLoaded = false
    @State private var saveTask: Task<Void, Never>?
    @State private var lastPersistedContent: String = ""
    @State private var lastPersistedTitle: String = ""

    /// Live copy from the store (agent tools / sync update it while open).
    private var currentNote: Note {
        appState.notes.first { $0.id == note.id } ?? note
    }

    private var isNotionSynced: Bool { currentNote.notionPageId != nil }

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 20)
                .padding(.vertical, 10)

            OttoDivider()

            if isNotionSynced {
                notionBanner
            }

            if let controller {
                BlockEditorView(controller: controller) {
                    editorHeader
                }
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { loadNote() }
        .onDisappear {
            saveTask?.cancel()
            persistNow()
            if appState.notesEditorUndoManager === controller?.undoManager {
                appState.notesEditorUndoManager = nil
            }
        }
        .onChange(of: title) { _, _ in
            guard hasLoaded else { return }
            scheduleSave()
        }
        .onChange(of: primaryCategory) { _, _ in
            guard hasLoaded else { return }
            scheduleSave()
        }
        .onChange(of: currentNote.updatedAt) { _, _ in
            reconcileExternalChanges()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            flushBeforeTermination()
        }
    }

    // MARK: - Load / save pipeline

    private func loadNote() {
        let content = NoteDocument.normalizeSeparators(note.content)
        title = note.title
        primaryCategory = note.primaryCategory
        lastPersistedContent = content
        lastPersistedTitle = note.title

        let editorController = NoteEditorController(markdown: content, readOnly: isNotionSynced)
        editorController.onContentEdited = { scheduleSave() }
        editorController.onExitTop = { isTitleFocused = true }
        controller = editorController
        appState.notesEditorUndoManager = editorController.undoManager
        hasLoaded = true

        // A brand-new empty note starts in the title, Notion-style.
        if note.title.isEmpty && note.content.isEmpty {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(80))
                isTitleFocused = true
            }
        }
    }

    private func scheduleSave() {
        guard !isNotionSynced else { return }
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            persistNow()
        }
    }

    /// Build the updated note from editor state; nil when nothing changed.
    private func pendingUpdate() -> Note? {
        guard hasLoaded, let controller, !isNotionSynced else { return nil }
        let content = controller.isDirty ? controller.serialized() : lastPersistedContent
        let cleanTitle = title.replacingOccurrences(of: "\n", with: " ")

        var updated = currentNote
        guard cleanTitle != updated.title
            || content != NoteDocument.normalizeSeparators(updated.content)
            || primaryCategory != updated.primaryCategory else {
            controller.markSaved()
            return nil
        }
        updated.title = cleanTitle
        updated.content = content
        updated.primaryCategory = primaryCategory
        return updated
    }

    private func persistNow() {
        guard let updated = pendingUpdate() else { return }
        controller?.markSaved()
        lastPersistedContent = updated.content
        lastPersistedTitle = updated.title
        Task { await appState.updateNote(updated) }
    }

    /// At termination there is no further runloop turn for async saves.
    private func flushBeforeTermination() {
        saveTask?.cancel()
        guard let updated = pendingUpdate() else { return }
        controller?.markSaved()
        lastPersistedContent = updated.content
        lastPersistedTitle = updated.title
        appState.saveNoteBeforeTermination(updated)
    }

    /// The store changed under us (agent `update_note`, Notion sync, undo
    /// toast). Reload the editor when we have no local edits in flight.
    private func reconcileExternalChanges() {
        guard hasLoaded, let controller else { return }
        let storeContent = NoteDocument.normalizeSeparators(currentNote.content)
        if !controller.isDirty, storeContent != lastPersistedContent {
            lastPersistedContent = storeContent
            controller.reload(markdown: storeContent)
        }
        if title == lastPersistedTitle, currentNote.title != lastPersistedTitle {
            lastPersistedTitle = currentNote.title
            title = currentNote.title
        }
        controller.isReadOnly = isNotionSynced
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            if let onToggleSidebar {
                OttoGlyphButton(
                    systemImage: "sidebar.left",
                    help: isSidebarCollapsed ? "Show sidebar" : "Hide sidebar",
                    isActive: isSidebarCollapsed
                ) {
                    onToggleSidebar()
                }
            }

            // Breadcrumb (edcrumb — mono overline)
            Text("NOTES / \(primaryCategory.rawValue.uppercased())")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(Theme.Tracking.xxwide)
                .foregroundStyle(Theme.Colors.tertiaryText)
                .lineLimit(1)

            Spacer()

            Text(timeAgo(currentNote.updatedAt))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.Colors.tertiaryText)
                .help("Last edited")

            moreMenu
        }
    }

    private var moreMenu: some View {
        Menu {
            Section("\(NoteDocument.wordCount(editorContent())) words") {
                Button {
                    Task {
                        let copy = await appState.duplicateNote(currentNote)
                        onOpenNote?(copy.id)
                    }
                } label: {
                    Label("Duplicate", systemImage: "doc.on.doc")
                }

                Button {
                    persistNow()
                    let linkTitle = title.isEmpty ? "Untitled" : title
                    let link = "[\(linkTitle)](otto://note/\(currentNote.id.uuidString))"
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link, forType: .string)
                } label: {
                    Label("Copy Link", systemImage: "link")
                }

                Button {
                    exportAsMarkdown()
                } label: {
                    Label("Export as Markdown…", systemImage: "square.and.arrow.up")
                }
            }

            Menu("Convert to…") {
                Button {
                    persistNow()
                    Task { await appState.convertNote(currentNote, to: .todo) }
                } label: {
                    Label("To-Do", systemImage: "checkmark.circle")
                }
                Button {
                    persistNow()
                    Task { await appState.convertNote(currentNote, to: .idea) }
                } label: {
                    Label("Idea", systemImage: "lightbulb")
                }
                Button {
                    persistNow()
                    Task { await appState.convertNote(currentNote, to: .reminder) }
                } label: {
                    Label("Reminder (keeps note)", systemImage: "bell")
                }
            }

            Divider()

            Button(role: .destructive) {
                Task {
                    await appState.deleteNote(currentNote)
                    onClose?()
                }
            } label: {
                Label("Move to Trash", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.Colors.tertiaryText)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    private func editorContent() -> String {
        controller?.serialized() ?? currentNote.content
    }

    private func exportAsMarkdown() {
        persistNow()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = (title.isEmpty ? "Untitled" : title) + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var text = editorContent()
        if !title.isEmpty {
            text = "# \(title)\n\n" + text
        }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Notion banner

    private var notionBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.Colors.amber)
            Text("Synced from Notion — read-only. Re-sync replaces this copy.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Colors.amber)
                .lineLimit(1)

            Spacer()

            Button {
                Task {
                    let copy = await appState.duplicateNote(currentNote)
                    onOpenNote?(copy.id)
                }
            } label: {
                Text("Edit a local copy")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Colors.amber)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(Theme.Colors.tintAmber))
        .padding(.horizontal, 20)
        .padding(.top, 10)
    }

    // MARK: - Editor header (title + properties, scrolls with content)

    private var editorHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleArea
                .padding(.top, 36)
                .padding(.bottom, 4)

            propertiesSection
                .padding(.bottom, 14)

            OttoDivider()
                .padding(.bottom, 14)
        }
        .padding(.leading, 44)   // align with the block text column (gutter width)
        .padding(.trailing, 20)
        .onHover { isHoveringTitleArea = $0 }
    }

    private var titleArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Icon (Notion-style page icon)
            HStack(spacing: 8) {
                if let icon = currentNote.icon {
                    Button {
                        showIconPicker.toggle()
                    } label: {
                        Text(icon)
                            .font(.system(size: 34))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isNotionSynced)
                    .popover(isPresented: $showIconPicker, arrowEdge: .bottom) {
                        NoteIconPicker(currentIcon: currentNote.icon) { newIcon in
                            showIconPicker = false
                            setIcon(newIcon)
                        }
                    }
                } else if isHoveringTitleArea && !isNotionSynced {
                    Button {
                        showIconPicker.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "face.smiling")
                                .font(.system(size: 11))
                            Text("Add icon")
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showIconPicker, arrowEdge: .bottom) {
                        NoteIconPicker(currentIcon: nil) { newIcon in
                            showIconPicker = false
                            setIcon(newIcon)
                        }
                    }
                } else {
                    // Reserve the row so the layout doesn't jump on hover.
                    Color.clear.frame(height: currentNote.icon == nil ? 14 : 40)
                }
                Spacer()
            }

            TextField("Untitled", text: $title, axis: .vertical)
                .font(Font.system(size: 31, weight: .regular, design: .serif))
                .kerning(-0.4)
                .textFieldStyle(.plain)
                .foregroundStyle(Theme.Colors.text)
                .focused($isTitleFocused)
                .lineLimit(1...4)
                .disabled(isNotionSynced)
                .onSubmit {
                    controller?.focusFirstBlock()
                }
                .onKeyPress(.downArrow) {
                    controller?.focusFirstBlock()
                    return .handled
                }
        }
    }

    private func setIcon(_ icon: String?) {
        var updated = currentNote
        updated.icon = icon
        Task { await appState.updateNote(updated) }
    }

    // MARK: - Properties (collapsible, like Notion)

    private var propertiesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                    propertyRow(icon: "folder", label: "Category") {
                        CategorySelector(selection: $primaryCategory)
                            .disabled(isNotionSynced)
                    }

                    if !currentNote.domainTagIds.isEmpty {
                        propertyRow(icon: "tag", label: "Tags") {
                            FlowLayout(spacing: 4) {
                                ForEach(appState.tags(for: currentNote.domainTagIds)) { tag in
                                    TagChipView(tag: tag)
                                }
                            }
                        }
                    }

                    propertyRow(icon: "calendar", label: "Created") {
                        Text(formatDate(currentNote.createdAt))
                            .font(Theme.Typography.monoCaption)
                            .foregroundStyle(Theme.Colors.textDim)
                    }

                    propertyRow(icon: "clock", label: "Last edited") {
                        Text(timeAgo(currentNote.updatedAt))
                            .font(Theme.Typography.monoCaption)
                            .foregroundStyle(Theme.Colors.textDim)
                    }

                    propertyRow(icon: "textformat.123", label: "Words") {
                        Text("\(NoteDocument.wordCount(editorContent()))")
                            .font(Theme.Typography.monoCaption)
                            .foregroundStyle(Theme.Colors.textDim)
                    }
                }
                .padding(.top, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.top, 8)
    }

    private func propertyRow<Content: View>(
        icon: String,
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.tertiaryText)
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
            .frame(width: 120, alignment: .leading)

            content()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }

    // MARK: - Helpers

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

// MARK: - Icon picker

struct NoteIconPicker: View {
    let currentIcon: String?
    let onSelect: (String?) -> Void

    private static let icons = [
        "📝", "📄", "📌", "💡", "🎯", "🚀", "🔥", "⭐️", "✅", "📚",
        "🧠", "💭", "🗓️", "🏗️", "🔬", "🎨", "💼", "🏠", "✈️", "🍜",
        "🎧", "🏃", "💰", "🔑", "🌱", "⚙️", "📊", "🧪", "🎬", "🗺️"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(34)), count: 6), spacing: 4) {
                ForEach(Self.icons, id: \.self) { icon in
                    Button {
                        onSelect(icon)
                    } label: {
                        Text(icon)
                            .font(.system(size: 19))
                            .frame(width: 32, height: 32)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                                    .fill(icon == currentIcon ? Theme.Colors.selectTint : Color.clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if currentIcon != nil {
                Button {
                    onSelect(nil)
                } label: {
                    Text("Remove icon")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.red)
                }
                .buttonStyle(.plain)
                .padding(.leading, 2)
            }
        }
        .padding(12)
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
        content: "# Agenda\n- Review Q1 goals\n- [ ] Follow up with design team\n> Important quote\n---\nRegular paragraph text.",
        primaryCategory: .work
    ))
    .environment(AppState())
    .frame(width: 800, height: 640)
}
