import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Block Types

enum BlockType: String, CaseIterable, Identifiable {
    case text
    case heading1
    case heading2
    case heading3
    case bulletList
    case numberedList
    case todo
    case toggle
    case quote
    case divider

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .text: return "Text"
        case .heading1: return "Heading 1"
        case .heading2: return "Heading 2"
        case .heading3: return "Heading 3"
        case .bulletList: return "Bullet List"
        case .numberedList: return "Numbered List"
        case .todo: return "To-do"
        case .toggle: return "Toggle"
        case .quote: return "Quote"
        case .divider: return "Divider"
        }
    }

    var description: String {
        switch self {
        case .text: return "Plain text paragraph"
        case .heading1: return "Large section heading"
        case .heading2: return "Medium section heading"
        case .heading3: return "Small section heading"
        case .bulletList: return "Simple bullet point"
        case .numberedList: return "Numbered list item"
        case .todo: return "Checkbox for tasks"
        case .toggle: return "Collapsible content"
        case .quote: return "Highlighted quote"
        case .divider: return "Visual separator"
        }
    }

    var iconName: String {
        switch self {
        case .text: return "text.alignleft"
        case .heading1: return "textformat.size.larger"
        case .heading2: return "textformat.size"
        case .heading3: return "textformat.size.smaller"
        case .bulletList: return "list.bullet"
        case .numberedList: return "list.number"
        case .todo: return "checkmark.square"
        case .toggle: return "arrowtriangle.right.fill"
        case .quote: return "text.quote"
        case .divider: return "minus"
        }
    }

    /// Markdown shortcut hint shown in the block picker (like Notion)
    var shortcutHint: String {
        switch self {
        case .text: return ""
        case .heading1: return "#"
        case .heading2: return "##"
        case .heading3: return "###"
        case .bulletList: return "-"
        case .numberedList: return "1."
        case .todo: return "[]"
        case .toggle: return ">"
        case .quote: return "\""
        case .divider: return "---"
        }
    }
}

// MARK: - Note Block (for gutter overlays only)

struct NoteBlock: Identifiable, Equatable {
    let id: UUID
    var type: BlockType
    var content: String
    var isCompleted: Bool
    var isExpanded: Bool
    var children: [NoteBlock]
    var lineIndex: Int  // which line in the text this block corresponds to

    init(
        id: UUID = UUID(),
        type: BlockType = .text,
        content: String = "",
        isCompleted: Bool = false,
        isExpanded: Bool = true,
        children: [NoteBlock] = [],
        lineIndex: Int = 0
    ) {
        self.id = id
        self.type = type
        self.content = content
        self.isCompleted = isCompleted
        self.isExpanded = isExpanded
        self.children = children
        self.lineIndex = lineIndex
    }

    static func == (lhs: NoteBlock, rhs: NoteBlock) -> Bool {
        lhs.id == rhs.id &&
        lhs.type == rhs.type &&
        lhs.content == rhs.content &&
        lhs.isCompleted == rhs.isCompleted &&
        lhs.isExpanded == rhs.isExpanded &&
        lhs.lineIndex == rhs.lineIndex
    }
}

// MARK: - Block Parser (line -> BlockType)

