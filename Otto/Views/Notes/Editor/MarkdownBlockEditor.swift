import SwiftUI

/// Embeddable block editor bound to a markdown string (used by the Ideas
/// tab). Renders rows in a plain VStack — the CALLER owns the ScrollView, so
/// there is no nested-scroller fight. Edits serialize back into the binding
/// after a short debounce.
struct MarkdownBlockEditor: View {
    @Binding var content: String

    @State private var controller: NoteEditorController?
    @State private var lastSerialized: String = ""
    @State private var writeBackTask: Task<Void, Never>?

    var body: some View {
        Group {
            if let controller {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(controller.visibleBlocks) { block in
                        BlockRowView(controller: controller, block: block)
                            .id(block.id)
                    }
                }
                .overlayPreferenceValue(SlashMenuAnchorKey.self) { anchor in
                    GeometryReader { proxy in
                        if let state = controller.slashMenu, let anchor {
                            let rect = proxy[anchor]
                            ZStack(alignment: .topLeading) {
                                Color.black.opacity(0.001)
                                    .contentShape(Rectangle())
                                    .onTapGesture { controller.closeSlashMenu() }
                                SlashMenuView(controller: controller, state: state)
                                    .offset(x: max(4, rect.minX + 44), y: rect.maxY + 4)
                            }
                        }
                    }
                    .allowsHitTesting(controller.slashMenu != nil)
                }
            } else {
                Color.clear.frame(height: 24)
            }
        }
        .onAppear { setUp() }
        .onDisappear {
            writeBackTask?.cancel()
            flushNow()
        }
        .onChange(of: content) { _, newValue in
            // External update (loading a different item, AI edit): reload
            // unless the change is our own write-back echo.
            guard let controller else { return }
            let normalized = NoteDocument.normalizeSeparators(newValue)
            if !controller.isDirty, normalized != lastSerialized {
                lastSerialized = normalized
                controller.reload(markdown: normalized)
            }
        }
    }

    private func setUp() {
        guard controller == nil else { return }
        let normalized = NoteDocument.normalizeSeparators(content)
        let newController = NoteEditorController(markdown: normalized)
        lastSerialized = normalized
        newController.onContentEdited = { scheduleWriteBack() }
        controller = newController
    }

    private func scheduleWriteBack() {
        writeBackTask?.cancel()
        writeBackTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            flushNow()
        }
    }

    private func flushNow() {
        guard let controller, controller.isDirty else { return }
        let serialized = controller.serialized()
        controller.markSaved()
        guard serialized != lastSerialized else { return }
        lastSerialized = serialized
        content = serialized
    }
}
