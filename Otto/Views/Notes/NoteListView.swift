import SwiftUI

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

    var filteredNotes: [Note] {
        var notes = appState.notes

        if let category = selectedCategory {
            notes = notes.filter { $0.primaryCategory == category }
        }

        if !searchText.isEmpty {
            notes = notes.filter {
                $0.title.localizedCaseInsensitiveContains(searchText) ||
                $0.content.localizedCaseInsensitiveContains(searchText)
            }
        }

        return notes.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var hasSelection: Bool {
        selectedNoteId != nil && appState.notes.contains(where: { $0.id == selectedNoteId })
    }

    var body: some View {
        HStack(spacing: 0) {
            // Notion-style sidebar with note list (collapsible)
            if !isSidebarCollapsed {
                noteSidebar
                    .frame(width: 260)
                    .transition(.move(edge: .leading).combined(with: .opacity))

                Rectangle()
                    .fill(Theme.Colors.cyan.opacity(0.18))
                    .frame(width: 1)
            }

            // Full-page editor (Notion-style)
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
                    }
                )
                .frame(maxWidth: .infinity)
                .transition(.opacity)
                .id(noteId)
            } else {
                // Empty state when no note selected
                emptyEditor
                    .frame(maxWidth: .infinity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isSidebarCollapsed)
        .animation(.easeInOut(duration: 0.15), value: selectedNoteId)
        .onChange(of: appState.locateItemId) { oldValue, newValue in
            if let itemId = newValue,
               appState.notes.contains(where: { $0.id == itemId }) {
                selectedNoteId = itemId
                appState.locateItemId = nil
            }
        }
        .onAppear {
            if let itemId = appState.locateItemId,
               appState.notes.contains(where: { $0.id == itemId }) {
                selectedNoteId = itemId
                appState.locateItemId = nil
            }
            // Auto-select first note if none selected
            if selectedNoteId == nil, let first = filteredNotes.first {
                selectedNoteId = first.id
            }
        }
        .alert("Delete \(selectedNoteIds.count) note\(selectedNoteIds.count == 1 ? "" : "s")?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                deleteSelectedNotes()
            }
        } message: {
            Text("This action can be undone.")
        }
    }

    // MARK: - Batch Delete

    private func deleteSelectedNotes() {
        let idsToDelete = selectedNoteIds
        // Clear selected note if it's being deleted
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

    // MARK: - Create New Note

    private func createNewNote() {
        let newNote = Note(title: "", content: "", primaryCategory: .personal)
        Task {
            await appState.addNote(newNote)
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedNoteId = newNote.id
            }
        }
    }

    // MARK: - Note Sidebar

    private var noteSidebar: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 10) {
                HStack {
                    Text("⌬ NOTES")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .tracking(3)
                        .foregroundStyle(Theme.Colors.cyan)
                        .shadow(color: Theme.Colors.cyanGlow, radius: 4)

                    Spacer()

                    Text("\(filteredNotes.count)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.Colors.borderSubtle)
                        .overlay(Rectangle().stroke(Theme.Colors.border, lineWidth: 1))

                    // Select mode toggle
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isSelectMode.toggle()
                            if !isSelectMode {
                                selectedNoteIds.removeAll()
                            }
                        }
                    } label: {
                        Image(systemName: isSelectMode ? "xmark.circle.fill" : "checkmark.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(isSelectMode ? Theme.Colors.accent : Theme.Colors.secondaryText)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isSelectMode ? "Cancel selection" : "Select notes")

                    // Create new note button
                    if !isSelectMode {
                        Button {
                            createNewNote()
                        } label: {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.Colors.secondaryText)
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("New note")
                    }
                }

                // Selection actions bar
                if isSelectMode {
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
                                .foregroundStyle(Theme.Colors.accent)
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
                            .help("Delete selected notes")
                        }
                    }
                    .padding(.vertical, 2)
                }

                // Search
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Theme.Colors.hoverTint)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))

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
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            OttoDivider()

            // Note list
            if filteredNotes.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 24, weight: .thin))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                    Text("No notes")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(filteredNotes) { note in
                            sidebarNoteRow(note)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
            }
        }
        .background(Theme.Colors.background.opacity(0.5))
    }

    // MARK: - Sidebar Note Row (compact, Notion-style)

    private func sidebarNoteRow(_ note: Note) -> some View {
        let isActive = selectedNoteId == note.id
        let isChecked = selectedNoteIds.contains(note.id)

        return HStack(spacing: 8) {
            if isSelectMode {
                // Selection checkbox
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isChecked ? Theme.Colors.accent : Theme.Colors.tertiaryText)
            } else {
                // Page icon
                Image(systemName: "doc.text")
                    .font(.system(size: 12))
                    .foregroundStyle(isActive ? Theme.Colors.accent : Theme.Colors.tertiaryText)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(note.title.isEmpty ? "Untitled" : note.title)
                    .font(.system(size: 13, weight: isActive && !isSelectMode ? .medium : .regular))
                    .foregroundStyle(isActive && !isSelectMode ? Theme.Colors.text : Theme.Colors.secondaryText)
                    .lineLimit(1)

                if !note.content.isEmpty {
                    Text(strippedNotePreview(note.content))
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
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(isChecked && isSelectMode ? Theme.Colors.accent.opacity(0.08) :
                      isActive && !isSelectMode ? Theme.Colors.accent.opacity(0.1) : Color.clear)
        )
        .contentShape(Rectangle())
        #if os(macOS)
        .onTapGesture {
            handleNoteClick(note, shift: NSEvent.modifierFlags.contains(.shift),
                            command: NSEvent.modifierFlags.contains(.command))
        }
        #else
        .onTapGesture {
            handleNoteClick(note, shift: false, command: false)
        }
        #endif
    }

    // MARK: - Click Handling

    private func handleNoteClick(_ note: Note, shift: Bool, command: Bool) {
        // Shift+Click: range selection
        if shift {
            withAnimation(.easeInOut(duration: 0.1)) {
                if !isSelectMode {
                    isSelectMode = true
                    // If we had an active note, use it as the anchor
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

        // Cmd+Click: toggle individual selection
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

        // Normal click
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
        let notes = filteredNotes
        guard let startIndex = notes.firstIndex(where: { $0.id == startId }),
              let endIndex = notes.firstIndex(where: { $0.id == endId }) else {
            return [startId, endId]
        }
        let range = min(startIndex, endIndex)...max(startIndex, endIndex)
        return Set(notes[range].map(\.id))
    }

    // MARK: - Sidebar Category Chip

    private func sidebarCategoryChip(_ category: PrimaryCategory?, label: String) -> some View {
        let isSelected = selectedCategory == category

        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedCategory = category
            }
        } label: {
            Text(label)
                .font(.system(size: 11))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(isSelected ? Theme.Colors.accent.opacity(0.12) : Theme.Colors.hoverTint)
                .foregroundStyle(isSelected ? Theme.Colors.accent : Theme.Colors.tertiaryText)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty Editor

    private var emptyEditor: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(Theme.Colors.tertiaryText.opacity(0.5))

            Text("Select a note")
                .font(.system(size: 15))
                .foregroundStyle(Theme.Colors.tertiaryText)

            Text("Choose a note from the sidebar to start editing")
                .font(.system(size: 13))
                .foregroundStyle(Theme.Colors.tertiaryText.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    NoteListView()
        .environment(AppState())
        .frame(width: 900, height: 600)
}