func blockTypeForLine(_ line: String) -> (type: BlockType, isCompleted: Bool) {
    if line == "---" { return (.divider, false) }
    if line.hasPrefix("### ") { return (.heading3, false) }
    if line.hasPrefix("## ") { return (.heading2, false) }
    if line.hasPrefix("# ") { return (.heading1, false) }
    if line.hasPrefix("- [x] ") { return (.todo, true) }
    if line.hasPrefix("- [ ] ") { return (.todo, false) }
    if line.hasPrefix("- ") { return (.bulletList, false) }
    if line.range(of: #"^\d+\. "#, options: .regularExpression) != nil { return (.numberedList, false) }
    if line.hasPrefix("> ") { return (.quote, false) }
    return (.text, false)
}

func parseLineBlocks(_ text: String) -> [NoteBlock] {
    let lines = text.components(separatedBy: "\n")
    if lines.isEmpty { return [NoteBlock(lineIndex: 0)] }

    return lines.enumerated().map { index, line in
        let (type, isCompleted) = blockTypeForLine(line)
        return NoteBlock(type: type, content: line, isCompleted: isCompleted, lineIndex: index)
    }
}

// MARK: - NoteBlockEditor (main view)

struct NoteBlockEditor: View {
    @Binding var content: String

    @State private var hoveredLineIndex: Int? = nil
    @State private var showBlockPicker: Bool = false
    @State private var showActionsMenu: Bool = false
    @State private var pickerLineIndex: Int = 0
    @State private var actionsLineIndex: Int = 0
    @State private var lineRects: [Int: CGRect] = [:]
    @State private var showSlashMenu: Bool = false
    @State private var slashMenuPosition: CGPoint = .zero
    @State private var slashFilterText: String = ""
    @State private var slashLineIndex: Int = 0

    #if os(iOS)
    @State private var showiOSBlockPicker: Bool = false
    @State private var showiOSBlockActions: Bool = false
    @State private var iOSCurrentLineIndex: Int = 0
    #endif

    var body: some View {
        #if os(macOS)
        macOSBody
        #else
        iOSBody
        #endif
    }

    // MARK: - iOS Body

    #if os(iOS)
    private var iOSBody: some View {
        VStack(spacing: 0) {
            RichNoteTextEditor(
                text: $content,
                hoveredLineIndex: $hoveredLineIndex,
                lineRects: $lineRects,
                showSlashMenu: $showSlashMenu,
                slashMenuPosition: $slashMenuPosition,
                slashFilterText: $slashFilterText,
                slashLineIndex: $slashLineIndex,
                onToolbarPlus: {
                    showiOSBlockPicker = true
                },
                onToolbarActions: {
                    showiOSBlockActions = true
                },
                cursorLineIndex: $iOSCurrentLineIndex
            )
            .frame(maxWidth: .infinity, minHeight: 400)
        }
        .sheet(isPresented: $showiOSBlockPicker) {
            iOSBlockPickerSheet(
                onSelect: { type in
                    showiOSBlockPicker = false
                    insertBlockFromPicker(type, afterLine: iOSCurrentLineIndex)
                }
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showiOSBlockActions) {
            iOSBlockActionsSheet(
                blockType: currentLineBlockType,
                onTurnInto: { type in
                    showiOSBlockActions = false
                    turnLineInto(lineIndex: iOSCurrentLineIndex, newType: type)
                },
                onDuplicate: {
                    showiOSBlockActions = false
                    duplicateLine(at: iOSCurrentLineIndex)
                },
                onDelete: {
                    showiOSBlockActions = false
                    deleteLine(at: iOSCurrentLineIndex)
                }
            )
            .presentationDetents([.medium])
        }
    }

    private var currentLineBlockType: BlockType {
        let lines = content.components(separatedBy: "\n")
        guard iOSCurrentLineIndex < lines.count else { return .text }
        let (type, _) = blockTypeForLine(lines[iOSCurrentLineIndex])
        return type
    }
    #endif

    // MARK: - macOS Body

    #if os(macOS)
    private var macOSBody: some View {
        ZStack(alignment: .topLeading) {
            HStack(alignment: .top, spacing: 0) {
                // Left gutter for + and ⋮⋮ handles
                blockGutter
                    .frame(width: 44)

                // Single continuous text editor
                RichNoteTextEditor(
                    text: $content,
                    hoveredLineIndex: $hoveredLineIndex,
                    lineRects: $lineRects,
                    showSlashMenu: $showSlashMenu,
                    slashMenuPosition: $slashMenuPosition,
                    slashFilterText: $slashFilterText,
                    slashLineIndex: $slashLineIndex
                )
                .frame(maxWidth: .infinity, minHeight: 400)
            }

            // Slash menu overlay
            if showSlashMenu {
                SlashCommandMenu(
                    filterText: $slashFilterText,
                    onSelect: { type in
                        applySlashCommand(type, at: slashLineIndex)
                    },
                    onDismiss: {
                        showSlashMenu = false
                        slashFilterText = ""
                    }
                )
                .offset(x: 44, y: slashMenuPosition.y)
            }
        }
    }
    #endif

    // MARK: - Block Gutter (macOS only)

    #if os(macOS)
    private var blockGutter: some View {
        GeometryReader { geo in
            let blocks = parseLineBlocks(content)

            ForEach(blocks) { block in
                if let rect = lineRects[block.lineIndex] {
                    let isHoveredLine = hoveredLineIndex == block.lineIndex
                    let isPickerLine = showBlockPicker && pickerLineIndex == block.lineIndex
                    let isActionsLine = showActionsMenu && actionsLineIndex == block.lineIndex
                    let showHandles = isHoveredLine || isPickerLine || isActionsLine

                    HStack(spacing: 0) {
                        if showHandles {
                            // "+" button
                            Button {
                                pickerLineIndex = block.lineIndex
                                showBlockPicker.toggle()
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Theme.Colors.tertiaryText)
                                    .frame(width: 20, height: 24)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .popover(isPresented: Binding(
                                get: { showBlockPicker && pickerLineIndex == block.lineIndex },
                                set: { newVal in
                                    if !newVal { showBlockPicker = false }
                                }
                            ), arrowEdge: .leading) {
                                BlockPickerPopover { type in
                                    showBlockPicker = false
                                    insertBlockFromPicker(type, afterLine: block.lineIndex)
                                }
                            }

                            // "⋮⋮" button
                            Button {
                                actionsLineIndex = block.lineIndex
                                showActionsMenu.toggle()
                            } label: {
                                Image(systemName: "ellipsis")
                                    .rotationEffect(.degrees(90))
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(Theme.Colors.tertiaryText)
                                    .frame(width: 20, height: 24)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .popover(isPresented: Binding(
                                get: { showActionsMenu && actionsLineIndex == block.lineIndex },
                                set: { newVal in
                                    if !newVal { showActionsMenu = false }
                                }
                            ), arrowEdge: .leading) {
                                BlockActionsPopover(
                                    blockType: block.type,
                                    onTurnInto: { type in
                                        showActionsMenu = false
                                        turnLineInto(lineIndex: block.lineIndex, newType: type)
                                    },
                                    onDuplicate: {
                                        showActionsMenu = false
                                        duplicateLine(at: block.lineIndex)
                                    },
                                    onDelete: {
                                        showActionsMenu = false
                                        deleteLine(at: block.lineIndex)
                                    }
                                )
                            }
                        } else {
                            Color.clear.frame(width: 40, height: 24)
                        }
                    }
                    .frame(width: 44, alignment: .trailing)
                    .position(x: 22, y: rect.midY)
                    .animation(.easeInOut(duration: 0.08), value: showHandles)
                }
            }
        }
    }
    #endif

    // MARK: - Line Manipulation

    private func insertBlockFromPicker(_ type: BlockType, afterLine lineIndex: Int) {
        var lines = content.components(separatedBy: "\n")
        let newLine: String
        switch type {
        case .text: newLine = ""
        case .heading1: newLine = "# "
        case .heading2: newLine = "## "
        case .heading3: newLine = "### "
        case .bulletList: newLine = "- "
        case .numberedList: newLine = "1. "
        case .todo: newLine = "- [ ] "
        case .toggle: newLine = "> "
        case .quote: newLine = "> "
        case .divider: newLine = "---"
        }
        let insertIdx = min(lineIndex + 1, lines.count)
        lines.insert(newLine, at: insertIdx)
        content = lines.joined(separator: "\n")
    }

    private func turnLineInto(lineIndex: Int, newType: BlockType) {
        var lines = content.components(separatedBy: "\n")
        guard lineIndex < lines.count else { return }
        let line = lines[lineIndex]

        // Strip existing prefix to get raw content
        let rawContent = stripMarkdownPrefix(line)

        // Apply new prefix
        switch newType {
        case .text: lines[lineIndex] = rawContent
        case .heading1: lines[lineIndex] = "# \(rawContent)"
        case .heading2: lines[lineIndex] = "## \(rawContent)"
        case .heading3: lines[lineIndex] = "### \(rawContent)"
        case .bulletList: lines[lineIndex] = "- \(rawContent)"
        case .numberedList: lines[lineIndex] = "1. \(rawContent)"
        case .todo: lines[lineIndex] = "- [ ] \(rawContent)"
        case .toggle: lines[lineIndex] = "> \(rawContent)"
        case .quote: lines[lineIndex] = "> \(rawContent)"
        case .divider: lines[lineIndex] = "---"
        }
        content = lines.joined(separator: "\n")
    }

    private func duplicateLine(at lineIndex: Int) {
        var lines = content.components(separatedBy: "\n")
        guard lineIndex < lines.count else { return }
        lines.insert(lines[lineIndex], at: lineIndex + 1)
        content = lines.joined(separator: "\n")
    }

    private func deleteLine(at lineIndex: Int) {
        var lines = content.components(separatedBy: "\n")
        guard lines.count > 1, lineIndex < lines.count else { return }
        lines.remove(at: lineIndex)
        content = lines.joined(separator: "\n")
    }

    private func clearSlashLine(at lineIndex: Int) {
        var lines = content.components(separatedBy: "\n")
        guard lineIndex < lines.count else { return }
        lines[lineIndex] = ""
        content = lines.joined(separator: "\n")
    }

    private func applySlashCommand(_ type: BlockType, at lineIndex: Int) {
        var lines = content.components(separatedBy: "\n")
        guard lineIndex < lines.count else { return }

        // Remove the "/" prefix content
        let prefix: String
        switch type {
        case .text: prefix = ""
        case .heading1: prefix = "# "
        case .heading2: prefix = "## "
        case .heading3: prefix = "### "
        case .bulletList: prefix = "- "
        case .numberedList: prefix = "1. "
        case .todo: prefix = "- [ ] "
        case .toggle: prefix = "> "
        case .quote: prefix = "> "
        case .divider: prefix = "---"
        }
        lines[lineIndex] = prefix
        content = lines.joined(separator: "\n")
        showSlashMenu = false
        slashFilterText = ""
    }

    private func stripMarkdownPrefix(_ line: String) -> String {
        let trimmed = line
        if trimmed == "---" { return "" }
        let prefixes = ["### ", "## ", "# ", "- [x] ", "- [ ] ", "- ", "> "]
        for prefix in prefixes {
            if trimmed.hasPrefix(prefix) {
                return String(trimmed.dropFirst(prefix.count))
            }
        }
        if let match = trimmed.range(of: #"^\d+\. "#, options: .regularExpression) {
            return String(trimmed[match.upperBound...])
        }
        return trimmed
    }
}

// MARK: - Rich Note Text Editor (NSTextView wrapper)

#if os(macOS)
struct RichNoteTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var hoveredLineIndex: Int?
    @Binding var lineRects: [Int: CGRect]
    @Binding var showSlashMenu: Bool
    @Binding var slashMenuPosition: CGPoint
    @Binding var slashFilterText: String
    @Binding var slashLineIndex: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = BlockNSTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.font = NSFont.systemFont(ofSize: 15)
        textView.insertionPointColor = NSColor(Theme.Colors.text)

        // Enable tracking for hover
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: context.coordinator,
            userInfo: nil
        )
        textView.addTrackingArea(trackingArea)

        textView.delegate = context.coordinator
        textView.hoverDelegate = context.coordinator

        scrollView.documentView = textView

        context.coordinator.textView = textView

        // Initial content
        textView.string = text
        context.coordinator.applyBlockStyling(textView)
        context.coordinator.updateLineRects(textView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? BlockNSTextView else { return }

        if !context.coordinator.isUpdating && textView.string != text {
            context.coordinator.isUpdating = true

            // External update (loading new note, AI action, etc.)
            // Use direct assignment and clear undo — this is not a user edit.
            textView.string = text
            textView.undoManager?.removeAllActions()

            context.coordinator.applyBlockStyling(textView)
            context.coordinator.updateLineRects(textView)
            context.coordinator.isUpdating = false
        }
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichNoteTextEditor
        var isUpdating = false
        weak var textView: BlockNSTextView?
        private var lastLineCount: Int = 0

        init(_ parent: RichNoteTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            guard !isUpdating else { return }

            isUpdating = true
            let newText = textView.string

            // Detect slash commands
            detectSlashCommand(in: textView, text: newText)

            // Auto-detect block type prefixes (like typing "# " converts to heading)
            // We just let the text stay as markdown — styling handles the visual

            parent.text = newText
            applyBlockStyling(textView)
            updateLineRects(textView)
            isUpdating = false
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            // Break undo coalescing on newline so each line is a separate undo step.
            // This makes ⌘Z undo line-by-line instead of reverting all text at once.
            if let replacement = replacementString {
                if replacement.contains("\n") || replacement.count > 1 {
                    textView.breakUndoCoalescing()
                }
            }

            // Handle Enter key for list continuation
            if replacementString == "\n" {
                let text = textView.string
                let cursorPos = affectedCharRange.location
                let lineRange = (text as NSString).lineRange(for: NSRange(location: cursorPos, length: 0))
                let currentLine = (text as NSString).substring(with: lineRange).trimmingCharacters(in: .newlines)

                let (blockType, _) = blockTypeForLine(currentLine)

                // If empty list/todo line, strip the prefix instead of continuing
                let stripped = stripLinePrefix(currentLine)
                if stripped.isEmpty && (blockType == .bulletList || blockType == .numberedList || blockType == .todo) {
                    // Replace the current line's prefix with empty (undo-friendly)
                    let lineWithNewline = NSRange(location: lineRange.location, length: max(lineRange.length - 1, 0))
                    textView.insertText("", replacementRange: lineWithNewline)
                    textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
                    return false
                }

                // Continue list type on new line
                if blockType == .bulletList {
                    let insertion = "\n- "
                    textView.insertText(insertion, replacementRange: affectedCharRange)
                    textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
                    return false
                }
                if blockType == .numberedList {
                    // Parse current number and increment
                    if let match = currentLine.range(of: #"^(\d+)\. "#, options: .regularExpression) {
                        let numStr = currentLine[currentLine.startIndex..<currentLine.index(before: match.upperBound)]
                        if let num = Int(numStr.trimmingCharacters(in: .punctuationCharacters)) {
                            let insertion = "\n\(num + 1). "
                            textView.insertText(insertion, replacementRange: affectedCharRange)
                            textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
                            return false
                        }
                    }
                    let insertion = "\n1. "
                    textView.insertText(insertion, replacementRange: affectedCharRange)
                    textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
                    return false
                }
                if blockType == .todo {
                    let insertion = "\n- [ ] "
                    textView.insertText(insertion, replacementRange: affectedCharRange)
                    textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
                    return false
                }
            }

            return true
        }

        private func stripLinePrefix(_ line: String) -> String {
            if line == "---" { return "" }
            let prefixes = ["### ", "## ", "# ", "- [x] ", "- [ ] ", "- ", "> "]
            for prefix in prefixes {
                if line.hasPrefix(prefix) {
                    return String(line.dropFirst(prefix.count))
                }
            }
            if let match = line.range(of: #"^\d+\. "#, options: .regularExpression) {
                return String(line[match.upperBound...])
            }
            return line
        }

        // MARK: - Slash Command Detection

        private func detectSlashCommand(in textView: NSTextView, text: String) {
            let cursorPos = textView.selectedRange().location
            guard cursorPos > 0, cursorPos <= text.count else {
                if parent.showSlashMenu { parent.showSlashMenu = false }
                return
            }

            let nsText = text as NSString
            let lineRange = nsText.lineRange(for: NSRange(location: cursorPos, length: 0))
            let currentLine = nsText.substring(with: lineRange).trimmingCharacters(in: .newlines)

            if currentLine.hasPrefix("/") {
                let lineIndex = lineIndexForCharacter(at: cursorPos, in: text)
                parent.slashLineIndex = lineIndex
                parent.slashFilterText = currentLine.count > 1 ? String(currentLine.dropFirst()) : ""

                // Calculate position for slash menu
                let glyphIndex = textView.layoutManager?.glyphIndexForCharacter(at: lineRange.location) ?? 0
                let lineRect = textView.layoutManager?.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil) ?? .zero
                parent.slashMenuPosition = CGPoint(x: 0, y: lineRect.maxY)
                parent.showSlashMenu = true
            } else {
                if parent.showSlashMenu {
                    parent.showSlashMenu = false
                    parent.slashFilterText = ""
                }
            }
        }

        private func lineIndexForCharacter(at charIndex: Int, in text: String) -> Int {
            let prefix = (text as NSString).substring(to: min(charIndex, (text as NSString).length))
            return prefix.components(separatedBy: "\n").count - 1
        }

        // MARK: - Styling

        func applyBlockStyling(_ textView: NSTextView) {
            let text = textView.string
            guard !text.isEmpty else { return }

            let fullRange = NSRange(location: 0, length: (text as NSString).length)
            let storage = textView.textStorage!

            // Disable undo registration during styling so attribute changes
            // don't pollute the undo stack (only text changes should be undoable)
            textView.undoManager?.disableUndoRegistration()
            storage.beginEditing()

            // Default style
            let defaultFont = NSFont.systemFont(ofSize: 15)
            let defaultColor = NSColor(Theme.Colors.text)
            let defaultParagraph = NSMutableParagraphStyle()
            defaultParagraph.lineSpacing = 4
            defaultParagraph.paragraphSpacing = 2

            storage.addAttributes([
                .font: defaultFont,
                .foregroundColor: defaultColor,
                .paragraphStyle: defaultParagraph
            ], range: fullRange)

            // Style each line based on its block type
            let nsText = text as NSString
            var lineStart = 0
            while lineStart < nsText.length {
                let lineRange = nsText.lineRange(for: NSRange(location: lineStart, length: 0))
                let line = nsText.substring(with: lineRange).trimmingCharacters(in: .newlines)
                let contentRange = NSRange(location: lineRange.location, length: max(lineRange.length - 1, 0))

                let (blockType, isCompleted) = blockTypeForLine(line)

                switch blockType {
                case .heading1:
                    let h1Font = NSFont.systemFont(ofSize: 28, weight: .bold)
                    let h1Para = NSMutableParagraphStyle()
                    h1Para.lineSpacing = 6
                    h1Para.paragraphSpacingBefore = 10
                    h1Para.paragraphSpacing = 4
                    storage.addAttributes([
                        .font: h1Font,
                        .paragraphStyle: h1Para
                    ], range: contentRange)

                case .heading2:
                    let h2Font = NSFont.systemFont(ofSize: 22, weight: .semibold)
                    let h2Para = NSMutableParagraphStyle()
                    h2Para.lineSpacing = 5
                    h2Para.paragraphSpacingBefore = 8
                    h2Para.paragraphSpacing = 3
                    storage.addAttributes([
                        .font: h2Font,
                        .paragraphStyle: h2Para
                    ], range: contentRange)

                case .heading3:
                    let h3Font = NSFont.systemFont(ofSize: 18, weight: .semibold)
                    let h3Para = NSMutableParagraphStyle()
                    h3Para.lineSpacing = 4
                    h3Para.paragraphSpacingBefore = 6
                    h3Para.paragraphSpacing = 2
                    storage.addAttributes([
                        .font: h3Font,
                        .paragraphStyle: h3Para
                    ], range: contentRange)

                case .bulletList:
                    let bulletPara = NSMutableParagraphStyle()
                    bulletPara.headIndent = 0
                    bulletPara.lineSpacing = 3
                    bulletPara.paragraphSpacing = 1
                    storage.addAttributes([
                        .paragraphStyle: bulletPara
                    ], range: contentRange)

                case .numberedList:
                    let numPara = NSMutableParagraphStyle()
                    numPara.headIndent = 0
                    numPara.lineSpacing = 3
                    numPara.paragraphSpacing = 1
                    storage.addAttributes([
                        .paragraphStyle: numPara
                    ], range: contentRange)

                case .todo:
                    let todoPara = NSMutableParagraphStyle()
                    todoPara.lineSpacing = 3
                    todoPara.paragraphSpacing = 1
                    if isCompleted {
                        storage.addAttributes([
                            .foregroundColor: NSColor(Theme.Colors.tertiaryText),
                            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                            .paragraphStyle: todoPara
                        ], range: contentRange)
                    } else {
                        storage.addAttributes([
                            .paragraphStyle: todoPara
                        ], range: contentRange)
                    }

                case .quote:
                    let quoteFont = NSFont.systemFont(ofSize: 15).italic() ?? NSFont.systemFont(ofSize: 15)
                    let quoteColor = NSColor(Theme.Colors.secondaryText)
                    let quotePara = NSMutableParagraphStyle()
                    quotePara.headIndent = 16
                    quotePara.firstLineHeadIndent = 16
                    quotePara.lineSpacing = 4
                    quotePara.paragraphSpacing = 2
                    storage.addAttributes([
                        .font: quoteFont,
                        .foregroundColor: quoteColor,
                        .paragraphStyle: quotePara
                    ], range: contentRange)

                case .divider:
                    let dividerColor = NSColor(Theme.Colors.tertiaryText)
                    let dividerPara = NSMutableParagraphStyle()
                    dividerPara.paragraphSpacingBefore = 8
                    dividerPara.paragraphSpacing = 8
                    storage.addAttributes([
                        .foregroundColor: dividerColor,
                        .paragraphStyle: dividerPara
                    ], range: contentRange)

                case .toggle:
                    let toggleFont = NSFont.systemFont(ofSize: 15, weight: .medium)
                    storage.addAttributes([
                        .font: toggleFont
                    ], range: contentRange)

                case .text:
                    break // default styling already applied
                }

                lineStart = NSMaxRange(lineRange)
            }

            storage.endEditing()
            textView.undoManager?.enableUndoRegistration()
        }

        // MARK: - Line Rects (for gutter positioning)

        func updateLineRects(_ textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }

            let text = textView.string
            let nsText = text as NSString
            var rects: [Int: CGRect] = [:]
            var lineIndex = 0
            var lineStart = 0

            while lineStart < nsText.length {
                let lineRange = nsText.lineRange(for: NSRange(location: lineStart, length: 0))
                let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
                let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                rects[lineIndex] = rect

                lineIndex += 1
                lineStart = NSMaxRange(lineRange)
            }

            // Handle empty last line
            if text.hasSuffix("\n") || text.isEmpty {
                let lastRect = rects[lineIndex - 1] ?? .zero
                rects[lineIndex] = CGRect(x: 0, y: lastRect.maxY, width: lastRect.width, height: lastRect.height > 0 ? lastRect.height : 20)
            }

            Task { @MainActor in
                self.parent.lineRects = rects
            }
        }
    }
}

