import SwiftUI
import AppKit

/// One block's editable text: a self-sizing, non-scrolling NSTextView bound
/// directly to the block's NSTextStorage (TextKit 1, explicitly — temporary
/// attributes and the measurement path depend on NSLayoutManager).
///
/// Block-boundary keys (Return, Backspace-at-start, Tab, arrows at edges)
/// call into the shared NoteEditorController; everything else is native
/// AppKit editing against the shared document UndoManager.
struct BlockTextView: NSViewRepresentable {
    let controller: NoteEditorController
    let block: EditorBlock

    func makeCoordinator() -> BlockTextCoordinator {
        BlockTextCoordinator(controller: controller, block: block)
    }

    func makeNSView(context: Context) -> BlockInlineTextView {
        let coordinator = context.coordinator

        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0

        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(container)
        block.storage.addLayoutManager(layoutManager)
        coordinator.layoutManager = layoutManager

        let textView = BlockInlineTextView(frame: .zero, textContainer: container)
        textView.coordinator = coordinator
        coordinator.textView = textView

        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width, .height]
        textView.textContainerInset = .zero
        textView.insertionPointColor = NSColor(Theme.Colors.text)
        textView.linkTextAttributes = [
            .foregroundColor: NSColor(Theme.Colors.accentText),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand
        ]

        // Markdown-backed storage: smart substitutions would corrupt syntax.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false

        textView.typingAttributes = NoteEditorStyle.baseAttributes(for: block.kind)
        textView.delegate = coordinator
        block.storage.delegate = coordinator

        coordinator.applyReadOnly()
        coordinator.applyTodoAppearance()
        coordinator.scheduleMeasure()
        return textView
    }

    func updateNSView(_ textView: BlockInlineTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.applyReadOnly()

        if coordinator.lastAppliedKind != block.kind {
            coordinator.lastAppliedKind = block.kind
            textView.typingAttributes = NoteEditorStyle.baseAttributes(for: block.kind)
            coordinator.applyTodoAppearance()
            coordinator.scheduleMeasure()
        }

        // Consume a pending focus request for this block.
        if let request = controller.focusRequest, request.blockID == block.id {
            coordinator.consumeFocusRequest(request)
        }
    }

    static func dismantleNSView(_ textView: BlockInlineTextView, coordinator: BlockTextCoordinator) {
        coordinator.tearDown()
    }
}

// MARK: - Coordinator

@MainActor
final class BlockTextCoordinator: NSObject {
    let controller: NoteEditorController
    let block: EditorBlock
    weak var textView: BlockInlineTextView?
    weak var layoutManager: NSLayoutManager?
    var lastAppliedKind: NoteBlockKind
    private var lastMeasuredWidth: CGFloat = 0
    private var measurePending = false
    /// Set while a `shouldChangeTextIn` recorded a single-character insertion —
    /// consumed by `textDidChange` to run typing rules exactly once.
    private var pendingInsertion: (location: Int, text: String)?

    init(controller: NoteEditorController, block: EditorBlock) {
        self.controller = controller
        self.block = block
        self.lastAppliedKind = block.kind
    }

    func tearDown() {
        if block.storage.delegate === self { block.storage.delegate = nil }
        if let layoutManager { block.storage.removeLayoutManager(layoutManager) }
        textView?.delegate = nil
        textView?.coordinator = nil
    }

    var isCodeBlock: Bool {
        if case .code = block.kind { return true }
        return false
    }

    func applyReadOnly() {
        textView?.isEditable = !controller.isReadOnly
        textView?.isSelectable = true
    }

    // MARK: Done-todo appearance (temporary attributes — never in storage)

    func applyTodoAppearance() {
        guard let layoutManager else { return }
        let full = NSRange(location: 0, length: block.storage.length)
        layoutManager.removeTemporaryAttribute(.strikethroughStyle, forCharacterRange: full)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
        if case .todo(true) = block.kind, full.length > 0 {
            layoutManager.addTemporaryAttribute(.strikethroughStyle,
                                                value: NSUnderlineStyle.single.rawValue,
                                                forCharacterRange: full)
            layoutManager.addTemporaryAttribute(.foregroundColor,
                                                value: NSColor(Theme.Colors.tertiaryText),
                                                forCharacterRange: full)
        }
    }

    // MARK: Measurement

