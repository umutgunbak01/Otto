import SwiftUI
import UniformTypeIdentifiers

/// The scrolling editor surface: header (title/properties, supplied by the
/// detail view), the block rows, and a click-to-append tail. One ScrollView
/// owns the whole page — no nested scrollers, no overlay drift.
struct BlockEditorView<Header: View>: View {
    let controller: NoteEditorController
    @ViewBuilder var header: () -> Header

    @FocusState private var chromeFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header()

                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(controller.visibleBlocks) { block in
                            BlockRowView(controller: controller, block: block)
                                .id(block.id)
                        }
                    }

                    bottomTail
                }
                .padding(.bottom, 60)
                // Notion-style centered content column.
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: controller.focusRequest) { _, request in
                if let request {
                    proxy.scrollTo(request.blockID, anchor: nil)
                }
            }
        }
        .overlayPreferenceValue(SlashMenuAnchorKey.self) { anchor in
            slashMenuOverlay(anchor: anchor)
        }
        .background(selectionKeyHandler)
        .onCopyCommand {
            guard !controller.selectedBlockIDs.isEmpty else { return [] }
            return [NSItemProvider(object: controller.markdownForSelection() as NSString)]
        }
        .onCutCommand {
            guard !controller.selectedBlockIDs.isEmpty else { return [] }
            let provider = NSItemProvider(object: controller.markdownForSelection() as NSString)
            controller.deleteSelectedBlocks()
            return [provider]
        }
        .onChange(of: controller.blockSelectionFocused) { _, focused in
            chromeFocused = focused
        }
    }

    // MARK: Selection keyboard handling

    private var selectionKeyHandler: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .focusable()
            .focusEffectDisabled()
            .focused($chromeFocused)
            .onKeyPress(phases: .down) { press in
                guard !controller.selectedBlockIDs.isEmpty else { return .ignored }
                switch press.key {
                case .escape:
                    controller.clearBlockSelection()
                    return .handled
                case .delete:
                    if controller.isReadOnly { return .ignored }
                    controller.deleteSelectedBlocks()
                    return .handled
                case .upArrow:
                    if press.modifiers.contains(.shift) {
                        controller.extendSelection(direction: -1)
                    } else {
                        controller.moveSelection(direction: -1)
                    }
                    return .handled
                case .downArrow:
                    if press.modifiers.contains(.shift) {
                        controller.extendSelection(direction: 1)
                    } else {
                        controller.moveSelection(direction: 1)
                    }
                    return .handled
                case .return:
                    let visible = controller.visibleBlocks
                    if let first = visible.first(where: {
                        controller.selectedBlockIDs.contains($0.id) && $0.kind.isTextual
                    }) {
                        controller.requestFocus(first.id, placement: .end)
                    } else {
                        controller.clearBlockSelection()
                    }
                    return .handled
                default:
                    if press.characters == "d", press.modifiers.contains(.command) {
                        if controller.isReadOnly { return .ignored }
                        controller.duplicateSelectedBlocks()
                        return .handled
                    }
                    if press.characters == "a", press.modifiers.contains(.command) {
                        controller.selectAllBlocks()
                        return .handled
                    }
                    return .ignored
                }
            }
    }

    // MARK: Click-to-append tail (and end-of-document drop target)

    private var bottomTail: some View {
        ZStack(alignment: .top) {
            Color.clear
                .frame(minHeight: 160)
                .contentShape(Rectangle())
                .onTapGesture {
                    if !controller.selectedBlockIDs.isEmpty {
                        controller.clearBlockSelection()
                        return
                    }
                    guard !controller.isReadOnly else { return }
                    if let last = controller.blocks.last, last.kind == .paragraph,
                       last.storage.length == 0 {
                        controller.requestFocus(last.id, placement: .start)
                    } else {
                        let paragraph = EditorBlock()
                        controller.insertBlocks([paragraph], at: controller.blocks.count,
                                                actionName: "Add Block")
                        controller.requestFocus(paragraph.id, placement: .start)
                    }
                }
                .onDrop(of: [.plainText], delegate: EndZoneDropDelegate(controller: controller))

            if controller.dropTargetIndex == controller.blocks.count {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Theme.Colors.accent)
                    .frame(height: 2)
                    .padding(.leading, 44)
            }
        }
    }

    // MARK: Slash menu overlay

    @ViewBuilder
    private func slashMenuOverlay(anchor: Anchor<CGRect>?) -> some View {
        GeometryReader { proxy in
            if let state = controller.slashMenu, let anchor {
                let rect = proxy[anchor]
                let menuHeight: CGFloat = min(CGFloat(max(1, SlashMenuItem.matches(for: state.query).count)) * 44 + 36, 330)
                let flip = rect.maxY + menuHeight + 8 > proxy.size.height
                let y = flip ? max(4, rect.minY - menuHeight - 4) : rect.maxY + 4
                let x = min(max(4, rect.minX + 44), max(4, proxy.size.width - 308))

                ZStack(alignment: .topLeading) {
                    // Click-away catcher: any click outside the menu dismisses.
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { controller.closeSlashMenu() }

                    SlashMenuView(controller: controller, state: state)
                        .offset(x: x, y: y)
                }
                .transition(.opacity)
            }
        }
        .allowsHitTesting(controller.slashMenu != nil)
    }
}

// MARK: - End-of-document drop delegate

struct EndZoneDropDelegate: DropDelegate {
    let controller: NoteEditorController

    func validateDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated { controller.draggedBlockID != nil }
    }

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated {
            guard controller.draggedBlockID != nil else { return }
            controller.dropTargetIndex = controller.blocks.count
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        MainActor.assumeIsolated {
            guard controller.draggedBlockID != nil else { return nil }
            controller.dropTargetIndex = controller.blocks.count
            return DropProposal(operation: .move)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            guard let target = controller.dropTargetIndex else { return false }
            controller.moveDraggedBlock(to: target)
            return true
        }
    }
}
