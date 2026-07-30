import SwiftUI
import UniformTypeIdentifiers

/// One block's full row: hover gutter (+ / drag handle), indentation,
/// per-kind adornment (checkbox, bullet, number, toggle chevron), and the
/// content itself. All chrome lives IN the layout flow — the old editor
/// absolutely-positioned overlays on line rects and they drifted apart on
/// every scroll or reflow.
struct BlockRowView: View {
    let controller: NoteEditorController
    let block: EditorBlock

    @State private var isHovered = false
    @State private var showActionsMenu = false
    @State private var rowHeight: CGFloat = 0

    private var isSelected: Bool { controller.selectedBlockIDs.contains(block.id) }

    private var blockIndex: Int? { controller.index(of: block.id) }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            gutter

            // Indentation
            if block.indent > 0 {
                Color.clear.frame(width: CGFloat(block.indent) * 22, height: 1)
            }

            adornment

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, padding.top)
        .padding(.bottom, padding.bottom)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(isSelected ? Theme.Colors.selectTint : Color.clear)
                .padding(.leading, 44)
        )
        .overlay(alignment: .top) { dropIndicator }
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            rowHeight = height
        }
        .onDrop(of: [.plainText], delegate: BlockRowDropDelegate(
            controller: controller, block: block, rowHeight: { rowHeight }
        ))
        .anchorPreference(key: SlashMenuAnchorKey.self, value: .bounds) { anchor in
            controller.slashMenu?.blockID == block.id ? anchor : nil
        }
    }

    // MARK: Gutter (+ and drag handle)

    private var gutter: some View {
        HStack(spacing: 0) {
            if showHandles && !controller.isReadOnly {
                Button {
                    controller.insertBlockBelowAndPrompt(block.id)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .frame(width: 20, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Add block below")

                Button {
                    showActionsMenu.toggle()
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .frame(width: 20, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Drag to move, click for actions")
                .onDrag {
                    controller.draggedBlockID = block.id
                    return NSItemProvider(object: block.id.uuidString as NSString)
                }
                .popover(isPresented: $showActionsMenu, arrowEdge: .leading) {
                    BlockActionsMenu(controller: controller, block: block, isPresented: $showActionsMenu)
                }
            } else {
                Color.clear.frame(width: 40, height: 22)
            }
        }
        .frame(width: 44, alignment: .trailing)
        .padding(.trailing, 0)
        .padding(.top, gutterTopOffset)
    }

    private var showHandles: Bool {
        isHovered || showActionsMenu
    }

    /// Nudge handles down so they line up with the first text line of big blocks.
    private var gutterTopOffset: CGFloat {
        switch block.kind {
        case .heading1: return 5
        case .heading2: return 1
        case .code, .callout, .image: return 6
        default: return 0
        }
    }

    // MARK: Per-kind vertical rhythm

    private var padding: (top: CGFloat, bottom: CGFloat) {
        switch block.kind {
        case .heading1: return (16, 3)
        case .heading2: return (11, 2)
        case .heading3: return (8, 2)
        case .divider: return (2, 2)
        case .code, .callout, .image: return (4, 4)
        case .bullet, .numbered, .todo, .toggle: return (1.5, 1.5)
        default: return (2.5, 2.5)
        }
    }

    // MARK: Adornment column

    @ViewBuilder
    private var adornment: some View {
        switch block.kind {
        case .bullet:
            Text(bulletGlyph)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.Colors.secondaryText)
                .frame(width: 22, height: lineHeight, alignment: .center)

        case .numbered:
            Text("\(controller.displayNumber(for: block)).")
                .font(.system(size: 13, weight: .regular).monospacedDigit())
                .foregroundStyle(Theme.Colors.secondaryText)
                .frame(width: 22, height: lineHeight, alignment: .center)

        case .todo(let done):
            Button {
                controller.toggleTodo(block.id)
            } label: {
                Image(systemName: done ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(done ? Theme.Colors.accent : Theme.Colors.tertiaryText)
                    .frame(width: 22, height: lineHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(controller.isReadOnly)
            .help(done ? "Mark not done" : "Mark done")

        case .toggle:
            Button {
                controller.toggleCollapse(block.id)
            } label: {
                Image(systemName: "arrowtriangle.forward.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .rotationEffect(.degrees(block.isCollapsed ? 0 : 90))
                    .frame(width: 22, height: lineHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(block.isCollapsed ? "Expand" : "Collapse")

        case .quote:
            RoundedRectangle(cornerRadius: 1)
                .fill(Theme.Colors.text.opacity(0.8))
                .frame(width: 3)
                .frame(maxHeight: .infinity)
                .padding(.trailing, 12)
                .padding(.vertical, 1)

        default:
            EmptyView()
        }
    }

    private var bulletGlyph: String {
        switch block.indent % 3 {
        case 0: return "•"
        case 1: return "◦"
        default: return "▪"
        }
    }

    private var lineHeight: CGFloat {
        NoteEditorStyle.lineHeight(for: block.kind) + 4
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch block.kind {
        case .divider:
            DividerBlockView(controller: controller, block: block)
        case .image(let source, _):
            ImageBlockView(controller: controller, block: block, source: source)
        case .code(let language):
            CodeBlockView(controller: controller, block: block, language: language, isHovered: isHovered)
        case .callout(let icon):
            CalloutBlockView(controller: controller, block: block, icon: icon)
        default:
            textView
        }
    }

    private var textView: some View {
        BlockTextView(controller: controller, block: block)
            .frame(height: max(block.measuredHeight, NoteEditorStyle.lineHeight(for: block.kind)))
            .padding(.trailing, 8)
    }

    // MARK: Drop indicator

    @ViewBuilder
    private var dropIndicator: some View {
        if let target = controller.dropTargetIndex, let idx = blockIndex, target == idx {
            RoundedRectangle(cornerRadius: 1)
                .fill(Theme.Colors.accent)
                .frame(height: 2)
                .padding(.leading, 44)
        }
    }
}

// MARK: - Slash menu anchor preference

struct SlashMenuAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

// MARK: - Drop delegate (block reordering)

struct BlockRowDropDelegate: DropDelegate {
    let controller: NoteEditorController
    let block: EditorBlock
    let rowHeight: () -> CGFloat

    func validateDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated { controller.draggedBlockID != nil }
    }

    func dropEntered(info: DropInfo) {
        updateTarget(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateTarget(info)
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            guard let target = controller.dropTargetIndex else { return false }
            controller.moveDraggedBlock(to: target)
            return true
        }
    }

    func dropExited(info: DropInfo) {
        MainActor.assumeIsolated {
            guard let idx = controller.index(of: block.id) else { return }
            let mine = [idx, controller.descendantRange(of: idx).upperBound]
            if let target = controller.dropTargetIndex, mine.contains(target) {
                controller.dropTargetIndex = nil
            }
        }
    }

    private func updateTarget(_ info: DropInfo) {
        MainActor.assumeIsolated {
            guard controller.draggedBlockID != nil,
                  let idx = controller.index(of: block.id) else { return }
            let height = max(rowHeight(), 1)
            if info.location.y < height / 2 {
                controller.dropTargetIndex = idx
            } else {
                // Below this block — after it AND its nested children.
                controller.dropTargetIndex = controller.descendantRange(of: idx).upperBound
            }
        }
    }
}

// MARK: - Block actions popover (drag-handle click)

struct BlockActionsMenu: View {
    let controller: NoteEditorController
    let block: EditorBlock
    @Binding var isPresented: Bool

    @State private var hovered: String?
    @State private var showTurnInto = false

    private static let turnIntoTargets: [(String, String, NoteBlockKind)] = [
        ("Text", "text.alignleft", .paragraph),
        ("Heading 1", "textformat.size.larger", .heading1),
        ("Heading 2", "textformat.size", .heading2),
        ("Heading 3", "textformat.size.smaller", .heading3),
        ("Bulleted list", "list.bullet", .bullet),
        ("Numbered list", "list.number", .numbered),
        ("To-do list", "checkmark.square", .todo(done: false)),
        ("Toggle list", "arrowtriangle.right.fill", .toggle),
        ("Quote", "text.quote", .quote),
        ("Callout", "lightbulb", .callout(icon: "💡")),
        ("Code", "chevron.left.forwardslash.chevron.right", .code(language: ""))
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if block.kind.isTextual {
                row(icon: "arrow.triangle.swap", label: "Turn into", key: "turninto", chevron: true) {
                    showTurnInto.toggle()
                }
                .popover(isPresented: $showTurnInto, arrowEdge: .trailing) {
                    turnIntoSubmenu
                }
            }

            row(icon: "doc.on.doc", label: "Duplicate", key: "dup", shortcut: "⌘D") {
                isPresented = false
                controller.duplicateBlock(block.id)
            }

            row(icon: "doc.on.clipboard", label: "Copy as Markdown", key: "copymd") {
                isPresented = false
                let range = markdownRange()
                let markdown = NoteDocument.serialize(range)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(markdown, forType: .string)
            }

            OttoDivider()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

            Button {
                isPresented = false
                controller.deleteBlockAndChildren(block.id)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .frame(width: 20)
                    Text("Delete")
                        .font(.system(size: 13))
                    Spacer()
                    Text("Del")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
                .foregroundStyle(Theme.Colors.red)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .fill(hovered == "delete" ? Theme.Colors.red.opacity(0.08) : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 ? "delete" : nil }
        }
        .padding(.vertical, 6)
        .frame(width: 230)
        .background(Theme.Colors.background)
    }

    private func markdownRange() -> [EditorBlock] {
        guard let idx = controller.index(of: block.id) else { return [block] }
        let range = idx..<controller.descendantRange(of: idx).upperBound
        return Array(controller.blocks[range])
    }

    private var turnIntoSubmenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Turn into")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.Colors.tertiaryText)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)

            ForEach(Self.turnIntoTargets, id: \.0) { title, icon, kind in
                if !block.kind.isSameFamily(as: kind) {
                    Button {
                        isPresented = false
                        controller.convertBlock(block.id, to: kind)
                        controller.requestFocus(block.id, placement: .end)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: icon)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.Colors.secondaryText)
                                .frame(width: 20)
                            Text(title)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.Colors.text)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 4)
        .frame(width: 190)
        .background(Theme.Colors.background)
    }

    private func row(icon: String, label: String, key: String, shortcut: String? = nil,
                     chevron: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .frame(width: 20)
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Colors.text)
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                } else if chevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(hovered == key ? Theme.Colors.borderSubtle : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? key : nil }
    }
}

// MARK: - Divider block

struct DividerBlockView: View {
    let controller: NoteEditorController
    let block: EditorBlock

    var body: some View {
        Rectangle()
            .fill(Theme.Colors.border)
            .frame(height: 1)
            .padding(.vertical, 9)
            .padding(.trailing, 8)
            .contentShape(Rectangle())
            .onTapGesture {
                controller.selectBlocks([block.id], anchor: block.id)
            }
    }
}

// MARK: - Callout block

struct CalloutBlockView: View {
    let controller: NoteEditorController
    let block: EditorBlock
    let icon: String

    @State private var showIconPicker = false

    private static let presetIcons = [
        "💡", "📌", "⚠️", "🔥", "✅", "❗️", "❓", "📝", "🎯", "🚀",
        "💭", "📣", "🧠", "⭐️", "🛑", "👀", "🗓️", "🔗", "🧪", "🏁"
    ]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                showIconPicker.toggle()
            } label: {
                Text(icon)
                    .font(.system(size: 15))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(controller.isReadOnly)
            .popover(isPresented: $showIconPicker, arrowEdge: .bottom) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(30)), count: 5), spacing: 4) {
                    ForEach(Self.presetIcons, id: \.self) { preset in
                        Button {
                            showIconPicker = false
                            controller.convertBlock(block.id, to: .callout(icon: preset))
                        } label: {
                            Text(preset)
                                .font(.system(size: 16))
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
            }

            BlockTextView(controller: controller, block: block)
                .frame(height: max(block.measuredHeight, NoteEditorStyle.lineHeight(for: block.kind)))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Colors.hoverTint)
        )
        .padding(.trailing, 8)
    }
}

