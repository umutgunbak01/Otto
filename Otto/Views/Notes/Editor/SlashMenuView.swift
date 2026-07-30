import SwiftUI

// MARK: - Slash menu items

struct SlashMenuItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let keywords: [String]
    let shortcutHint: String
    private let action: @MainActor (NoteEditorController) -> Void

    @MainActor
    func apply(_ controller: NoteEditorController) { action(controller) }

    static let all: [SlashMenuItem] = [
        SlashMenuItem(id: "text", title: "Text", subtitle: "Plain paragraph",
                      icon: "text.alignleft", keywords: ["text", "paragraph", "plain"], shortcutHint: "",
                      action: { $0.applySlashSelection(.paragraph) }),
        SlashMenuItem(id: "h1", title: "Heading 1", subtitle: "Large section heading",
                      icon: "textformat.size.larger", keywords: ["h1", "heading", "title", "big"], shortcutHint: "#",
                      action: { $0.applySlashSelection(.heading1) }),
        SlashMenuItem(id: "h2", title: "Heading 2", subtitle: "Medium section heading",
                      icon: "textformat.size", keywords: ["h2", "heading", "subtitle"], shortcutHint: "##",
                      action: { $0.applySlashSelection(.heading2) }),
        SlashMenuItem(id: "h3", title: "Heading 3", subtitle: "Small section heading",
                      icon: "textformat.size.smaller", keywords: ["h3", "heading", "small"], shortcutHint: "###",
                      action: { $0.applySlashSelection(.heading3) }),
        SlashMenuItem(id: "bullet", title: "Bulleted list", subtitle: "Simple bullet point",
                      icon: "list.bullet", keywords: ["bullet", "list", "unordered", "ul"], shortcutHint: "-",
                      action: { $0.applySlashSelection(.bullet) }),
        SlashMenuItem(id: "numbered", title: "Numbered list", subtitle: "List with numbering",
                      icon: "list.number", keywords: ["numbered", "ordered", "list", "ol", "1"], shortcutHint: "1.",
                      action: { $0.applySlashSelection(.numbered) }),
        SlashMenuItem(id: "todo", title: "To-do list", subtitle: "Checkbox for tasks",
                      icon: "checkmark.square", keywords: ["todo", "task", "check", "checkbox"], shortcutHint: "[]",
                      action: { $0.applySlashSelection(.todo(done: false)) }),
        SlashMenuItem(id: "toggle", title: "Toggle list", subtitle: "Collapsible content",
                      icon: "arrowtriangle.right.fill", keywords: ["toggle", "collapse", "fold", "details"], shortcutHint: "+",
                      action: { $0.applySlashSelection(.toggle) }),
        SlashMenuItem(id: "quote", title: "Quote", subtitle: "Highlighted quotation",
                      icon: "text.quote", keywords: ["quote", "blockquote", "cite"], shortcutHint: ">",
                      action: { $0.applySlashSelection(.quote) }),
        SlashMenuItem(id: "callout", title: "Callout", subtitle: "Emphasized box with an icon",
                      icon: "lightbulb", keywords: ["callout", "info", "note", "tip", "warning"], shortcutHint: "",
                      action: { $0.applySlashSelection(.callout(icon: "💡")) }),
        SlashMenuItem(id: "divider", title: "Divider", subtitle: "Visual separator",
                      icon: "minus", keywords: ["divider", "separator", "rule", "hr", "line"], shortcutHint: "---",
                      action: { $0.applySlashSelection(.divider) }),
        SlashMenuItem(id: "code", title: "Code", subtitle: "Code block with monospace font",
                      icon: "chevron.left.forwardslash.chevron.right", keywords: ["code", "snippet", "pre", "fence"], shortcutHint: "```",
                      action: { $0.applySlashSelection(.code(language: "")) }),
        SlashMenuItem(id: "image", title: "Image", subtitle: "Embed a picture from a file",
                      icon: "photo", keywords: ["image", "picture", "photo", "img", "screenshot"], shortcutHint: "",
                      action: { $0.applySlashImagePicker() })
    ]

    static func matches(for query: String) -> [SlashMenuItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return all }
        return all.filter { item in
            item.title.lowercased().contains(trimmed)
                || item.keywords.contains(where: { $0.hasPrefix(trimmed) })
        }
    }
}

// MARK: - Slash menu view

/// Keyboard-driven block picker (↑/↓/Return/Esc are routed here by the
/// focused block's text view while the menu is open).
struct SlashMenuView: View {
    let controller: NoteEditorController
    let state: SlashMenuState

    private var items: [SlashMenuItem] { SlashMenuItem.matches(for: state.query) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("BASIC BLOCKS")
                    .font(Theme.Typography.label)
                    .tracking(Theme.Tracking.xwide)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                Spacer()
                if !state.query.isEmpty {
                    Text(state.query)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if items.isEmpty {
                Text("No results")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                row(item, isSelected: index == state.selectionIndex)
                                    .id(item.id)
                                    .onTapGesture { item.apply(controller) }
                                    .onHover { hovering in
                                        if hovering { controller.slashMenu?.selectionIndex = index }
                                    }
                            }
                        }
                        .padding(4)
                    }
                    .frame(maxHeight: 292)
                    .onChange(of: state.selectionIndex) { _, index in
                        if items.indices.contains(index) {
                            proxy.scrollTo(items[index].id, anchor: nil)
                        }
                    }
                }
            }
        }
        .frame(width: 300)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.Colors.background)
                .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Theme.Colors.border.opacity(0.4), lineWidth: 0.5)
        )
    }

    private func row(_ item: SlashMenuItem, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .font(.system(size: 13))
                .foregroundStyle(Theme.Colors.secondaryText)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .fill(Theme.Colors.borderSubtle.opacity(0.5))
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.Colors.text)
                Text(item.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }

            Spacer()

            if !item.shortcutHint.isEmpty {
                Text(item.shortcutHint)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(isSelected ? Theme.Colors.hoverTint : Color.clear)
        )
        .contentShape(Rectangle())
    }
}
