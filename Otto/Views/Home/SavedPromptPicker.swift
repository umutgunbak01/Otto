import SwiftUI

/// Compact popover behind the composer's bookmark button: insert a saved
/// prompt into the input field, save the current input as a new prompt, or
/// jump to the Automations tab to manage the library.
struct SavedPromptPicker: View {
    @Environment(AppState.self) private var appState

    let hasCurrentInput: Bool
    let onInsert: (SavedPrompt) -> Void
    let onSaveCurrent: () -> Void
    let onManage: () -> Void

    @State private var query = ""

    private var results: [SavedPrompt] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = appState.savedPrompts
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.name.lowercased().contains(q) || $0.prompt.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if appState.savedPrompts.count > 5 {
                TextField("Search prompts…", text: $query)
                    .textFieldStyle(.plain)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.text)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.sm)
                OttoDivider()
            }

            if appState.savedPrompts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No saved prompts yet")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.text)
                    Text("Type something in the composer and save it here, or create prompts in the Automations tab.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Theme.Spacing.md)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(results) { prompt in
                            PromptRow(prompt: prompt) { onInsert(prompt) }
                        }
                        if results.isEmpty {
                            Text("No matches")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.textDim)
                                .padding(Theme.Spacing.md)
                        }
                    }
                }
                .frame(maxHeight: 240)
            }

            OttoDivider()

            VStack(alignment: .leading, spacing: 2) {
                if hasCurrentInput {
                    footerButton(icon: "bookmark.fill", label: "Save current input as prompt…", action: onSaveCurrent)
                }
                footerButton(icon: "calendar.badge.clock", label: "Manage in Automations", action: onManage)
            }
            .padding(.vertical, Theme.Spacing.xs)
        }
        .frame(width: 320)
        .background(Theme.Colors.bg1)
    }

    private func footerButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Colors.amber)
                    .frame(width: 16)
                Text(label)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.text)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private struct PromptRow: View {
        let prompt: SavedPrompt
        let action: () -> Void

        @State private var hovered = false

        var body: some View {
            Button(action: action) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(prompt.name)
                        .font(Theme.Typography.body.weight(.medium))
                        .foregroundStyle(Theme.Colors.text)
                        .lineLimit(1)
                    Text(prompt.prompt)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textDim)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.sm)
                .background(hovered ? Theme.Colors.selectTint.opacity(0.5) : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
        }
    }
}