// MARK: - Code block

struct CodeBlockView: View {
    let controller: NoteEditorController
    let block: EditorBlock
    let language: String
    let isHovered: Bool

    @State private var copied = false

    private static let languages = [
        "plain", "swift", "python", "javascript", "typescript", "bash", "json",
        "html", "css", "sql", "go", "rust", "c", "cpp", "java", "kotlin",
        "ruby", "php", "yaml", "markdown"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Menu {
                    ForEach(Self.languages, id: \.self) { lang in
                        Button(lang) {
                            controller.setCodeLanguage(block.id, language: lang == "plain" ? "" : lang)
                        }
                    }
                } label: {
                    Text(language.isEmpty ? "plain text" : language)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(isHovered ? .visible : .hidden)
                .fixedSize()
                .disabled(controller.isReadOnly)

                Spacer()

                if isHovered {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(block.plainText, forType: .string)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            copied = false
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10))
                            Text(copied ? "Copied" : "Copy")
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            BlockTextView(controller: controller, block: block)
                .frame(height: max(block.measuredHeight, NoteEditorStyle.lineHeight(for: block.kind)))
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Colors.bg1)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .strokeBorder(Theme.Colors.borderSubtle, lineWidth: 1)
                )
        )
        .padding(.trailing, 8)
    }
}

