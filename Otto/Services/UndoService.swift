import SwiftUI

// MARK: - Undo Service

@Observable
class UndoService {

    struct UndoAction: Identifiable {
        let id: UUID = UUID()
        let label: String
        let timestamp: Date = Date()
        let perform: @MainActor () async -> Void
    }

    private(set) var undoStack: [UndoAction] = []
    private(set) var showToast: Bool = false
    private(set) var toastLabel: String = ""

    private var dismissTask: Task<Void, Never>?
    private let maxStackDepth = 10

    // MARK: - Push

    func pushUndo(label: String, perform: @escaping @MainActor () async -> Void) {
        let action = UndoAction(label: label, perform: perform)
        undoStack.append(action)

        // Trim stack if too large
        if undoStack.count > maxStackDepth {
            undoStack.removeFirst(undoStack.count - maxStackDepth)
        }

        // Show toast
        toastLabel = label
        showToast = true
        scheduleAutoDismiss()
    }

    // MARK: - Undo

    func undo() async {
        guard let action = undoStack.popLast() else { return }
        await action.perform()
        showToast = false
        dismissTask?.cancel()
    }

    // MARK: - Dismiss

    func dismissToast() {
        showToast = false
        dismissTask?.cancel()
    }

    var canUndo: Bool {
        !undoStack.isEmpty
    }

    // MARK: - Auto-dismiss

    private func scheduleAutoDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled {
                self?.showToast = false
            }
        }
    }
}
