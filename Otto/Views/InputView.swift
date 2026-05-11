import SwiftUI

struct InputView: View {
    @Environment(AppState.self) private var appState
    @FocusState private var isFocused: Bool
    @State private var selectedType: ContentType = .todo
    @State private var showTypeSelector: Bool = false

    var body: some View {
        @Bindable var state = appState

        VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.md) {
                // Type selector button
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showTypeSelector.toggle()
                    }
                } label: {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: selectedType.iconName)
                            .font(.system(size: 14))
                        Text(selectedType.displayName)
                            .font(Theme.Typography.caption)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundStyle(typeColor)
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, Theme.Spacing.xs)
                    .background(typeColor.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                }
                .buttonStyle(.plain)

                // Text input
                TextField(placeholderText, text: $state.inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.Typography.body)
                    .lineLimit(1...3)
                    .focused($isFocused)
                    .onSubmit {
                        submitInput()
                    }

                // Submit button
                if canSubmit {
                    Button {
                        submitInput()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Theme.Colors.accent)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.md)

            // Type selector dropdown
            if showTypeSelector {
                Divider()
                    .padding(.horizontal, Theme.Spacing.md)

                typeSelectorView
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.sm)
            }
        }
        .background(Theme.Colors.background)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .stroke(isFocused ? Theme.Colors.accent.opacity(0.5) : Theme.Colors.border, lineWidth: 1)
        )
    }

    private var placeholderText: String {
        switch selectedType {
        case .todo: return "What needs to be done?"
        case .note: return "Write a note..."
        case .idea: return "Capture your idea..."
        case .reminder: return "Remind me to..."
        case .bookmark: return "Paste a URL to save..."
        default: return "Add something..."
        }
    }

    private var typeColor: Color {
        switch selectedType {
        case .todo: return Theme.Colors.accent
        case .note: return Theme.Colors.work
        case .idea: return Theme.Colors.hobby
        case .reminder: return Theme.Colors.priorityHigh
        case .bookmark: return .pink
        default: return Theme.Colors.accent
        }
    }

    private var typeSelectorView: some View {
        HStack(spacing: Theme.Spacing.sm) {
            ForEach([ContentType.todo, .note, .idea, .reminder, .bookmark]) { type in
                typeButton(type)
            }
            Spacer()
        }
    }

    private func typeButton(_ type: ContentType) -> some View {
        let isSelected = selectedType == type
        let color: Color = {
            switch type {
            case .todo: return Theme.Colors.accent
            case .note: return Theme.Colors.work
            case .idea: return Theme.Colors.hobby
            case .reminder: return Theme.Colors.priorityHigh
            case .bookmark: return .pink
            default: return Theme.Colors.accent
            }
        }()

        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedType = type
                showTypeSelector = false
            }
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: type.iconName)
                    .font(.system(size: 12))
                Text(type.displayName)
                    .font(Theme.Typography.caption)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .background(isSelected ? color.opacity(0.12) : Color.clear)
            .foregroundStyle(isSelected ? color : Theme.Colors.secondaryText)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
        }
        .buttonStyle(.plain)
    }

    private var canSubmit: Bool {
        !appState.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitInput() {
        guard canSubmit else { return }
        Task {
            await appState.processInput(appState.inputText, type: selectedType)
        }
    }
}

#Preview {
    InputView()
        .padding()
        .frame(width: 600)
        .environment(AppState())
}
