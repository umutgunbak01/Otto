import SwiftUI
import AppKit

struct NoteListView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedCategory: PrimaryCategory?
    @State private var selectedNoteId: UUID?
    @State private var searchText: String = ""
    @State private var isSidebarCollapsed: Bool = false
    @State private var isSelectMode: Bool = false
    @State private var selectedNoteIds: Set<UUID> = []
    @State private var showDeleteConfirmation: Bool = false
    @State private var lastClickedNoteId: UUID?
    @State private var showTrash: Bool = false
    @State private var hoveredNoteId: UUID?

    private var activeNotes: [Note] { appState.activeNotes }

    var filteredNotes: [Note] {
        var notes = activeNotes

        if let category = selectedCategory {
            notes = notes.filter { $0.primaryCategory == category }
        }

        if !searchText.isEmpty {
            notes = notes.filter {
                $0.title.localizedCaseInsensitiveContains(searchText)
                    || NoteDocument.plainText($0.content).localizedCaseInsensitiveContains(searchText)
            }
        }

        return notes.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Pinned first, then date buckets — Notion-ish sidebar grouping.
    private var groupedNotes: [(title: String, notes: [Note])] {
        let notes = filteredNotes
        var groups: [(String, [Note])] = []

        let pinned = notes.filter(\.isPinned)
        if !pinned.isEmpty { groups.append(("Pinned", pinned)) }

        let rest = notes.filter { !$0.isPinned }
        let calendar = Calendar.current
        let now = Date()
        var today: [Note] = [], yesterday: [Note] = [], week: [Note] = [], older: [Note] = []
        for note in rest {
            if calendar.isDateInToday(note.updatedAt) { today.append(note) }
            else if calendar.isDateInYesterday(note.updatedAt) { yesterday.append(note) }
            else if note.updatedAt > now.addingTimeInterval(-7 * 86400) { week.append(note) }
            else { older.append(note) }
        }
        if !today.isEmpty { groups.append(("Today", today)) }
        if !yesterday.isEmpty { groups.append(("Yesterday", yesterday)) }
        if !week.isEmpty { groups.append(("Previous 7 Days", week)) }
        if !older.isEmpty { groups.append(("Older", older)) }
        return groups
    }

    var body: some View {
        HStack(spacing: 0) {
            if !isSidebarCollapsed {
                noteSidebar
                    .frame(width: 260)
                    .transition(.move(edge: .leading).combined(with: .opacity))

                Rectangle()
                    .fill(Theme.Colors.border)
                    .frame(width: 1)
            }

            if let noteId = selectedNoteId,
               let note = appState.notes.first(where: { $0.id == noteId }) {
                NoteDetailView(
                    note: note,
                    isSidebarCollapsed: isSidebarCollapsed,
                    onToggleSidebar: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isSidebarCollapsed.toggle()
                        }
                    },
                    onClose: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedNoteId = nil
                        }
                    },
                    onOpenNote: { id in
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedNoteId = id
                        }
                    }
                )
                .frame(maxWidth: .infinity)
                .transition(.opacity)
                .id(noteId)
            } else {
                emptyEditor
                    .frame(maxWidth: .infinity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isSidebarCollapsed)
        .animation(.easeInOut(duration: 0.15), value: selectedNoteId)
        .onChange(of: appState.locateItemId) { _, newValue in
            if let itemId = newValue {
                openLocatedNote(itemId)
            }
        }
        .onAppear {
            if let itemId = appState.locateItemId {
                openLocatedNote(itemId)
            }
            if selectedNoteId == nil, let first = filteredNotes.first {
                selectedNoteId = first.id
            }
        }
        .alert("Move \(selectedNoteIds.count) note\(selectedNoteIds.count == 1 ? "" : "s") to Trash?",
               isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Move to Trash", role: .destructive) {
                deleteSelectedNotes()
            }
        } message: {
            Text("Notes in the Trash can be restored for 30 days.")
        }
    }

    private func openLocatedNote(_ itemId: UUID) {
        guard let located = appState.notes.first(where: { $0.id == itemId }) else { return }
        // A deep link into a trashed note restores it.
        if located.deletedAt != nil {
            Task { await appState.restoreNotes([itemId]) }
        }
        selectedNoteId = itemId
        appState.locateItemId = nil
    }

    // MARK: - Batch delete

    private func deleteSelectedNotes() {
        let idsToDelete = selectedNoteIds
        if let currentId = selectedNoteId, idsToDelete.contains(currentId) {
            selectedNoteId = filteredNotes.first(where: { !idsToDelete.contains($0.id) })?.id
        }
        Task {
            await appState.deleteNotes(idsToDelete)
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedNoteIds.removeAll()
                isSelectMode = false
            }
        }
    }

    // MARK: - Create new note

    private func createNewNote() {
        let newNote = Note(title: "", content: "", primaryCategory: selectedCategory ?? .personal)
        Task {
            await appState.addNote(newNote)
            withAnimation(.easeInOut(duration: 0.15)) {
                showTrash = false
                selectedNoteId = newNote.id
            }
        }
    }

    // MARK: - Sidebar

    private var noteSidebar: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Text(showTrash ? "Trash" : "Notes")
                        .font(.system(size: 16, weight: .regular, design: .serif))
                        .foregroundStyle(Theme.Colors.text)

                    OttoCountChip(text: countLabel)

                    Spacer()

                    if !showTrash {
                        OttoGlyphButton(
                            systemImage: isSelectMode ? "xmark.circle.fill" : "checkmark.circle",
                            help: isSelectMode ? "Cancel selection" : "Select notes",
                            isActive: isSelectMode,
                            size: 24
                        ) {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                isSelectMode.toggle()
                                if !isSelectMode {
                                    selectedNoteIds.removeAll()
                                }
                            }
                        }

                        if !isSelectMode {
                            OttoGlyphButton(systemImage: "square.and.pencil", help: "New note (⌘N)", size: 24) {
                                createNewNote()
                            }
                            .keyboardShortcut("n", modifiers: .command)
                        }
                    }
                }

                if isSelectMode && !showTrash {
                    selectionBar
                }

                if !showTrash {
                    // Search
                    OttoSearchMini(placeholder: "Search", text: $searchText, width: nil)

                    // Category filter
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            sidebarCategoryChip(nil, label: "All")
                            ForEach(PrimaryCategory.allCases) { category in
                                sidebarCategoryChip(category, label: category.rawValue)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            OttoDivider()

            if showTrash {
                trashList
            } else {
                notesList
            }

            OttoDivider()

            trashFooter
        }
        .background(Theme.Colors.panelWash)
    }

    private var countLabel: String {
        if showTrash { return "\(appState.trashedNotes.count)" }
        let filtered = filteredNotes.count
        let total = activeNotes.count
        return filtered == total ? "\(total)" : "\(filtered)/\(total)"
    }

    private var selectionBar: some View {
        HStack(spacing: 8) {
            Button {
                if selectedNoteIds.count == filteredNotes.count {
                    selectedNoteIds.removeAll()
                } else {
                    selectedNoteIds = Set(filteredNotes.map(\.id))
                }
            } label: {
                Text(selectedNoteIds.count == filteredNotes.count ? "Deselect All" : "Select All")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Colors.accentText)
            }
            .buttonStyle(.plain)

            Spacer()

            if !selectedNoteIds.isEmpty {
                Text("\(selectedNoteIds.count) selected")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Colors.secondaryText)

                Button {
                    showDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.red)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Move selected notes to Trash")
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Notes list

    private var notesList: some View {
        Group {
            if filteredNotes.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 24, weight: .thin))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                    Text(searchText.isEmpty ? "No notes" : "No results")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                    if searchText.isEmpty {
                        Button {
                            createNewNote()
                        } label: {
                            Text("New note")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.Colors.accentText)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1, pinnedViews: []) {
                        ForEach(groupedNotes, id: \.title) { group in
                            HStack {
                                Text(group.title.uppercased())
                                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                    .tracking(Theme.Tracking.xxwide)
                                    .foregroundStyle(Theme.Colors.tertiaryText)
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.top, 14)
                            .padding(.bottom, 5)

                            ForEach(group.notes) { note in
                                sidebarNoteRow(note)
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
                .focusable()
                .focusEffectDisabled()
                .onKeyPress(phases: .down) { press in
                    handleListKey(press)
                }
            }
        }
    }

    private func handleListKey(_ press: KeyPress) -> KeyPress.Result {
        let flat = groupedNotes.flatMap(\.notes)
        guard !flat.isEmpty else { return .ignored }
        switch press.key {
        case .upArrow, .downArrow:
            let delta = press.key == .downArrow ? 1 : -1
            if let current = selectedNoteId, let idx = flat.firstIndex(where: { $0.id == current }) {
                let next = min(max(0, idx + delta), flat.count - 1)
                selectedNoteId = flat[next].id
            } else {
                selectedNoteId = flat.first?.id
            }
            return .handled
        default:
            return .ignored
        }
    }

    // MARK: - Trash list

    private var trashList: some View {
        Group {
            let trashed = appState.trashedNotes
            if trashed.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "trash")
                        .font(.system(size: 24, weight: .thin))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                    Text("Trash is empty")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(trashed) { note in
                            trashRow(note)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func trashRow(_ note: Note) -> some View {
        HStack(spacing: 8) {
            Group {
                if let icon = note.icon {
                    Text(icon).font(.system(size: 14))
                } else {
                    Image(systemName: "doc.text")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
            }
            .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(note.title.isEmpty ? "Untitled" : note.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.Colors.textDim)
                    .lineLimit(1)
                if let deletedAt = note.deletedAt {
                    Text("Deleted \(relativeAge(deletedAt))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
            }

            Spacer()

            Button {
                Task {
                    await appState.restoreNotes([note.id])
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showTrash = false
                        selectedNoteId = note.id
                    }
                }
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Restore")

            Button {
                Task { await appState.permanentlyDeleteNote(note) }
            } label: {
                Image(systemName: "xmark.bin")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Colors.red)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Delete forever")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func relativeAge(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 3600 { return "\(max(1, Int(interval / 60)))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }

    private var trashFooter: some View {
        HStack {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showTrash.toggle()
                    if showTrash {
                        isSelectMode = false
                        selectedNoteIds.removeAll()
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showTrash ? "chevron.left" : "trash")
                        .font(.system(size: 10, weight: .medium))
                    Text(showTrash ? "Back to notes" : "Trash")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .tracking(0.5)
                    if !showTrash && !appState.trashedNotes.isEmpty {
                        Text("\(appState.trashedNotes.count)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }
                }
                .foregroundStyle(Theme.Colors.textDim)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            if showTrash && !appState.trashedNotes.isEmpty {
                Button {
                    Task { await appState.emptyNoteTrash() }
                } label: {
                    Text("Empty Trash")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .tracking(0.5)
                        .foregroundStyle(Theme.Colors.red)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Sidebar note row

    private func sidebarNoteRow(_ note: Note) -> some View {
        let isActive = selectedNoteId == note.id
        let isChecked = selectedNoteIds.contains(note.id)

        return HStack(spacing: 8) {
            if isSelectMode {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isChecked ? Theme.Colors.accent : Theme.Colors.tertiaryText)
            } else {
                Group {
                    if let icon = note.icon {
                        Text(icon).font(.system(size: 14))
                    } else {
                        Image(systemName: "doc.text")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }
                }
                .frame(width: 18)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(note.title.isEmpty ? "Untitled" : note.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(
                            (isActive && !isSelectMode) || (isChecked && isSelectMode)
                                ? Theme.Colors.text
                                : Theme.Colors.textDim
                        )
                        .lineLimit(1)

                    if note.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }
                    if note.notionPageId != nil {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 8))
                            .foregroundStyle(Theme.Colors.tertiaryText)
                            .help("Synced from Notion")
                    }
                }

                if !note.content.isEmpty {
                    Text(NoteDocument.preview(note.content))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(
                    (isChecked && isSelectMode) || (isActive && !isSelectMode)
                        ? Theme.Colors.selectTint
                        : (hoveredNoteId == note.id ? Theme.Colors.panel : Color.clear)
                )
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                hoveredNoteId = note.id
            } else if hoveredNoteId == note.id {
                hoveredNoteId = nil
            }
        }
        .onTapGesture {
            handleNoteClick(note, shift: NSEvent.modifierFlags.contains(.shift),
                            command: NSEvent.modifierFlags.contains(.command))
        }
        .contextMenu {
            Button {
                handleNoteClick(note, shift: false, command: false)
            } label: {
                Label("Open", systemImage: "arrow.up.right.square")
            }

            Button {
                Task { await appState.setNotePinned(note.id, pinned: !note.isPinned) }
            } label: {
                Label(note.isPinned ? "Unpin" : "Pin", systemImage: note.isPinned ? "pin.slash" : "pin")
            }

            Button {
                Task {
                    let copy = await appState.duplicateNote(note)
                    selectedNoteId = copy.id
                }
            } label: {
                Label("Duplicate", systemImage: "doc.on.doc")
            }

            Button {
                let linkTitle = note.title.isEmpty ? "Untitled" : note.title
                let link = "[\(linkTitle)](otto://note/\(note.id.uuidString))"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link, forType: .string)
            } label: {
                Label("Copy Link", systemImage: "link")
            }

            Menu("Convert to…") {
                Button("To-Do") { Task { await appState.convertNote(note, to: .todo) } }
                Button("Idea") { Task { await appState.convertNote(note, to: .idea) } }
                Button("Reminder (keeps note)") { Task { await appState.convertNote(note, to: .reminder) } }
            }

            Divider()

            Button(role: .destructive) {
                if selectedNoteId == note.id { selectedNoteId = nil }
                selectedNoteIds.remove(note.id)
                Task { await appState.deleteNote(note) }
            } label: {
                Label("Move to Trash", systemImage: "trash")
            }
        }
    }

    // MARK: - Click handling

    private func handleNoteClick(_ note: Note, shift: Bool, command: Bool) {
        if shift {
            withAnimation(.easeInOut(duration: 0.1)) {
                if !isSelectMode {
                    isSelectMode = true
                    if let anchorId = lastClickedNoteId ?? selectedNoteId {
                        selectedNoteIds = rangeOfNoteIds(from: anchorId, to: note.id)
                    } else {
                        selectedNoteIds = [note.id]
                        lastClickedNoteId = note.id
                    }
                } else {
                    if let anchorId = lastClickedNoteId {
                        selectedNoteIds = rangeOfNoteIds(from: anchorId, to: note.id)
                    } else {
                        selectedNoteIds.insert(note.id)
                        lastClickedNoteId = note.id
                    }
                }
            }
            return
        }

        if command {
            withAnimation(.easeInOut(duration: 0.1)) {
                if !isSelectMode {
                    isSelectMode = true
                    selectedNoteIds = [note.id]
                } else {
                    if selectedNoteIds.contains(note.id) {
                        selectedNoteIds.remove(note.id)
                        if selectedNoteIds.isEmpty {
                            isSelectMode = false
                        }
                    } else {
                        selectedNoteIds.insert(note.id)
                    }
                }
                lastClickedNoteId = note.id
            }
            return
        }

        if isSelectMode {
            withAnimation(.easeInOut(duration: 0.1)) {
                if selectedNoteIds.contains(note.id) {
                    selectedNoteIds.remove(note.id)
                } else {
                    selectedNoteIds.insert(note.id)
                }
                lastClickedNoteId = note.id
            }
        } else {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedNoteId = note.id
                lastClickedNoteId = note.id
            }
        }
    }

    private func rangeOfNoteIds(from startId: UUID, to endId: UUID) -> Set<UUID> {
        let notes = groupedNotes.flatMap(\.notes)
        guard let startIndex = notes.firstIndex(where: { $0.id == startId }),
              let endIndex = notes.firstIndex(where: { $0.id == endId }) else {
            return [startId, endId]
        }
        let range = min(startIndex, endIndex)...max(startIndex, endIndex)
        return Set(notes[range].map(\.id))
    }

    // MARK: - Category chip

    private func sidebarCategoryChip(_ category: PrimaryCategory?, label: String) -> some View {
        let isSelected = selectedCategory == category

        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedCategory = category
            }
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? Theme.Colors.text : Theme.Colors.tertiaryText)
                .padding(.horizontal, 11)
                .frame(height: 24)
                .background(
                    Capsule().fill(isSelected ? Theme.Colors.panel2 : Color.clear)
                )
                .overlay(
                    Capsule().strokeBorder(isSelected ? Theme.Colors.border : Color.clear, lineWidth: 1)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty editor

    private var emptyEditor: some View {
        OttoEmptyState(
            systemImage: "doc.text",
            title: "Select a note",
            message: "Or create a new one — ⌘N."
        )
    }
}

#Preview {
    NoteListView()
        .environment(AppState())
        .frame(width: 1000, height: 640)
}