    func scheduleMeasure() {
        guard !measurePending else { return }
        measurePending = true
        Task { @MainActor [weak self] in
            self?.measurePending = false
            self?.measureNow()
        }
    }

    func measureNow() {
        guard let textView, let layoutManager, let container = textView.textContainer else { return }
        let width = textView.bounds.width
        guard width > 1 else { return }
        lastMeasuredWidth = width
        layoutManager.ensureLayout(for: container)
        var height = layoutManager.usedRect(for: container).height
        if block.storage.length == 0 || block.storage.string.hasSuffix("\n") {
            height += NoteEditorStyle.lineHeight(for: block.kind)
        }
        let rounded = (height * 2).rounded() / 2
        if abs(rounded - block.measuredHeight) > 0.5 {
            block.measuredHeight = rounded
        }
    }

    func widthChanged(to width: CGFloat) {
        if abs(width - lastMeasuredWidth) > 0.5 { scheduleMeasure() }
    }

    // MARK: Focus

    func consumeFocusRequest(_ request: FocusRequest) {
        guard let textView else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            // A freshly split/inserted row may not be attached to the window
            // on the first turn — give it a couple of runloop beats.
            var attempts = 0
            while textView.window == nil, attempts < 5 {
                attempts += 1
                try? await Task.sleep(for: .milliseconds(25))
            }
            guard let window = textView.window else { return }
            guard self.controller.focusRequest == request else { return }
            self.controller.focusRequest = nil
            window.makeFirstResponder(textView)
            let length = self.block.storage.length
            switch request.placement {
            case .start:
                textView.setSelectedRange(NSRange(location: 0, length: 0))
            case .end:
                textView.setSelectedRange(NSRange(location: length, length: 0))
            case .utf16Offset(let offset):
                textView.setSelectedRange(NSRange(location: min(max(0, offset), length), length: 0))
            case .x(let x, let fromTop):
                let point: NSPoint
                if fromTop {
                    point = NSPoint(x: x, y: 4)
                } else {
                    let height = max(self.block.measuredHeight, 8)
                    point = NSPoint(x: x, y: height - 4)
                }
                let index = textView.characterIndexForInsertion(at: point)
                textView.setSelectedRange(NSRange(location: min(max(0, index), length), length: 0))
            }
            textView.scrollRangeToVisible(textView.selectedRange())
        }
    }

    // MARK: Caret geometry

    private func caretInfo() -> (onFirstLine: Bool, onLastLine: Bool, x: CGFloat, atStart: Bool, atEnd: Bool)? {
        guard let textView, let layoutManager, let container = textView.textContainer else { return nil }
        let selected = textView.selectedRange()
        let length = block.storage.length
        guard selected.length == 0 else { return nil }

        if length == 0 { return (true, true, 0, true, true) }

        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        let caret = selected.location

        var effective = NSRange()
        let glyphIndex: Int
        if caret >= length {
            glyphIndex = max(0, layoutManager.numberOfGlyphs - 1)
        } else {
            glyphIndex = layoutManager.glyphIndexForCharacter(at: caret)
        }
        var fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &effective)
        var inExtraFragment = false
        if caret >= length, block.storage.string.hasSuffix("\n") {
            fragment = layoutManager.extraLineFragmentRect
            inExtraFragment = true
        }

        let onFirst = fragment.minY <= 0.5 && !inExtraFragment
        let onLast = inExtraFragment || fragment.maxY >= used.maxY - 0.5
        var x: CGFloat = 0
        if caret < length || !inExtraFragment {
            let caretGlyph = caret >= length ? layoutManager.numberOfGlyphs : layoutManager.glyphIndexForCharacter(at: caret)
            if caretGlyph >= layoutManager.numberOfGlyphs {
                let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: max(0, layoutManager.numberOfGlyphs - 1), length: 1), in: container)
                x = rect.maxX
            } else {
                x = layoutManager.location(forGlyphAt: caretGlyph).x + fragment.minX
            }
        }
        return (onFirst, onLast, x, caret == 0, caret == length)
    }

    // MARK: Typing rules

    /// Line-start markdown conversions ("# ", "- ", "1. ", "[] ", "> ", "+ ",
    /// "```", "---") — Notion-style live conversion while typing.
    private func runBlockConversionRules(insertion: (location: Int, text: String)?) {
        guard block.kind == .paragraph, controller.slashMenu == nil else { return }
        guard let textView else { return }
        let text = block.storage.string
        let caret = textView.selectedRange().location

        // Whole-line instant conversions.
        if text == "---" || text == "***" {
            clearAndConvert(to: .divider)
            return
        }
        if text == "```" {
            replaceAll(with: "")
            controller.convertBlock(block.id, to: .code(language: ""))
            controller.requestFocus(block.id, placement: .start)
            return
        }

        // Marker + space conversions — only right after typing the space.
        guard let insertion, insertion.text == " " else { return }
        let prefixes: [(String, NoteBlockKind)] = [
            ("# ", .heading1), ("## ", .heading2), ("### ", .heading3),
            ("- ", .bullet), ("* ", .bullet), ("+ ", .toggle),
            ("[] ", .todo(done: false)), ("-[] ", .todo(done: false)),
            ("> ", .quote)
        ]
        for (marker, kind) in prefixes {
            let markerLength = (marker as NSString).length
            if text.hasPrefix(marker), caret == markerLength {
                stripPrefixAndConvert(markerLength: markerLength, to: kind)
                return
            }
        }
        if let match = text.range(of: #"^(\d{1,3})[.)] "#, options: .regularExpression) {
            let markerLength = (String(text[match]) as NSString).length
            if caret == markerLength {
                stripPrefixAndConvert(markerLength: markerLength, to: .numbered)
                return
            }
        }
    }

    private func stripPrefixAndConvert(markerLength: Int, to kind: NoteBlockKind) {
        guard let textView else { return }
        let range = NSRange(location: 0, length: markerLength)
        if textView.shouldChangeText(in: range, replacementString: "") {
            block.storage.replaceCharacters(in: range, with: "")
            textView.didChangeText()
        }
        controller.convertBlock(block.id, to: kind)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
    }

    private func clearAndConvert(to kind: NoteBlockKind) {
        replaceAll(with: "")
        guard let idx = controller.index(of: block.id) else { return }
        let newBlock = EditorBlock(kind: kind, indent: block.indent)
        controller.removeBlocks(ids: [block.id], actionName: "Insert Block")
        controller.insertBlocks([newBlock], at: min(idx, controller.blocks.count), actionName: "Insert Block")
        // Land the caret after the inserted divider.
        if let newIdx = controller.index(of: newBlock.id) {
            if newIdx + 1 < controller.blocks.count, controller.blocks[newIdx + 1].kind.isTextual {
                controller.requestFocus(controller.blocks[newIdx + 1].id, placement: .start)
            } else {
                let paragraph = EditorBlock(kind: .paragraph, indent: 0)
                controller.insertBlocks([paragraph], at: newIdx + 1, actionName: "Insert Block")
                controller.requestFocus(paragraph.id, placement: .start)
            }
        }
    }

    private func replaceAll(with string: String) {
        guard let textView else { return }
        let full = NSRange(location: 0, length: block.storage.length)
        if textView.shouldChangeText(in: full, replacementString: string) {
            block.storage.replaceCharacters(in: full, with: string)
            textView.didChangeText()
        }
    }

    /// Inline auto-format: `**bold**`, `*italic*`, `` `code` ``, `~~strike~~`
    /// convert as the closing marker is typed (undo restores the raw markers).
    private func runInlineFormatRules(insertion: (location: Int, text: String)?) {
        guard !isCodeBlock, controller.slashMenu == nil else { return }
        guard let insertion, "*`~".contains(insertion.text) else { return }
        guard let textView else { return }
        let caret = textView.selectedRange().location
        let text = block.storage.string as NSString
        guard caret <= text.length else { return }
        let upToCaret = text.substring(to: caret)

        let rules: [(String, (NSMutableAttributedString) -> Void)] = [
            (#"(?<![*\\])\*\*([^\s*](?:[^*]*[^\s*])?)\*\*$"#, { self.applyTrait($0, bold: true) }),
            (#"(?<![*\\])\*([^\s*](?:[^*]*[^\s*])?)\*$"#, { self.applyTrait($0, italic: true) }),
            (#"(?<!`)`([^`\n]+)`$"#, { self.applyCodeTrait($0) }),
            (#"~~([^~\n]+)~~$"#, { self.applyStrikeTrait($0) })
        ]

        for (pattern, applier) in rules {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let searchRange = NSRange(location: 0, length: (upToCaret as NSString).length)
            guard let match = regex.firstMatch(in: upToCaret, range: searchRange),
                  match.numberOfRanges > 1 else { continue }
            let contentRange = match.range(at: 1)
            let fullRange = match.range

            let inner = NSMutableAttributedString(
                attributedString: block.storage.attributedSubstring(from: contentRange)
            )
            applier(inner)
            if textView.shouldChangeText(in: fullRange, replacementString: inner.string) {
                block.storage.replaceCharacters(in: fullRange, with: inner)
                textView.didChangeText()
                textView.setSelectedRange(NSRange(location: fullRange.location + inner.length, length: 0))
                // Follow-up typing shouldn't inherit the style.
                textView.typingAttributes = NoteEditorStyle.baseAttributes(for: block.kind)
            }
            return
        }
    }

    private func applyTrait(_ text: NSMutableAttributedString, bold: Bool = false, italic: Bool = false) {
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attrs, range, _ in
            let hasBold = bold || (attrs[.ottoBold] as? Bool == true)
            let hasItalic = italic || (attrs[.ottoItalic] as? Bool == true)
            text.addAttribute(.font,
                              value: NoteEditorStyle.displayFont(for: block.kind, bold: hasBold, italicFlag: hasItalic),
                              range: range)
            if hasBold { text.addAttribute(.ottoBold, value: true, range: range) }
            if hasItalic { text.addAttribute(.ottoItalic, value: true, range: range) }
        }
    }

    private func applyCodeTrait(_ text: NSMutableAttributedString) {
        let range = NSRange(location: 0, length: text.length)
        text.addAttributes([
            .font: NoteEditorStyle.inlineCodeFont,
            .foregroundColor: NoteEditorStyle.inlineCodeColor,
            .backgroundColor: NoteEditorStyle.inlineCodeBackground,
            .ottoInlineCode: true
        ], range: range)
    }

    private func applyStrikeTrait(_ text: NSMutableAttributedString) {
        text.addAttribute(.strikethroughStyle,
                          value: NSUnderlineStyle.single.rawValue,
                          range: NSRange(location: 0, length: text.length))
    }

    // MARK: Inline formatting commands (Cmd+B / I / E / K / Shift+S)

    func toggleInlineTrait(_ trait: InlineTrait) {
        guard let textView, !controller.isReadOnly, !isCodeBlock else { return }
        let selection = textView.selectedRange()
        guard selection.length > 0 else {
            toggleTypingAttribute(trait, on: textView)
            return
        }
        let before = block.storage.attributedSubstring(from: selection)
        let mutable = NSMutableAttributedString(attributedString: before)

        switch trait {
        case .bold, .italic:
            let key: NSAttributedString.Key = trait == .bold ? .ottoBold : .ottoItalic
            // On if every run already carries it.
            var allHave = true
            mutable.enumerateAttribute(key, in: NSRange(location: 0, length: mutable.length)) { value, _, _ in
                if (value as? Bool) != true { allHave = false }
            }
            mutable.enumerateAttributes(in: NSRange(location: 0, length: mutable.length)) { attrs, range, _ in
                var bold = attrs[.ottoBold] as? Bool == true
                var italicFlag = attrs[.ottoItalic] as? Bool == true
                if trait == .bold { bold = !allHave } else { italicFlag = !allHave }
                mutable.addAttribute(.font,
                                     value: NoteEditorStyle.displayFont(for: block.kind, bold: bold, italicFlag: italicFlag),
                                     range: range)
                if bold { mutable.addAttribute(.ottoBold, value: true, range: range) }
                else { mutable.removeAttribute(.ottoBold, range: range) }
                if italicFlag { mutable.addAttribute(.ottoItalic, value: true, range: range) }
                else { mutable.removeAttribute(.ottoItalic, range: range) }
            }
        case .code:
            var allHave = true
            mutable.enumerateAttribute(.ottoInlineCode, in: NSRange(location: 0, length: mutable.length)) { value, _, _ in
                if (value as? Bool) != true { allHave = false }
            }
            let full = NSRange(location: 0, length: mutable.length)
            if allHave {
                mutable.removeAttribute(.ottoInlineCode, range: full)
                mutable.removeAttribute(.backgroundColor, range: full)
                mutable.addAttributes([
                    .font: NoteEditorStyle.font(for: block.kind),
                    .foregroundColor: NoteEditorStyle.color(for: block.kind)
                ], range: full)
            } else {
                applyCodeTrait(mutable)
            }
        case .strikethrough:
            var allHave = true
            mutable.enumerateAttribute(.strikethroughStyle, in: NSRange(location: 0, length: mutable.length)) { value, _, _ in
                if ((value as? Int) ?? 0) == 0 { allHave = false }
            }
            let full = NSRange(location: 0, length: mutable.length)
            if allHave {
                mutable.removeAttribute(.strikethroughStyle, range: full)
            } else {
                mutable.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: full)
            }
        case .link:
            promptForLink(selection: selection)
            return
        }

        block.storage.replaceCharacters(in: selection, with: mutable)
        controller.registerInlineFormatUndo(
            block: block,
            range: NSRange(location: selection.location, length: mutable.length),
            previous: before
        )
        textView.setSelectedRange(NSRange(location: selection.location, length: mutable.length))
        controller.noteEdited()
    }

    private func toggleTypingAttribute(_ trait: InlineTrait, on textView: NSTextView) {
        var attrs = textView.typingAttributes
        switch trait {
        case .bold, .italic:
            let hasBold = attrs[.ottoBold] as? Bool == true
            let hasItalic = attrs[.ottoItalic] as? Bool == true
            let bold = trait == .bold ? !hasBold : hasBold
            let italicFlag = trait == .italic ? !hasItalic : hasItalic
            attrs[.font] = NoteEditorStyle.displayFont(for: block.kind, bold: bold, italicFlag: italicFlag)
            if bold { attrs[.ottoBold] = true } else { attrs.removeValue(forKey: .ottoBold) }
            if italicFlag { attrs[.ottoItalic] = true } else { attrs.removeValue(forKey: .ottoItalic) }
        case .code:
            if attrs[.ottoInlineCode] as? Bool == true {
                attrs = NoteEditorStyle.baseAttributes(for: block.kind)
            } else {
                attrs[.font] = NoteEditorStyle.inlineCodeFont
                attrs[.foregroundColor] = NoteEditorStyle.inlineCodeColor
                attrs[.backgroundColor] = NoteEditorStyle.inlineCodeBackground
                attrs[.ottoInlineCode] = true
            }
        case .strikethrough:
            let current = (attrs[.strikethroughStyle] as? Int) ?? 0
            attrs[.strikethroughStyle] = current == 0 ? NSUnderlineStyle.single.rawValue : 0
        case .link:
            return
        }
        textView.typingAttributes = attrs
    }

    private func promptForLink(selection: NSRange) {
        guard let textView else { return }
        let existing = block.storage.length > selection.location
            ? block.storage.attribute(.link, at: selection.location, effectiveRange: nil)
            : nil

        let alert = NSAlert()
        alert.messageText = "Add Link"
        alert.informativeText = "Link the selected text to a URL."
        alert.addButton(withTitle: "Link")
        alert.addButton(withTitle: existing != nil ? "Remove Link" : "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 22))
        field.placeholderString = "https://…"
        if let url = existing as? URL { field.stringValue = url.absoluteString }
        else if let pasted = NSPasteboard.general.string(forType: .string),
                pasted.hasPrefix("http") { field.stringValue = pasted }
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let response = alert.runModal()
        let before = block.storage.attributedSubstring(from: selection)
        if response == .alertFirstButtonReturn {
            var raw = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { return }
            if !raw.contains("://"), !raw.hasPrefix("mailto:") { raw = "https://" + raw }
            guard let url = URL(string: raw) else { return }
            block.storage.addAttribute(.link, value: url, range: selection)
        } else if response == .alertSecondButtonReturn, existing != nil {
            block.storage.removeAttribute(.link, range: selection)
        } else {
            return
        }
        controller.registerInlineFormatUndo(block: block, range: selection, previous: before)
        textView.setSelectedRange(selection)
        controller.noteEdited()
    }

    // MARK: Slash menu tracking

    private func updateSlashMenuAfterEdit(insertion: (location: Int, text: String)?) {
        guard var menu = controller.slashMenu, menu.blockID == block.id else {
            // Opening: user typed "/" at start or after whitespace.
            guard let insertion, insertion.text == "/",
                  !controller.isReadOnly, !isCodeBlock else { return }
            let location = insertion.location
            let text = block.storage.string as NSString
            let okToOpen = location == 0 || {
                let prev = text.substring(with: NSRange(location: location - 1, length: 1))
                return prev == " " || prev == "\n"
            }()
            if okToOpen {
                controller.openSlashMenu(blockID: block.id, slashLocation: location)
            }
            return
        }

        guard let textView else { return }
        let caret = textView.selectedRange().location
        let text = block.storage.string as NSString

        // Synthetic menus (gutter +): typing "/" turns them into a real
        // slash session; typing anything else dismisses.
        if menu.slashLocation < 0 {
            if let insertion, insertion.text == "/" {
                controller.slashMenu = SlashMenuState(blockID: block.id, slashLocation: insertion.location)
            } else if block.storage.length > 0 {
                controller.closeSlashMenu()
            }
            return
        }

        // The "/" must still be there and the caret after it.
        guard menu.slashLocation < text.length,
              text.substring(with: NSRange(location: menu.slashLocation, length: 1)) == "/",
              caret > menu.slashLocation else {
            controller.closeSlashMenu()
            return
        }
        let queryRange = NSRange(location: menu.slashLocation + 1, length: caret - menu.slashLocation - 1)
        guard queryRange.location + queryRange.length <= text.length else {
            controller.closeSlashMenu()
            return
        }
        let query = text.substring(with: queryRange)
        if query.contains("\n") || query.count > 24 {
            controller.closeSlashMenu()
            return
        }
        menu.query = query
        menu.selectionIndex = min(menu.selectionIndex, max(0, SlashMenuItem.matches(for: query).count - 1))
        controller.slashMenu = menu
    }

    // MARK: Paste

    func handlePaste() -> Bool {
        guard !controller.isReadOnly else { return true }
        let pasteboard = NSPasteboard.general

        // Image data / image files → image blocks.
        if let images = pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage],
           let image = images.first,
           pasteboard.string(forType: .string) == nil {
            if let source = NoteAssetStore.saveImage(image) {
                controller.insertImageBlock(source: source, after: block.id)
                return true
            }
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] {
            let imageExtensions = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"]
            let imageURLs = urls.filter { $0.isFileURL && imageExtensions.contains($0.pathExtension.lowercased()) }
            if !imageURLs.isEmpty, pasteboard.string(forType: .string) == nil {
                for url in imageURLs {
                    if let source = NoteAssetStore.importImageFile(at: url) {
                        controller.insertImageBlock(source: source, alt: url.deletingPathExtension().lastPathComponent, after: block.id)
                    }
                }
                return true
            }
        }

        guard let string = pasteboard.string(forType: .string), !string.isEmpty else { return false }
        guard let textView else { return false }
        let selection = textView.selectedRange()

        // URL over a selection → make it a link.
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if selection.length > 0, !trimmed.contains(" "), !trimmed.contains("\n"),
           trimmed.hasPrefix("http"), let url = URL(string: trimmed) {
            let before = block.storage.attributedSubstring(from: selection)
            block.storage.addAttribute(.link, value: url, range: selection)
            controller.registerInlineFormatUndo(block: block, range: selection, previous: before)
            controller.noteEdited()
            return true
        }

        let normalized = NoteDocument.normalizeSeparators(string)
        if normalized.contains("\n"), !isCodeBlock {
            // Replace any selection first, then splice blocks in.
            if selection.length > 0 {
                if textView.shouldChangeText(in: selection, replacementString: "") {
                    block.storage.replaceCharacters(in: selection, with: "")
                    textView.didChangeText()
                }
            }
            controller.pasteMultiline(normalized, into: block.id, atUTF16: selection.location)
            return true
        }

        if !isCodeBlock {
            // Single line: honor inline markdown in the pasted text.
            let styled = NoteDocument.inlineAttributed(fromMarkdown: normalized, kind: block.kind)
            if textView.shouldChangeText(in: selection, replacementString: styled.string) {
                block.storage.replaceCharacters(in: selection, with: styled)
                textView.didChangeText()
                textView.setSelectedRange(NSRange(location: selection.location + styled.length, length: 0))
            }
            return true
        }
        return false
    }
}

// MARK: - NSTextViewDelegate / NSTextStorageDelegate

extension BlockTextCoordinator: NSTextViewDelegate {

    nonisolated func undoManager(for view: NSTextView) -> UndoManager? {
        MainActor.assumeIsolated { controller.undoManager }
    }

    nonisolated func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        MainActor.assumeIsolated {
            if let replacement = replacementString, replacement.count <= 1 {
                pendingInsertion = replacement.isEmpty ? nil : (affectedCharRange.location, replacement)
            } else {
                pendingInsertion = nil
            }
            return true
        }
    }

    nonisolated func textDidChange(_ notification: Notification) {
        MainActor.assumeIsolated {
            // Consume the recorded insertion up front — the rules below edit
            // the storage, which re-enters textDidChange.
            let insertion = pendingInsertion
            pendingInsertion = nil
            updateSlashMenuAfterEdit(insertion: insertion)
            runBlockConversionRules(insertion: insertion)
            runInlineFormatRules(insertion: insertion)
            applyTodoAppearance()
        }
    }

    nonisolated func textViewDidChangeSelection(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard let textView, textView.window?.firstResponder === textView else { return }
            controller.focusedBlockID = block.id
            // Moving the caret away from the slash region closes the menu.
            if let menu = controller.slashMenu, menu.blockID == block.id, menu.slashLocation >= 0 {
                let caret = textView.selectedRange().location
                if caret <= menu.slashLocation { controller.closeSlashMenu() }
            }
        }
    }

    nonisolated func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        MainActor.assumeIsolated {
            handleCommand(commandSelector)
        }
    }

    private func handleCommand(_ selector: Selector) -> Bool {
        guard let textView else { return false }

        // Slash menu captures navigation keys while open for this block.
        if let menu = controller.slashMenu, menu.blockID == block.id {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                controller.slashMenu?.selectionIndex = max(0, menu.selectionIndex - 1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                let count = SlashMenuItem.matches(for: menu.query).count
                controller.slashMenu?.selectionIndex = min(max(0, count - 1), menu.selectionIndex + 1)
                return true
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                let items = SlashMenuItem.matches(for: menu.query)
                if items.indices.contains(menu.selectionIndex) {
                    items[menu.selectionIndex].apply(controller)
                } else {
                    controller.closeSlashMenu()
                }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                controller.closeSlashMenu()
                return true
            default:
                break
            }
        }

        guard !controller.isReadOnly else { return false }
        let selection = textView.selectedRange()
        let length = block.storage.length

        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if isCodeBlock { return false }  // newline inside code
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertText("\n", replacementRange: selection)
                return true
            }
            // Replace any selection, then split at the caret.
            if selection.length > 0 {
                if textView.shouldChangeText(in: selection, replacementString: "") {
                    block.storage.replaceCharacters(in: selection, with: "")
                    textView.didChangeText()
                }
            }
            controller.undoManager.setActionName("Split Block")
            splitAtCaret()
            return true

        case #selector(NSResponder.deleteBackward(_:)):
            guard selection.length == 0, selection.location == 0 else { return false }
            controller.backspaceAtStart(block.id)
            return true

        case #selector(NSResponder.deleteForward(_:)):
            guard selection.length == 0, selection.location == length else { return false }
            controller.deleteForwardAtEnd(block.id)
            return true

        case #selector(NSResponder.insertTab(_:)):
            if isCodeBlock {
                textView.insertText("  ", replacementRange: selection)
                return true
            }
            controller.indentCommand(block.id, outdent: false)
            return true

        case #selector(NSResponder.insertBacktab(_:)):
            if isCodeBlock { return true }
            controller.indentCommand(block.id, outdent: true)
            return true

        case #selector(NSResponder.moveUp(_:)):
            if let info = caretInfo(), info.onFirstLine {
                controller.focusPrevious(from: block.id, caretX: info.x)
                return true
            }
            return false

        case #selector(NSResponder.moveDown(_:)):
            if let info = caretInfo(), info.onLastLine {
                controller.focusNext(from: block.id, caretX: info.x)
                return true
            }
            return false

        case #selector(NSResponder.moveLeft(_:)):
            if selection.length == 0, selection.location == 0 {
                controller.focusPrevious(from: block.id, caretX: nil)
                return true
            }
            return false

        case #selector(NSResponder.moveRight(_:)):
            if selection.length == 0, selection.location == length {
                controller.focusNext(from: block.id, caretX: nil)
                return true
            }
            return false

        case #selector(NSResponder.cancelOperation(_:)):
            controller.selectBlocks([block.id], anchor: block.id)
            return true

        default:
            return false
        }
    }

    private func splitAtCaret() {
        guard let textView else { return }
        controller.splitBlock(block.id, at: textView.selectedRange().location)
    }
}

