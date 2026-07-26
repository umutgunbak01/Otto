import SwiftUI

/// Settings → Agent card showing everything the agent has remembered across
/// conversations. The user can add, rewrite, recategorize, or delete entries —
/// the same list the `remember` / `update_memory` tools curate, injected into
/// every system prompt.
struct AgentMemorySettingsCard: View {
    @Environment(AppState.self) private var appState

    @State private var newContent: String = ""
    @State private var newCategory: AgentMemoryEntry.Category = .fact
    @State private var editingId: UUID?
    @State private var editingDraft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("MEMORY")
                .hudLabel()

            Text("Durable facts, preferences, and standing instructions the agent carries into every conversation. The agent adds to this list itself when you tell it something worth keeping (\"remember that…\"); everything here is editable.")
                .font(Theme.Typography.small)
                .foregroundStyle(Theme.Colors.textDim)
                .fixedSize(horizontal: false, vertical: true)

            if appState.agentMemories.isEmpty {
                Text("Nothing remembered yet.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .padding(.vertical, Theme.Spacing.xs)
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    ForEach(appState.agentMemories.sorted(by: { $0.createdAt > $1.createdAt })) { memory in
                        memoryRow(memory)
                    }
                }
            }

            OttoDivider()

            HStack(spacing: Theme.Spacing.sm) {
                TextField("Add a memory (e.g. \"Keep follow-up drafts under 5 sentences\")", text: $newContent)
                    .textFieldStyle(.plain)
                    .font(Theme.Typography.body)
                    .onSubmit(addMemory)
                Picker("", selection: $newCategory) {
                    ForEach(AgentMemoryEntry.Category.allCases, id: \.self) { cat in
                        Text(cat.displayName).tag(cat)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Button("Add", action: addMemory)
                    .disabled(newContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.panel)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xl))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.xl)
                .strokeBorder(Theme.Colors.border, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func memoryRow(_ memory: AgentMemoryEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
            Text(memory.category.displayName.uppercased())
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.tertiaryText)
                .frame(width: 86, alignment: .leading)

            if editingId == memory.id {
                TextField("", text: $editingDraft)
                    .textFieldStyle(.plain)
                    .font(Theme.Typography.body)
                    .onSubmit { commitEdit(memory) }
                Button("Save") { commitEdit(memory) }
                    .font(Theme.Typography.small)
            } else {
                Text(memory.content)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    editingId = memory.id
                    editingDraft = memory.content
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Colors.textDim)
                }
                .buttonStyle(.plain)
                Button {
                    Task { await appState.deleteAgentMemory(id: memory.id) }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Colors.textDim)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 3)
    }

    private func addMemory() {
        let content = newContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        let entry = AgentMemoryEntry(content: content, category: newCategory)
        newContent = ""
        Task { await appState.addAgentMemory(entry) }
    }

    private func commitEdit(_ memory: AgentMemoryEntry) {
        let content = editingDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        editingId = nil
        guard !content.isEmpty, content != memory.content else { return }
        var updated = memory
        updated.content = content
        Task { await appState.updateAgentMemory(updated) }
    }
}

/// Settings → Agent card for agent-safety options.
struct AgentSafetySettingsCard: View {
    @AppStorage(OttoMCPServer.confirmDestructiveDefaultsKey)
    private var confirmDestructive = true

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("SAFETY")
                .hudLabel()

            Toggle(isOn: $confirmDestructive) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Confirm deletions")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.text)
                    Text("Ask before the agent deletes an item on the Claude / Codex backends (Hermes already has its own approval cards).")
                        .font(Theme.Typography.small)
                        .foregroundStyle(Theme.Colors.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.panel)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xl))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.xl)
                .strokeBorder(Theme.Colors.border, lineWidth: 1)
        )
    }
}
