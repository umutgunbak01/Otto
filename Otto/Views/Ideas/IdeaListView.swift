import SwiftUI

struct IdeaListView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedStatus: Idea.Status?
    @State private var selectedIdeaId: UUID?
    @State private var searchText: String = ""
    @State private var isSidebarCollapsed: Bool = false

    var filteredIdeas: [Idea] {
        var ideas = appState.ideas

        if let status = selectedStatus {
            ideas = ideas.filter { $0.status == status }
        }

        if !searchText.isEmpty {
            ideas = ideas.filter {
                $0.title.localizedCaseInsensitiveContains(searchText) ||
                $0.content.localizedCaseInsensitiveContains(searchText)
            }
        }

        return ideas.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var hasSelection: Bool {
        selectedIdeaId != nil && appState.ideas.contains(where: { $0.id == selectedIdeaId })
    }

    var body: some View {
        HStack(spacing: 0) {
            // Notion-style sidebar with idea list (collapsible)
            if !isSidebarCollapsed {
                ideaSidebar
                    .frame(width: 260)
                    .transition(.move(edge: .leading).combined(with: .opacity))

                Rectangle()
                    .fill(Theme.Colors.cyan.opacity(0.18))
                    .frame(width: 1)
            }

            // Full-page editor (Notion-style)
            if let ideaId = selectedIdeaId,
               let idea = appState.ideas.first(where: { $0.id == ideaId }) {
                IdeaDetailView(
                    idea: idea,
                    isSidebarCollapsed: isSidebarCollapsed,
                    onToggleSidebar: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isSidebarCollapsed.toggle()
                        }
                    },
                    onClose: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedIdeaId = nil
                        }
                    }
                )
                .frame(maxWidth: .infinity)
                .transition(.opacity)
                .id(ideaId)
            } else {
                emptyEditor
                    .frame(maxWidth: .infinity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isSidebarCollapsed)
        .animation(.easeInOut(duration: 0.15), value: selectedIdeaId)
        .onChange(of: appState.locateItemId) { oldValue, newValue in
            if let itemId = newValue,
               appState.ideas.contains(where: { $0.id == itemId }) {
                selectedIdeaId = itemId
                appState.locateItemId = nil
            }
        }
        .onAppear {
            if let itemId = appState.locateItemId,
               appState.ideas.contains(where: { $0.id == itemId }) {
                selectedIdeaId = itemId
                appState.locateItemId = nil
            }
            // Auto-select first idea if none selected
            if selectedIdeaId == nil, let first = filteredIdeas.first {
                selectedIdeaId = first.id
            }
        }
    }

    // MARK: - Create New Idea

    private func createNewIdea() {
        let newIdea = Idea(title: "", content: "", primaryCategory: .personal, status: .raw)
        Task {
            await appState.addIdea(newIdea)
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedIdeaId = newIdea.id
            }
        }
    }

    // MARK: - Idea Sidebar

    private var ideaSidebar: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 10) {
                HStack {
                    Text("⌬ IDEAS")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .tracking(3)
                        .foregroundStyle(Theme.Colors.cyan)
                        .shadow(color: Theme.Colors.cyanGlow, radius: 4)

                    Spacer()

                    Text("\(filteredIdeas.count)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.Colors.borderSubtle)
                        .overlay(Rectangle().stroke(Theme.Colors.border, lineWidth: 1))

                    // Create new idea button
                    Button {
                        createNewIdea()
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.Colors.secondaryText)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("New idea")
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

                // Status filter
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        sidebarStatusChip(nil, label: "All")
                        ForEach(Idea.Status.allCases, id: \.self) { status in
                            sidebarStatusChip(status, label: status.rawValue)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            OttoDivider()

            // Idea list
            if filteredIdeas.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "lightbulb")
                        .font(.system(size: 24, weight: .thin))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                    Text("No ideas")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(filteredIdeas) { idea in
                            sidebarIdeaRow(idea)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
            }
        }
        .background(Theme.Colors.background.opacity(0.5))
    }

    // MARK: - Sidebar Idea Row (compact, Notion-style)

    private func sidebarIdeaRow(_ idea: Idea) -> some View {
        let isSelected = selectedIdeaId == idea.id

        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedIdeaId = idea.id
            }
        } label: {
            HStack(spacing: 8) {
                // Lightbulb icon
                Image(systemName: "lightbulb")
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Theme.Colors.accent : Theme.Colors.tertiaryText)

                VStack(alignment: .leading, spacing: 2) {
                    Text(idea.title.isEmpty ? "Untitled" : idea.title)
                        .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(isSelected ? Theme.Colors.text : Theme.Colors.secondaryText)
                        .lineLimit(1)

                    if !idea.content.isEmpty {
                        Text(strippedNotePreview(idea.content))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Colors.tertiaryText)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Status indicator dot
                Circle()
                    .fill(statusColor(idea.status))
                    .frame(width: 6, height: 6)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .fill(isSelected ? Theme.Colors.accent.opacity(0.1) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sidebar Status Chip

    private func sidebarStatusChip(_ status: Idea.Status?, label: String) -> some View {
        let isSelected = selectedStatus == status

        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedStatus = status
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
            Image(systemName: "lightbulb")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(Theme.Colors.tertiaryText.opacity(0.5))

            Text("Select an idea")
                .font(.system(size: 15))
                .foregroundStyle(Theme.Colors.tertiaryText)

            Text("Choose an idea from the sidebar to start editing")
                .font(.system(size: 13))
                .foregroundStyle(Theme.Colors.tertiaryText.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func statusColor(_ status: Idea.Status) -> Color {
        switch status {
        case .raw: return Theme.Colors.tertiaryText
        case .researched: return Theme.Colors.work
        case .validated: return Theme.Colors.personal
        case .archived: return Theme.Colors.priorityHigh
        }
    }
}

#Preview {
    IdeaListView()
        .environment(AppState())
        .frame(width: 900, height: 600)
}