extension BlockTextCoordinator: NSTextStorageDelegate {
    nonisolated func textStorage(_ textStorage: NSTextStorage,
                                 didProcessEditing editedMask: NSTextStorageEditActions,
                                 range editedRange: NSRange,
                                 changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        // Storage mutations arrive from typing AND from controller ops/undo —
        // all of them dirty the note and can change the height.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.scheduleMeasure()
            self.controller.noteEdited()
        }
    }
}

// MARK: - Inline trait enum

enum InlineTrait {
    case bold, italic, code, strikethrough, link
}

// MARK: - NSTextView subclass

final class BlockInlineTextView: NSTextView {
    weak var coordinator: BlockTextCoordinator?

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        MainActor.assumeIsolated {
            coordinator?.widthChanged(to: bounds.width)
        }
    }

    override func paste(_ sender: Any?) {
        let handled = MainActor.assumeIsolated { coordinator?.handlePaste() ?? false }
        if !handled { super.pasteAsPlainText(sender) }
    }

    override func pasteAsRichText(_ sender: Any?) { paste(sender) }

    /// Cmd+A escalation: first select the block's text, then all blocks.
    override func selectAll(_ sender: Any?) {
        let full = NSRange(location: 0, length: (string as NSString).length)
        if selectedRange() == full, full.length >= 0, let coordinator {
            MainActor.assumeIsolated { coordinator.controller.selectAllBlocks() }
            return
        }
        super.selectAll(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command), let coordinator else {
            return super.performKeyEquivalent(with: event)
        }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let hasShift = event.modifierFlags.contains(.shift)

        return MainActor.assumeIsolated {
            switch (key, hasShift) {
            case ("b", false):
                coordinator.toggleInlineTrait(.bold); return true
            case ("i", false):
                coordinator.toggleInlineTrait(.italic); return true
            case ("e", false):
                coordinator.toggleInlineTrait(.code); return true
            case ("k", false):
                if selectedRange().length > 0 { coordinator.toggleInlineTrait(.link); return true }
                return super.performKeyEquivalent(with: event)
            case ("s", true):
                coordinator.toggleInlineTrait(.strikethrough); return true
            case ("d", false):
                coordinator.controller.duplicateBlock(coordinator.block.id); return true
            default:
                return super.performKeyEquivalent(with: event)
            }
        }
    }

    /// Focused empty blocks hint at the slash menu (paragraphs) or show their
    /// type (headings) — Notion-style placeholders.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, let coordinator else { return }
        let placeholder: String
        let isFocused = window?.firstResponder === self
        switch coordinator.block.kind {
        case .heading1: placeholder = "Heading 1"
        case .heading2: placeholder = "Heading 2"
        case .heading3: placeholder = "Heading 3"
        case .code: placeholder = isFocused ? "Code" : ""
        case .toggle: placeholder = "Toggle"
        case .quote: placeholder = isFocused ? "Quote" : ""
        case .callout: placeholder = isFocused ? "Callout" : ""
        case .todo, .bullet, .numbered: placeholder = isFocused ? "List item" : ""
        default: placeholder = isFocused ? "Type “/” for commands" : ""
        }
        guard !placeholder.isEmpty else { return }
        var attrs = MainActor.assumeIsolated { NoteEditorStyle.baseAttributes(for: coordinator.block.kind) }
        attrs[.foregroundColor] = MainActor.assumeIsolated { NSColor(Theme.Colors.tertiaryText).withAlphaComponent(0.6) }
        (placeholder as NSString).draw(at: NSPoint(x: 0, y: 0), withAttributes: attrs)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became, let coordinator {
            MainActor.assumeIsolated {
                coordinator.controller.focusedBlockID = coordinator.block.id
                if !coordinator.controller.selectedBlockIDs.isEmpty {
                    coordinator.controller.clearBlockSelection()
                }
            }
        }
        needsDisplay = true
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        needsDisplay = true
        return resigned
    }
}