// MARK: - Hover Delegate

protocol BlockTextViewHoverDelegate: AnyObject {
    func textViewMouseMoved(to lineIndex: Int?)
}

extension RichNoteTextEditor.Coordinator: BlockTextViewHoverDelegate {
    func textViewMouseMoved(to lineIndex: Int?) {
        Task { @MainActor in
            self.parent.hoveredLineIndex = lineIndex
        }
    }

    @objc func handleMouseMoved(_ event: NSEvent) {
        guard let textView = textView else { return }
        let point = textView.convert(event.locationInWindow, from: nil)
        let lineIndex = lineIndexAtPoint(point, in: textView)
        textViewMouseMoved(to: lineIndex)
    }

    @objc func handleMouseExited(_ event: NSEvent) {
        textViewMouseMoved(to: nil)
    }

    func lineIndexAtPoint(_ point: CGPoint, in textView: NSTextView) -> Int? {
        let text = textView.string as NSString
        guard text.length > 0 else { return 0 }

        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return nil }

        // Adjust for text container inset
        let adjustedPoint = CGPoint(
            x: point.x - textView.textContainerInset.width,
            y: point.y - textView.textContainerInset.height
        )

        let glyphIndex = layoutManager.glyphIndex(for: adjustedPoint, in: textContainer)
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)

        var lineIndex = 0
        var lineStart = 0
        while lineStart < text.length {
            let lineRange = text.lineRange(for: NSRange(location: lineStart, length: 0))
            if charIndex >= lineRange.location && charIndex < NSMaxRange(lineRange) {
                return lineIndex
            }
            lineIndex += 1
            lineStart = NSMaxRange(lineRange)
        }

        // If past last line, return last line index
        return max(0, lineIndex - 1)
    }
}

