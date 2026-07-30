import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Where the caret should land when a block receives focus.
enum CaretPlacement: Equatable {
    case start
    case end
    case utf16Offset(Int)
    /// Preserve horizontal position when arrowing across blocks.
    /// `fromTop` = true lands on the block's first visual line, false on its last.
    case x(CGFloat, fromTop: Bool)
}

struct FocusRequest: Equatable {
    let blockID: UUID
    var placement: CaretPlacement
}

struct SlashMenuState: Equatable {
    var blockID: UUID
    /// UTF-16 location of the "/" character inside the block's text.
    /// -1 for a synthetic open (gutter "+" button) with no slash to remove.
    var slashLocation: Int
    var query: String = ""
    var selectionIndex: Int = 0
}

/// The document brain of the block editor: owns the block array, the shared
/// undo manager, focus/selection/slash-menu state, and every structural
/// operation. Text INSIDE a block is edited by that block's NSTextView
/// directly on `block.storage` — the controller only moves whole blocks
/// around, so the caret and the undo stack survive every operation (the old
/// editor rebuilt the entire text view on any block action).
@MainActor
@Observable
final class NoteEditorController {

    var blocks: [EditorBlock]
    let undoManager = UndoManager()
    var isReadOnly = false

    // Focus
    var focusRequest: FocusRequest?
    var focusedBlockID: UUID?
    /// Arrow-up from the very first block exits into the title field.
    var onExitTop: (() -> Void)?

    // Block-selection mode (Esc / handle click / Cmd+A escalation)
    var selectedBlockIDs: Set<UUID> = []
    var selectionAnchorID: UUID?
    /// The container's focus binding flips on when block selection starts so
    /// keyboard events (arrows, Backspace, Cmd+D) route to the editor chrome
    /// instead of a text view.
    var blockSelectionFocused = false

    // Slash menu
    var slashMenu: SlashMenuState?

    // Drag & drop reorder
    var draggedBlockID: UUID?
    /// Insertion index into `blocks` the current drag would drop at.
    var dropTargetIndex: Int?

    // Change tracking
    private(set) var isDirty = false
    var onContentEdited: (() -> Void)?

    init(markdown: String, readOnly: Bool = false) {
        self.blocks = NoteDocument.parse(markdown)
        self.isReadOnly = readOnly
        self.undoManager.groupsByEvent = true
    }

    func serialized() -> String { NoteDocument.serialize(blocks) }

    func markSaved() { isDirty = false }

    /// Replace the whole document (external update while not dirty).
    func reload(markdown: String) {
        blocks = NoteDocument.parse(markdown)
        selectedBlockIDs = []
        slashMenu = nil
        focusRequest = nil
        isDirty = false
        undoManager.removeAllActions()
    }

    func noteEdited() {
        isDirty = true
        onContentEdited?()
    }

    // MARK: - Lookup

    func index(of id: UUID) -> Int? { blocks.firstIndex(where: { $0.id == id }) }
    func block(_ id: UUID) -> EditorBlock? { blocks.first(where: { $0.id == id }) }

    /// Blocks currently visible (children of collapsed toggles are hidden).
    var visibleBlocks: [EditorBlock] {
        var result: [EditorBlock] = []
        var hideDeeperThan: Int?
        for block in blocks {
            if let level = hideDeeperThan {
                if block.indent > level { continue }
                hideDeeperThan = nil
            }
            result.append(block)
            if block.kind == .toggle, block.isCollapsed {
                hideDeeperThan = block.indent
            }
        }
        return result
    }

    /// The contiguous run of blocks nested under `index` (deeper indent).
    func descendantRange(of index: Int) -> Range<Int> {
        let indent = blocks[index].indent
        var end = index + 1
        while end < blocks.count, blocks[end].indent > indent { end += 1 }
        return (index + 1)..<end
    }

    /// Display number for a numbered block — computed from document order so
    /// numbering is always correct (matches the serializer's counters).
    func displayNumber(for block: EditorBlock) -> Int {
        guard case .numbered = block.kind, let idx = index(of: block.id) else { return 1 }
        var count = 1
        var i = idx - 1
        while i >= 0 {
            let other = blocks[i]
            if other.indent > block.indent { i -= 1; continue }
            if other.indent < block.indent { break }
            if case .numbered = other.kind { count += 1; i -= 1 } else { break }
        }
        return count
    }