// MARK: - Image block

struct ImageBlockView: View {
    let controller: NoteEditorController
    let block: EditorBlock
    let source: String

    @State private var isHovered = false

    private var isSelected: Bool { controller.selectedBlockIDs.contains(block.id) }

    var body: some View {
        Group {
            if let url = NoteAssetStore.url(for: source), let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 560, maxHeight: 460, alignment: .leading)
            } else if source.hasPrefix("http"), let url = URL(string: source) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fit)
                    case .failure:
                        missingPlaceholder
                    default:
                        ProgressView().controlSize(.small).frame(height: 80)
                    }
                }
                .frame(maxWidth: 560, maxHeight: 460, alignment: .leading)
            } else {
                missingPlaceholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .strokeBorder(isSelected ? Theme.Colors.accent : Theme.Colors.borderSubtle,
                              lineWidth: isSelected ? 2 : 1)
        )
        .overlay(alignment: .topTrailing) {
            if isHovered && !controller.isReadOnly {
                Button {
                    controller.deleteBlockAndChildren(block.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                }
                .buttonStyle(.plain)
                .padding(6)
            }
        }
        .onHover { isHovered = $0 }
        .onTapGesture {
            controller.selectBlocks([block.id], anchor: block.id)
        }
    }

    private var missingPlaceholder: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 16))
            Text("Image not found")
                .font(.system(size: 12))
        }
        .foregroundStyle(Theme.Colors.tertiaryText)
        .frame(maxWidth: .infinity, minHeight: 72)
        .background(Theme.Colors.hoverTint)
    }
}