// MARK: - Custom NSTextView subclass for hover tracking

class BlockNSTextView: NSTextView {
    weak var hoverDelegate: BlockTextViewHoverDelegate?

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        if let coordinator = hoverDelegate as? RichNoteTextEditor.Coordinator {
            coordinator.handleMouseMoved(event)
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if let coordinator = hoverDelegate as? RichNoteTextEditor.Coordinator {
            coordinator.handleMouseExited(event)
        }
    }
}

// Helper extension for italic NSFont
extension NSFont {
    func italic() -> NSFont? {
        let descriptor = fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: pointSize)
    }
}

#else
// MARK: - iOS: UITextView wrapper

struct RichNoteTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var hoveredLineIndex: Int?
    @Binding var lineRects: [Int: CGRect]
    @Binding var showSlashMenu: Bool
    @Binding var slashMenuPosition: CGPoint
    @Binding var slashFilterText: String
    @Binding var slashLineIndex: Int

    // iOS toolbar callbacks
    var onToolbarPlus: (() -> Void)? = nil
    var onToolbarActions: (() -> Void)? = nil
    var cursorLineIndex: Binding<Int>? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.font = UIFont.systemFont(ofSize: 15)
        textView.textContainerInset = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.delegate = context.coordinator
        textView.text = text
        context.coordinator.textView = textView
        context.coordinator.applyBlockStyling(textView)

        // Add keyboard toolbar
        let toolbar = BlockEditorToolbar(coordinator: context.coordinator)
        textView.inputAccessoryView = toolbar

        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        if !context.coordinator.isUpdating && textView.text != text {
            context.coordinator.isUpdating = true
            let selectedRange = textView.selectedRange
            textView.text = text
            context.coordinator.applyBlockStyling(textView)
            textView.selectedRange = selectedRange
            context.coordinator.isUpdating = false
        }
    }

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: RichNoteTextEditor
        var isUpdating = false
        weak var textView: UITextView?

        init(_ parent: RichNoteTextEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isUpdating else { return }
            isUpdating = true
            parent.text = textView.text
            applyBlockStyling(textView)
            updateCursorLineIndex(textView)
            isUpdating = false
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            updateCursorLineIndex(textView)
        }

        private func updateCursorLineIndex(_ textView: UITextView) {
            let text = textView.text ?? ""
            let cursorPos = textView.selectedRange.location
            let nsText = text as NSString
            guard cursorPos <= nsText.length else { return }
            let prefix = nsText.substring(to: cursorPos)
            let lineIndex = prefix.components(separatedBy: "\n").count - 1
            parent.cursorLineIndex?.wrappedValue = lineIndex
        }

        // Toolbar actions
        @objc func toolbarPlusTapped() {
            if let tv = textView {
                updateCursorLineIndex(tv)
            }
            parent.onToolbarPlus?()
        }

        @objc func toolbarActionsTapped() {
            if let tv = textView {
                updateCursorLineIndex(tv)
            }
            parent.onToolbarActions?()
        }

        @objc func toolbarDismissKeyboard() {
            textView?.resignFirstResponder()
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            // Handle Enter key for list continuation
            if text == "\n" {
                let fullText = textView.text ?? ""
                let nsText = fullText as NSString
                let cursorPos = range.location
                let lineRange = nsText.lineRange(for: NSRange(location: cursorPos, length: 0))
                let currentLine = nsText.substring(with: lineRange).trimmingCharacters(in: .newlines)

                let (blockType, _) = blockTypeForLine(currentLine)
                let stripped = stripLinePrefix(currentLine)

                if stripped.isEmpty && (blockType == .bulletList || blockType == .numberedList || blockType == .todo) {
                    let lineWithNewline = NSRange(location: lineRange.location, length: max(lineRange.length - 1, 0))
                    let mutableText = NSMutableString(string: fullText)
                    mutableText.replaceCharacters(in: lineWithNewline, with: "")
                    textView.text = String(mutableText)
                    textView.selectedRange = NSRange(location: lineRange.location, length: 0)
                    textViewDidChange(textView)
                    return false
                }

                if blockType == .bulletList {
                    textView.insertText("\n- ")
                    textViewDidChange(textView)
                    return false
                }
                if blockType == .numberedList {
                    if let match = currentLine.range(of: #"^(\d+)\. "#, options: .regularExpression) {
                        let numStr = currentLine[currentLine.startIndex..<currentLine.index(before: match.upperBound)]
                        if let num = Int(numStr.trimmingCharacters(in: .punctuationCharacters)) {
                            textView.insertText("\n\(num + 1). ")
                            textViewDidChange(textView)
                            return false
                        }
                    }
                    textView.insertText("\n1. ")
                    textViewDidChange(textView)
                    return false
                }
                if blockType == .todo {
                    textView.insertText("\n- [ ] ")
                    textViewDidChange(textView)
                    return false
                }
            }
            return true
        }

        private func stripLinePrefix(_ line: String) -> String {
            if line == "---" { return "" }
            let prefixes = ["### ", "## ", "# ", "- [x] ", "- [ ] ", "- ", "> "]
            for prefix in prefixes {
                if line.hasPrefix(prefix) {
                    return String(line.dropFirst(prefix.count))
                }
            }
            if let match = line.range(of: #"^\d+\. "#, options: .regularExpression) {
                return String(line[match.upperBound...])
            }
            return line
        }

        func applyBlockStyling(_ textView: UITextView) {
            let text = textView.text ?? ""
            guard !text.isEmpty else { return }

            let nsText = text as NSString
            let fullRange = NSRange(location: 0, length: nsText.length)
            let storage = NSMutableAttributedString(string: text)

            let defaultFont = UIFont.systemFont(ofSize: 15)
            let defaultColor = UIColor.label
            let defaultParagraph = NSMutableParagraphStyle()
            defaultParagraph.lineSpacing = 4
            defaultParagraph.paragraphSpacing = 2

            storage.addAttributes([
                .font: defaultFont,
                .foregroundColor: defaultColor,
                .paragraphStyle: defaultParagraph
            ], range: fullRange)

            var lineStart = 0
            while lineStart < nsText.length {
                let lineRange = nsText.lineRange(for: NSRange(location: lineStart, length: 0))
                let line = nsText.substring(with: lineRange).trimmingCharacters(in: .newlines)
                let contentRange = NSRange(location: lineRange.location, length: max(lineRange.length - 1, 0))

                let (blockType, isCompleted) = blockTypeForLine(line)

                switch blockType {
                case .heading1:
                    storage.addAttributes([
                        .font: UIFont.systemFont(ofSize: 28, weight: .bold)
                    ], range: contentRange)
                case .heading2:
                    storage.addAttributes([
                        .font: UIFont.systemFont(ofSize: 22, weight: .semibold)
                    ], range: contentRange)
                case .heading3:
                    storage.addAttributes([
                        .font: UIFont.systemFont(ofSize: 18, weight: .semibold)
                    ], range: contentRange)
                case .todo:
                    if isCompleted {
                        storage.addAttributes([
                            .foregroundColor: UIColor.secondaryLabel,
                            .strikethroughStyle: NSUnderlineStyle.single.rawValue
                        ], range: contentRange)
                    }
                case .quote:
                    let italicFont = UIFont.italicSystemFont(ofSize: 15)
                    storage.addAttributes([
                        .font: italicFont,
                        .foregroundColor: UIColor.secondaryLabel
                    ], range: contentRange)
                case .divider:
                    storage.addAttributes([
                        .foregroundColor: UIColor.tertiaryLabel
                    ], range: contentRange)
                default:
                    break
                }

                lineStart = NSMaxRange(lineRange)
            }

            let selectedRange = textView.selectedRange
            textView.attributedText = storage
            textView.selectedRange = selectedRange
        }
    }
}