    private func visibleTextualBlock(before id: UUID) -> EditorBlock? {
        let visible = visibleBlocks
        guard let idx = visible.firstIndex(where: { $0.id == id }) else { return nil }
        for i in stride(from: idx - 1, through: 0, by: -1) where visible[i].kind.isTextual {
            return visible[i]
        }
        return nil
    }

    private func visibleTextualBlock(after id: UUID) -> EditorBlock? {
        let visible = visibleBlocks
        guard let idx = visible.firstIndex(where: { $0.id == id }) else { return nil }
        for i in (idx + 1)..<visible.count where visible[i].kind.isTextual {
            return visible[i]
        }
        return nil
    }

    // MARK: - Focus

    func requestFocus(_ id: UUID, placement: CaretPlacement) {
        selectedBlockIDs = []
        blockSelectionFocused = false
        focusRequest = FocusRequest(blockID: id, placement: placement)
    }

    /// Title-field Return/↓ lands here.
    func focusFirstBlock() {
        if let first = blocks.first(where: { $0.kind.isTextual }) {
            requestFocus(first.id, placement: .start)
        } else {
            let paragraph = EditorBlock()
            insertBlocks([paragraph], at: 0, actionName: "Add Block")
            requestFocus(paragraph.id, placement: .start)
        }
    }

    func focusPrevious(from id: UUID, caretX: CGFloat?) {
        if let prev = visibleTextualBlock(before: id) {
            requestFocus(prev.id, placement: caretX.map { .x($0, fromTop: false) } ?? .end)
        } else {
            onExitTop?()
        }
    }

    func focusNext(from id: UUID, caretX: CGFloat?) {
        if let next = visibleTextualBlock(after: id) {
            requestFocus(next.id, placement: caretX.map { .x($0, fromTop: true) } ?? .start)
        } else if let idx = index(of: id), idx == blocks.count - 1,
                  blocks[idx].kind.isTextual, blocks[idx].storage.length > 0 {
            // Arrow-down past the last block: append an empty paragraph
            // (also the escape hatch out of a trailing code block).
            let newBlock = EditorBlock(kind: .paragraph, indent: 0)
            insertBlocks([newBlock], at: blocks.count, actionName: "Add Block")
            requestFocus(newBlock.id, placement: .start)
        }
    }

    // MARK: - Structural operations (all undoable on the shared manager)