// MARK: - iOS Keyboard Toolbar

class BlockEditorToolbar: UIToolbar {
    init(coordinator: RichNoteTextEditor.Coordinator) {
        super.init(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 44))

        barStyle = .default
        isTranslucent = true
        sizeToFit()

        let plusButton = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            style: .plain,
            target: coordinator,
            action: #selector(RichNoteTextEditor.Coordinator.toolbarPlusTapped)
        )
        plusButton.tintColor = .label

        let actionsButton = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis")?.withConfiguration(
                UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)
            ),
            style: .plain,
            target: coordinator,
            action: #selector(RichNoteTextEditor.Coordinator.toolbarActionsTapped)
        )
        actionsButton.tintColor = .label

        let flexSpace = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)

        let dismissButton = UIBarButtonItem(
            image: UIImage(systemName: "keyboard.chevron.compact.down"),
            style: .plain,
            target: coordinator,
            action: #selector(RichNoteTextEditor.Coordinator.toolbarDismissKeyboard)
        )
        dismissButton.tintColor = .secondaryLabel

        items = [plusButton, actionsButton, flexSpace, dismissButton]
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - iOS Block Picker Sheet

struct iOSBlockPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onSelect: (BlockType) -> Void

    var body: some View {
        NavigationStack {
            List {
                // Basic blocks
                Section("Basic Blocks") {
                    ForEach(BlockType.allCases) { type in
                        Button {
                            onSelect(type)
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(type.displayName)
                                        .font(.system(size: 15))
                                        .foregroundStyle(Theme.Colors.text)
                                    Text(type.description)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.Colors.secondaryText)
                                }
                            } icon: {
                                Image(systemName: type.iconName)
                                    .foregroundStyle(Theme.Colors.secondaryText)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Add Block")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - iOS Block Actions Sheet

struct iOSBlockActionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    var blockType: BlockType
    var onTurnInto: (BlockType) -> Void
    var onDuplicate: () -> Void
    var onDelete: () -> Void

    @State private var showTurnInto = false

    var body: some View {
        NavigationStack {
            List {
                // Current block info
                Section {
                    Label {
                        Text(blockType.displayName)
                            .foregroundStyle(Theme.Colors.text)
                    } icon: {
                        Image(systemName: blockType.iconName)
                            .foregroundStyle(Theme.Colors.secondaryText)
                    }
                } header: {
                    Text("Current Block")
                }

                // Turn into
                Section("Turn Into") {
                    ForEach(BlockType.allCases) { type in
                        if type != blockType {
                            Button {
                                onTurnInto(type)
                            } label: {
                                Label {
                                    Text(type.displayName)
                                        .foregroundStyle(Theme.Colors.text)
                                } icon: {
                                    Image(systemName: type.iconName)
                                        .foregroundStyle(Theme.Colors.secondaryText)
                                }
                            }
                        }
                    }
                }

                // Actions
                Section {
                    Button {
                        onDuplicate()
                    } label: {
                        Label("Duplicate", systemImage: "doc.on.doc")
                    }

                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Block Actions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
#endif

// MARK: - Block Picker Popover (+ button)

struct BlockPickerPopover: View {
    var onSelect: (BlockType) -> Void

    @State private var filterText: String = ""
    @State private var hoveredType: BlockType?

    private var filteredTypes: [BlockType] {
        if filterText.isEmpty {
            return BlockType.allCases
        }
        let query = filterText.lowercased()
        return BlockType.allCases.filter {
            $0.displayName.lowercased().contains(query) ||
            $0.description.lowercased().contains(query) ||
            $0.shortcutHint.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Basic blocks")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Colors.secondaryText)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)

            // Block type list
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(filteredTypes) { type in
                        Button {
                            onSelect(type)
                        } label: {
                            HStack(spacing: 0) {
                                // Icon
                                Image(systemName: type.iconName)
                                    .font(.system(size: 14))
                                    .foregroundStyle(Theme.Colors.secondaryText)
                                    .frame(width: 24)

                                // Name
                                Text(type.displayName)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.Colors.text)
                                    .padding(.leading, 10)

                                Spacer()

                                // Shortcut hint
                                Text(type.shortcutHint)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(Theme.Colors.tertiaryText)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                                    .fill(hoveredType == type ? Theme.Colors.borderSubtle : Color.clear)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        #if os(macOS)
                        .onHover { hovering in
                            hoveredType = hovering ? type : nil
                        }
                        #endif
                    }
                }
            }
            .frame(maxHeight: 300)

            OttoDivider()
                .padding(.vertical, 4)

            // Filter field at bottom
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Colors.tertiaryText)
                TextField("Type to filter...", text: $filterText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
        .frame(width: 300)
        .background(Theme.Colors.background)
    }
}

// MARK: - Block Actions Popover (⋮⋮ button)

struct BlockActionsPopover: View {
    var blockType: BlockType
    var onTurnInto: (BlockType) -> Void
    var onDuplicate: () -> Void
    var onDelete: () -> Void

    @State private var searchText: String = ""
    @State private var showTurnInto: Bool = false
    @State private var hoveredAction: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Search field at top
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Colors.tertiaryText)
                TextField("Search actions...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.Colors.borderSubtle.opacity(0.5))

            OttoDivider()

            // Block type label
            HStack(spacing: 4) {
                Image(systemName: blockType.iconName)
                    .font(.system(size: 10))
                Text(blockType.displayName)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(Theme.Colors.tertiaryText)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            // Actions
            VStack(spacing: 0) {
                // Turn into
                actionButton(icon: "arrow.triangle.swap", label: "Turn into", action: "turninto") {
                    showTurnInto.toggle()
                }
                .popover(isPresented: $showTurnInto, arrowEdge: .trailing) {
                    turnIntoSubmenu
                }

                // Duplicate
                actionButton(icon: "doc.on.doc", label: "Duplicate", shortcut: "\u{2318}D", action: "duplicate") {
                    onDuplicate()
                }

                OttoDivider()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)

                // Delete
                Button {
                    onDelete()
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
                            .fill(hoveredAction == "delete" ? Theme.Colors.red.opacity(0.08) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                #if os(macOS)
                .onHover { hovering in
                    hoveredAction = hovering ? "delete" : nil
                }
                #endif
            }
            .padding(.vertical, 4)

            OttoDivider()
                .padding(.horizontal, 8)

            // Metadata footer
            VStack(alignment: .leading, spacing: 2) {
                Text("Block type: \(blockType.displayName)")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 260)
        .background(Theme.Colors.background)
    }

    private func actionButton(icon: String, label: String, shortcut: String? = nil, action: String, perform: @escaping () -> Void) -> some View {
        Button {
            perform()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .frame(width: 20)
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Colors.text)
                Spacer()
                if let shortcut = shortcut {
                    Text(shortcut)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(hoveredAction == action ? Theme.Colors.borderSubtle : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .onHover { hovering in
            hoveredAction = hovering ? action : nil
        }
        #endif
    }

    private var turnIntoSubmenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Turn into")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.Colors.tertiaryText)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)

            ForEach(BlockType.allCases) { type in
                if type != blockType {
                    Button {
                        onTurnInto(type)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: type.iconName)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.Colors.secondaryText)
                                .frame(width: 20)
                            Text(type.displayName)
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
        .frame(width: 200)
        .background(Theme.Colors.background)
    }
}

// MARK: - Slash Command Menu

struct SlashCommandMenu: View {
    @Binding var filterText: String
    var onSelect: (BlockType) -> Void
    var onDismiss: () -> Void

    @State private var hoveredType: BlockType?

    private var filteredTypes: [BlockType] {
        if filterText.isEmpty {
            return BlockType.allCases
        }
        let query = filterText.lowercased()
        return BlockType.allCases.filter {
            $0.displayName.lowercased().contains(query) ||
            $0.description.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    // Basic blocks section
                    HStack {
                        Text("BASIC BLOCKS")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.Colors.tertiaryText)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 6)

                    if filteredTypes.isEmpty {
                        Text("No results")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Colors.tertiaryText)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 12)
                    } else {
                        ForEach(filteredTypes) { type in
                            Button {
                                onSelect(type)
                            } label: {
                                HStack(spacing: 12) {
                                    // Icon container
                                    Image(systemName: type.iconName)
                                        .font(.system(size: 16))
                                        .foregroundStyle(Theme.Colors.secondaryText)
                                        .frame(width: 40, height: 40)
                                        .background(
                                            RoundedRectangle(cornerRadius: Theme.Radius.md)
                                                .fill(Theme.Colors.borderSubtle.opacity(0.5))
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                                                        .strokeBorder(Theme.Colors.border.opacity(0.3), lineWidth: 0.5)
                                                )
                                        )

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(type.displayName)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(Theme.Colors.text)

                                        Text(type.description)
                                            .font(.system(size: 11))
                                            .foregroundStyle(Theme.Colors.tertiaryText)
                                    }

                                    Spacer()
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                                        .fill(hoveredType == type ? Theme.Colors.hoverTint : Color.clear)
                                )
                            }
                            .buttonStyle(.plain)
                            #if os(macOS)
                            .onHover { hovering in
                                hoveredType = hovering ? type : nil
                            }
                            #endif
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
            .frame(maxHeight: 400)
        }
        .padding(.vertical, 4)
        .frame(width: 280)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.Colors.background)
                .shadow(color: Color.black.opacity(0.15), radius: 16, x: 0, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Theme.Colors.border.opacity(0.4), lineWidth: 0.5)
        )
    }
}

// MARK: - Stripped Preview Helper

func strippedNotePreview(_ text: String) -> String {
    let lines = text.components(separatedBy: "\n")
    let strippedLines = lines.compactMap { line -> String? in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed == "---" { return nil }
        if trimmed.isEmpty { return nil }

        var result = trimmed
        let prefixes = ["### ", "## ", "# ", "- [x] ", "- [ ] ", "- ", "> "]
        for prefix in prefixes {
            if result.hasPrefix(prefix) {
                result = String(result.dropFirst(prefix.count))
                break
            }
        }
        if let match = result.range(of: #"^\d+\. "#, options: .regularExpression) {
            result = String(result[match.upperBound...])
        }
        if result.hasPrefix("  > ") {
            result = String(result.dropFirst(4))
        }

        return result.isEmpty ? nil : result
    }

    return strippedLines.joined(separator: " ")
}

// MARK: - Preview

#Preview {
    struct PreviewWrapper: View {
        @State private var content = """
        # Meeting Notes
        ## Agenda
        - Review Q1 goals
        - Discuss hiring plan
        ### Action Items
        - [ ] Follow up with design team
        - [x] Schedule review meeting
        1. Moving to weekly sprints
        2. New design system rollout
        > This is an important quote
        ---
        Regular paragraph text here.
        """

        var body: some View {
            ScrollView {
                NoteBlockEditor(content: $content)
                    .padding(.horizontal, 64)
                    .padding(.vertical, 40)
            }
            .frame(width: 700, height: 600)
            .background(Theme.Colors.background)
        }
    }

    return PreviewWrapper()
}