    /// Low-level insert with inverse registration.
    func insertBlocks(_ newBlocks: [EditorBlock], at index: Int, actionName: String) {
        guard !newBlocks.isEmpty else { return }
        let clamped = min(max(0, index), blocks.count)
        blocks.insert(contentsOf: newBlocks, at: clamped)
        let ids = Set(newBlocks.map(\.id))
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.removeBlocks(ids: ids, actionName: actionName) }
        }
        undoManager.setActionName(actionName)
        noteEdited()
    }

    /// Low-level remove with inverse registration.
    func removeBlocks(ids: Set<UUID>, actionName: String) {
        let removed = blocks.enumerated().filter { ids.contains($0.element.id) }
        guard !removed.isEmpty else { return }
        blocks.removeAll { ids.contains($0.id) }
        // Never leave an empty document.
        var insertedPlaceholder: EditorBlock?
        if blocks.isEmpty {
            let placeholder = EditorBlock()
            blocks = [placeholder]
            insertedPlaceholder = placeholder
        }
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                if let placeholder = insertedPlaceholder {
                    target.blocks.removeAll { $0.id == placeholder.id }
                }
                for (position, block) in removed {
                    let at = min(position, target.blocks.count)
                    target.blocks.insert(block, at: at)
                }
                target.undoManager.registerUndo(withTarget: target) { inner in
                    MainActor.assumeIsolated { inner.removeBlocks(ids: ids, actionName: actionName) }
                }
                target.noteEdited()
            }
        }
        undoManager.setActionName(actionName)
        selectedBlockIDs.subtract(ids)
        noteEdited()
    }

    /// Return-key split. `utf16Offset` is the caret position in the block.
    func splitBlock(_ id: UUID, at utf16Offset: Int) {
        guard let idx = index(of: id) else { return }
        let block = blocks[idx]
        let length = block.storage.length
        let offset = min(max(0, utf16Offset), length)

        // Enter on an empty list-ish block exits the list (Notion behavior):
        // first outdent, then convert to paragraph.
        if length == 0 {
            switch block.kind {
            case .bullet, .numbered, .todo, .toggle, .quote, .callout:
                if block.indent > 0 {
                    setIndent(id, to: block.indent - 1)
                } else {
                    convertBlock(id, to: .paragraph)
                }
                return
            default:
                break
            }
        }

        // Enter at the very start of a non-empty block: push an empty twin
        // above, caret stays put (the old editor mangled this case).
        if offset == 0, length > 0 {
            let kind: NoteBlockKind
            switch block.kind {
            case .bullet, .numbered, .quote: kind = block.kind
            case .todo: kind = .todo(done: false)
            default: kind = .paragraph
            }
            let newBlock = EditorBlock(kind: kind, indent: block.indent)
            insertBlocks([newBlock], at: idx, actionName: "Split Block")
            return
        }

        // Tail block kind: lists continue, headings/callouts fall to paragraph,
        // toggles get a child when expanded.
        var tailKind: NoteBlockKind
        var tailIndent = block.indent
        switch block.kind {
        case .bullet, .numbered, .quote: tailKind = block.kind
        case .todo: tailKind = .todo(done: false)
        case .toggle:
            if block.isCollapsed {
                tailKind = .paragraph
            } else {
                tailKind = .paragraph
                tailIndent = block.indent + 1
            }
        default: tailKind = .paragraph
        }

        let tailRange = NSRange(location: offset, length: length - offset)
        let tailText = block.storage.attributedSubstring(from: tailRange)
        let newBlock = EditorBlock(kind: tailKind, indent: tailIndent)
        if tailText.length > 0 {
            let markdown = NoteDocument.inlineMarkdown(from: tailText, kind: block.kind)
            newBlock.storage.setAttributedString(
                NoteDocument.inlineAttributed(fromMarkdown: markdown, kind: tailKind)
            )
            // Removing the tail from the source block is undoable text-wise.
            replaceStorageText(block, range: tailRange, with: NSAttributedString(), actionName: "Split Block")
        }
        insertBlocks([newBlock], at: idx + 1, actionName: "Split Block")
        requestFocus(newBlock.id, placement: .start)
    }

    /// Backspace at block start. Notion's ladder: non-paragraph → paragraph;
    /// indented → outdent; else merge into the previous textual block.
    func backspaceAtStart(_ id: UUID) {
        guard let idx = index(of: id) else { return }
        let block = blocks[idx]

        if !(block.kind == .paragraph) && block.kind.isTextual {
            convertBlock(id, to: .paragraph)
            return
        }
        if block.indent > 0 {
            setIndent(id, to: block.indent - 1)
            return
        }

        // Merge with the previous visible block.
        guard let visibleIdx = visibleBlocks.firstIndex(where: { $0.id == id }), visibleIdx > 0 else { return }
        let previous = visibleBlocks[visibleIdx - 1]

        guard previous.kind.isTextual else {
            // Previous is a divider/image: backspace removes it (Notion selects
            // it; removing is the pragmatic one-step version).
            removeBlocks(ids: [previous.id], actionName: "Delete Block")
            return
        }

        if case .code = previous.kind {
            // Don't merge prose into a code block.
            if block.storage.length == 0 {
                removeBlocks(ids: [id], actionName: "Delete Block")
                requestFocus(previous.id, placement: .end)
            } else {
                requestFocus(previous.id, placement: .end)
            }
            return
        }

        let junction = previous.storage.length
        if block.storage.length > 0 {
            let markdown = NoteDocument.inlineMarkdown(from: block.storage, kind: block.kind)
            let restyled = NoteDocument.inlineAttributed(fromMarkdown: markdown, kind: previous.kind)
            replaceStorageText(previous, range: NSRange(location: junction, length: 0),
                               with: restyled, actionName: "Merge Blocks")
        }
        removeBlocks(ids: [id], actionName: "Merge Blocks")
        requestFocus(previous.id, placement: .utf16Offset(junction))
    }

    /// Forward-delete at block end: pull the next block's text into this one.
    func deleteForwardAtEnd(_ id: UUID) {
        guard let idx = index(of: id), idx + 1 < blocks.count else { return }
        let block = blocks[idx]
        let next = blocks[idx + 1]
        guard block.kind.isTextual else { return }

        guard next.kind.isTextual else {
            removeBlocks(ids: [next.id], actionName: "Delete Block")
            return
        }
        if case .code = next.kind {
            return
        }
        let junction = block.storage.length
        if next.storage.length > 0 {
            let markdown = NoteDocument.inlineMarkdown(from: next.storage, kind: next.kind)
            let restyled = NoteDocument.inlineAttributed(fromMarkdown: markdown, kind: block.kind)
            replaceStorageText(block, range: NSRange(location: junction, length: 0),
                               with: restyled, actionName: "Merge Blocks")
        }
        removeBlocks(ids: [next.id], actionName: "Merge Blocks")
        requestFocus(id, placement: .utf16Offset(junction))
    }

    /// Undo for attribute-only edits (Cmd+B etc.). Registered on the
    /// controller — NEVER on a row coordinator, which LazyVStack deallocates
    /// while the undo stack is still alive.
    func registerInlineFormatUndo(block: EditorBlock, range: NSRange, previous: NSAttributedString) {
        guard range.location + range.length <= block.storage.length else { return }
        let current = block.storage.attributedSubstring(from: range)
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                guard range.location + range.length <= block.storage.length else { return }
                block.storage.replaceCharacters(in: range, with: previous)
                let previousRange = NSRange(location: range.location, length: previous.length)
                target.registerInlineFormatUndo(block: block, range: previousRange, previous: current)
                target.requestFocus(block.id, placement: .utf16Offset(range.location + previous.length))
                target.noteEdited()
            }
        }
        undoManager.setActionName("Format")
    }

    /// Undoable text replacement inside a block's storage (used by structural
    /// ops — plain typing goes through the text view's own undo path).
    private func replaceStorageText(_ block: EditorBlock, range: NSRange,
                                    with replacement: NSAttributedString, actionName: String) {
        let previous = block.storage.attributedSubstring(from: range)
        block.storage.replaceCharacters(in: range, with: replacement)
        let newRange = NSRange(location: range.location, length: replacement.length)
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.replaceStorageText(block, range: newRange, with: previous, actionName: actionName)
                target.requestFocus(block.id, placement: .utf16Offset(range.location + previous.length))
            }
        }
        undoManager.setActionName(actionName)
        noteEdited()
    }

    // MARK: - Kind / indent changes

    func convertBlock(_ id: UUID, to newKind: NoteBlockKind) {
        guard let block = block(id) else { return }
        let oldKind = block.kind
        guard oldKind != newKind else { return }
        NoteDocument.restyle(block.storage, from: oldKind, to: newKind)
        block.kind = newKind
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.convertBlock(id, to: oldKind) }
        }
        undoManager.setActionName("Turn Into")
        noteEdited()
    }

    func toggleTodo(_ id: UUID) {
        guard let block = block(id), case .todo(let done) = block.kind else { return }
        block.kind = .todo(done: !done)
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.toggleTodo(id) }
        }
        undoManager.setActionName(done ? "Uncheck" : "Check")
        noteEdited()
    }

    func toggleCollapse(_ id: UUID) {
        guard let block = block(id), block.kind == .toggle else { return }
        block.isCollapsed.toggle()
        // View state only — not an edit, not undoable, not dirtying.
    }

    func setIndent(_ id: UUID, to newIndent: Int) {
        guard let idx = index(of: id) else { return }
        let block = blocks[idx]
        guard block.kind.supportsIndent else { return }
        // Can't indent deeper than one past the previous block.
        let maxIndent = idx > 0 ? blocks[idx - 1].indent + 1 : 0
        let clamped = min(max(0, newIndent), min(maxIndent, 8))
        let oldIndent = block.indent
        guard clamped != oldIndent else { return }
        block.indent = clamped
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.setIndent(id, to: oldIndent) }
        }
        undoManager.setActionName(clamped > oldIndent ? "Indent" : "Outdent")
        noteEdited()
    }

    func indentCommand(_ id: UUID, outdent: Bool) {
        guard let block = block(id) else { return }
        setIndent(id, to: block.indent + (outdent ? -1 : 1))
    }

    // MARK: - Move / duplicate / delete (blocks move with their children)

    /// The block plus its nested descendants, as indices into `blocks`.
    private func movableRange(for id: UUID) -> Range<Int>? {
        guard let idx = index(of: id) else { return nil }
        return idx..<descendantRange(of: idx).upperBound
    }

    func moveDraggedBlock(to targetIndex: Int) {
        guard let dragged = draggedBlockID, let range = movableRange(for: dragged) else {
            draggedBlockID = nil
            dropTargetIndex = nil
            return
        }
        defer { draggedBlockID = nil; dropTargetIndex = nil }
        // Dropping inside the moving range is a no-op.
        guard targetIndex <= range.lowerBound || targetIndex >= range.upperBound else { return }

        let moving = Array(blocks[range])
        let destination = targetIndex > range.upperBound ? targetIndex - moving.count : targetIndex
        blocks.removeSubrange(range)
        let clamped = min(max(0, destination), blocks.count)
        blocks.insert(contentsOf: moving, at: clamped)

        let sourceIndex = range.lowerBound
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.draggedBlockID = dragged
                target.moveDraggedBlock(to: sourceIndex > clamped ? sourceIndex + moving.count : sourceIndex)
            }
        }
        undoManager.setActionName("Move Block")
        noteEdited()
    }

    func duplicateBlock(_ id: UUID) {
        guard let range = movableRange(for: id) else { return }
        let copies = blocks[range].map { original -> EditorBlock in
            EditorBlock(
                kind: original.kind,
                text: NSAttributedString(attributedString: original.storage),
                indent: original.indent,
                isCollapsed: original.isCollapsed
            )
        }
        insertBlocks(copies, at: range.upperBound, actionName: "Duplicate Block")
        if let first = copies.first, first.kind.isTextual {
            requestFocus(first.id, placement: .end)
        }
    }

    func deleteBlockAndChildren(_ id: UUID) {
        guard let range = movableRange(for: id) else { return }
        let ids = Set(blocks[range].map(\.id))
        let focusAfter = visibleTextualBlock(before: id)?.id
        removeBlocks(ids: ids, actionName: "Delete Block")
        if let focusAfter {
            requestFocus(focusAfter, placement: .end)
        }
    }

    // MARK: - Block selection mode

    func selectBlocks(_ ids: Set<UUID>, anchor: UUID?) {
        selectedBlockIDs = ids
        selectionAnchorID = anchor ?? ids.first
        blockSelectionFocused = !ids.isEmpty
        if !ids.isEmpty {
            slashMenu = nil
            // Pull keyboard focus out of any text view.
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    func clearBlockSelection() {
        selectedBlockIDs = []
        selectionAnchorID = nil
        blockSelectionFocused = false
    }

    func selectAllBlocks() {
        selectBlocks(Set(blocks.map(\.id)), anchor: blocks.first?.id)
    }

    func extendSelection(direction: Int) {
        let visible = visibleBlocks
        guard !visible.isEmpty else { return }
        guard let anchorID = selectionAnchorID,
              let anchorIdx = visible.firstIndex(where: { $0.id == anchorID }) else { return }
        // Find the current extent in the given direction.
        let selectedIdxs = visible.enumerated().filter { selectedBlockIDs.contains($0.element.id) }.map(\.offset)
        guard let minIdx = selectedIdxs.min(), let maxIdx = selectedIdxs.max() else { return }
        var newMin = minIdx
        var newMax = maxIdx
        if direction > 0 {
            if minIdx < anchorIdx { newMin = minIdx + 1 } else { newMax = min(visible.count - 1, maxIdx + 1) }
        } else {
            if maxIdx > anchorIdx { newMax = maxIdx - 1 } else { newMin = max(0, minIdx - 1) }
        }
        selectedBlockIDs = Set(visible[newMin...newMax].map(\.id))
    }

    func moveSelection(direction: Int) {
        let visible = visibleBlocks
        guard !visible.isEmpty else { return }
        let selectedIdxs = visible.enumerated().filter { selectedBlockIDs.contains($0.element.id) }.map(\.offset)
        let current = direction > 0 ? (selectedIdxs.max() ?? -1) : (selectedIdxs.min() ?? visible.count)
        let next = min(max(0, current + direction), visible.count - 1)
        selectBlocks([visible[next].id], anchor: visible[next].id)
    }

    func deleteSelectedBlocks() {
        guard !selectedBlockIDs.isEmpty else { return }
        // Include hidden children of any selected collapsed toggle.
        var ids = selectedBlockIDs
        for id in selectedBlockIDs {
            if let idx = index(of: id), blocks[idx].kind == .toggle, blocks[idx].isCollapsed {
                ids.formUnion(blocks[descendantRange(of: idx)].map(\.id))
            }
        }
        // Land the caret on the nearest surviving textual block afterwards.
        let visible = visibleBlocks
        let firstSelectedIdx = visible.firstIndex(where: { ids.contains($0.id) }) ?? 0
        let fallback = visible.prefix(firstSelectedIdx).last(where: { $0.kind.isTextual && !ids.contains($0.id) })
            ?? visible.dropFirst(firstSelectedIdx).first(where: { $0.kind.isTextual && !ids.contains($0.id) })

        removeBlocks(ids: ids, actionName: "Delete Blocks")
        clearBlockSelection()
        if let fallback, block(fallback.id) != nil {
            requestFocus(fallback.id, placement: .end)
        } else if let first = blocks.first(where: { $0.kind.isTextual }) {
            requestFocus(first.id, placement: .end)
        }
    }

    func duplicateSelectedBlocks() {
        let visible = visibleBlocks
        let ordered = visible.filter { selectedBlockIDs.contains($0.id) }
        guard let last = ordered.last, let insertAt = index(of: last.id) else { return }
        var copies: [EditorBlock] = []
        for original in blocks where selectedBlockIDs.contains(original.id) {
            copies.append(EditorBlock(
                kind: original.kind,
                text: NSAttributedString(attributedString: original.storage),
                indent: original.indent,
                isCollapsed: original.isCollapsed
            ))
        }
        insertBlocks(copies, at: descendantRange(of: insertAt).upperBound, actionName: "Duplicate Blocks")
        selectBlocks(Set(copies.map(\.id)), anchor: copies.first?.id)
    }

    /// Markdown for the selected blocks (block-selection copy).
    func markdownForSelection() -> String {
        let ordered = blocks.filter { selectedBlockIDs.contains($0.id) }
        return NoteDocument.serialize(ordered)
    }

    // MARK: - Slash menu

    func openSlashMenu(blockID: UUID, slashLocation: Int) {
        guard !isReadOnly else { return }
        slashMenu = SlashMenuState(blockID: blockID, slashLocation: slashLocation)
    }

    func closeSlashMenu() {
        slashMenu = nil
    }

    /// Insert a new paragraph below `id`, focus it, and open the slash menu
    /// (the gutter "+" button).
    func insertBlockBelowAndPrompt(_ id: UUID) {
        guard let idx = index(of: id) else { return }
        let insertAt = descendantRange(of: idx).upperBound
        let newBlock = EditorBlock(kind: .paragraph, indent: blocks[idx].indent)
        insertBlocks([newBlock], at: insertAt, actionName: "Add Block")
        requestFocus(newBlock.id, placement: .start)
        openSlashMenu(blockID: newBlock.id, slashLocation: -1)
    }

    /// Remove the "/query" characters the user typed to summon the menu.
    private func stripSlashQuery(_ menu: SlashMenuState, from block: EditorBlock) {
        guard menu.slashLocation >= 0 else { return }
        let queryLength = (menu.query as NSString).length
        let removeRange = NSRange(location: menu.slashLocation, length: 1 + queryLength)
        if removeRange.location + removeRange.length <= block.storage.length {
            replaceStorageText(block, range: removeRange, with: NSAttributedString(), actionName: "Insert Block")
        }
    }

    /// Slash-menu "Image": strip the query, then pick a file and insert.
    func applySlashImagePicker() {
        guard let menu = slashMenu, let block = block(menu.blockID) else { closeSlashMenu(); return }
        closeSlashMenu()
        stripSlashQuery(menu, from: block)

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif, .heic, .webP, .tiff, .bmp, .image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an image to embed in the note"
        if panel.runModal() == .OK, let url = panel.url,
           let source = NoteAssetStore.importImageFile(at: url) {
            insertImageBlock(source: source,
                             alt: url.deletingPathExtension().lastPathComponent,
                             after: block.id)
        } else {
            requestFocus(block.id, placement: .end)
        }
    }

    func setCodeLanguage(_ id: UUID, language: String) {
        guard let block = block(id), case .code(let old) = block.kind, old != language else { return }
        block.kind = .code(language: language)
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.setCodeLanguage(id, language: old) }
        }
        undoManager.setActionName("Set Language")
        noteEdited()
    }

    /// Apply the chosen slash-menu item: strip the "/query", then convert the
    /// (now empty) block or insert a fresh sibling below.
    func applySlashSelection(_ kind: NoteBlockKind) {
        guard let menu = slashMenu, let block = block(menu.blockID) else { closeSlashMenu(); return }
        closeSlashMenu()
        stripSlashQuery(menu, from: block)

        switch kind {
        case .divider, .image:
            if block.storage.length == 0, block.kind == .paragraph {
                // Convert the empty paragraph in place.
                if let idx = index(of: block.id) {
                    let newBlock = EditorBlock(kind: kind, indent: block.indent)
                    removeBlocks(ids: [block.id], actionName: "Insert Block")
                    insertBlocks([newBlock], at: min(idx, blocks.count), actionName: "Insert Block")
                    focusAroundNonTextual(newBlock.id)
                }
            } else if let idx = index(of: block.id) {
                let newBlock = EditorBlock(kind: kind, indent: block.indent)
                insertBlocks([newBlock], at: idx + 1, actionName: "Insert Block")
                focusAroundNonTextual(newBlock.id)
            }
        default:
            if block.storage.length == 0 {
                convertBlock(block.id, to: kind)
                requestFocus(block.id, placement: .start)
            } else if let idx = index(of: block.id) {
                let newBlock = EditorBlock(kind: kind, indent: block.indent)
                insertBlocks([newBlock], at: idx + 1, actionName: "Insert Block")
                requestFocus(newBlock.id, placement: .start)
            }
        }
    }

    /// After inserting a divider/image, put the caret somewhere sensible.
    private func focusAroundNonTextual(_ id: UUID) {
        if let next = visibleTextualBlock(after: id) {
            requestFocus(next.id, placement: .start)
        } else if let idx = index(of: id) {
            let paragraph = EditorBlock(kind: .paragraph, indent: 0)
            insertBlocks([paragraph], at: idx + 1, actionName: "Add Block")
            requestFocus(paragraph.id, placement: .start)
        }
    }

    // MARK: - Images

    func insertImageBlock(source: String, alt: String = "", after id: UUID?) {
        let newBlock = EditorBlock(kind: .image(source: source, alt: alt))
        if let id, let idx = index(of: id) {
            newBlock.indent = blocks[idx].indent
            insertBlocks([newBlock], at: idx + 1, actionName: "Insert Image")
        } else {
            insertBlocks([newBlock], at: blocks.count, actionName: "Insert Image")
        }
        focusAroundNonTextual(newBlock.id)
    }

    // MARK: - Multi-line paste

    /// Paste text containing newlines: the first line joins the focused block
    /// at the caret; the rest become new blocks after it.
    func pasteMultiline(_ text: String, into id: UUID, atUTF16 offset: Int) {
        guard let block = block(id), let idx = index(of: id) else { return }
        let normalized = NoteDocument.normalizeSeparators(text)
        var lines = normalized.components(separatedBy: "\n")
        guard !lines.isEmpty else { return }

        let first = lines.removeFirst()
        if !first.isEmpty {
            let styled = NoteDocument.inlineAttributed(fromMarkdown: first, kind: block.kind)
            let clamped = min(max(0, offset), block.storage.length)
            replaceStorageText(block, range: NSRange(location: clamped, length: 0),
                               with: styled, actionName: "Paste")
        }
        let rest = lines.joined(separator: "\n")
        guard !rest.isEmpty else {
            requestFocus(id, placement: .utf16Offset(min(offset + (first as NSString).length, block.storage.length)))
            return
        }
        let newBlocks = NoteDocument.parse(rest)
        // Inherit the paste-target's indent as a base.
        for newBlock in newBlocks { newBlock.indent += block.indent }
        insertBlocks(newBlocks, at: idx + 1, actionName: "Paste")
        if let last = newBlocks.last {
            requestFocus(last.id, placement: last.kind.isTextual ? .end : .start)
        }
    }
}
