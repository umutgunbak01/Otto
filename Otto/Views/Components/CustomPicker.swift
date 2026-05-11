import SwiftUI

// MARK: - Elegant Dropdown Picker

struct DropdownPicker<T: Hashable & CustomStringConvertible>: View {
    let label: String?
    let icon: String?
    @Binding var selection: T
    let options: [T]
    var color: ((T) -> Color)? = nil

    @State private var isExpanded: Bool = false
    @State private var isHovered: Bool = false

    var body: some View {
        Menu {
            ForEach(0..<options.count, id: \.self) { index in
                let option = options[index]
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selection = option
                    }
                } label: {
                    HStack {
                        if let colorFn = color {
                            Circle()
                                .fill(colorFn(option))
                                .frame(width: 8, height: 8)
                        }
                        Text(option.description)
                        if option == selection {
                            Spacer()
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .semibold))
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }

                if let colorFn = color {
                    Circle()
                        .fill(colorFn(selection))
                        .frame(width: 8, height: 8)
                }

                Text(selection.description)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.text)

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .fill(isHovered ? Theme.Colors.borderSubtle : Theme.Colors.borderSubtle.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .strokeBorder(Theme.Colors.hoverTint, lineWidth: 1)
            )
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .onHover { hovering in
            isHovered = hovering
        }
        #endif
    }
}

// MARK: - Segmented Pill Picker for Todo Filter

struct TodoFilterPicker: View {
    @Binding var selection: TodoListView.TodoFilter
    var accentColor: Color = Theme.Colors.accent

    var body: some View {
        HStack(spacing: 2) {
            pillButton(for: .active)
            pillButton(for: .completed)
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Colors.borderSubtle.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .strokeBorder(Theme.Colors.borderSubtle, lineWidth: 1)
        )
    }

    private func pillButton(for option: TodoListView.TodoFilter) -> some View {
        let isSelected = selection == option
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selection = option
            }
        } label: {
            Text(option.rawValue)
                .font(Theme.Typography.caption)
                .fontWeight(isSelected ? .medium : .regular)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .fill(isSelected ? accentColor.opacity(0.15) : Color.clear)
                )
                .foregroundStyle(isSelected ? accentColor : Theme.Colors.secondaryText)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Status Pill Picker (for Idea status)

struct IdeaStatusPicker: View {
    @Binding var selection: Idea.Status

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            statusButton(for: .raw)
            statusButton(for: .researched)
            statusButton(for: .validated)
            statusButton(for: .archived)
        }
    }

    private func statusButton(for status: Idea.Status) -> some View {
        let isSelected = selection == status
        let color = colorFor(status)

        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selection = status
            }
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)

                Text(status.rawValue)
                    .font(Theme.Typography.caption)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.full)
                    .fill(isSelected ? color.opacity(0.12) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.full)
                    .strokeBorder(isSelected ? color.opacity(0.3) : Theme.Colors.hoverTint, lineWidth: 1)
            )
            .foregroundStyle(isSelected ? color : Theme.Colors.secondaryText)
        }
        .buttonStyle(.plain)
    }

    private func colorFor(_ status: Idea.Status) -> Color {
        switch status {
        case .raw: return Theme.Colors.tertiaryText
        case .researched: return Theme.Colors.work
        case .validated: return Theme.Colors.personal
        case .archived: return Theme.Colors.priorityHigh
        }
    }
}

// MARK: - Category Selector (Work/Personal/Hobby)

struct CategorySelector: View {
    @Binding var selection: PrimaryCategory

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            categoryButton(for: .work)
            categoryButton(for: .personal)
            categoryButton(for: .hobby)
        }
    }

    private func categoryButton(for category: PrimaryCategory) -> some View {
        let isSelected = selection == category
        let color = colorFor(category)

        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selection = category
            }
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)

                Text(category.rawValue)
                    .font(Theme.Typography.caption)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .fill(isSelected ? color.opacity(0.1) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .strokeBorder(isSelected ? color.opacity(0.3) : Theme.Colors.borderSubtle, lineWidth: 1)
            )
            .foregroundStyle(isSelected ? color : Theme.Colors.secondaryText)
        }
        .buttonStyle(.plain)
    }

    private func colorFor(_ category: PrimaryCategory) -> Color {
        switch category {
        case .work: return Theme.Colors.work
        case .personal: return Theme.Colors.personal
        case .hobby: return Theme.Colors.hobby
        }
    }
}

// MARK: - Bookmark Filter Picker

struct BookmarkFilterPicker: View {
    @Binding var selection: BookmarkListView.BookmarkFilter
    var accentColor: Color = Theme.Colors.accent

    var body: some View {
        HStack(spacing: 2) {
            pillButton(for: .all)
            pillButton(for: .unread)
            pillButton(for: .read)
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Colors.borderSubtle.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .strokeBorder(Theme.Colors.borderSubtle, lineWidth: 1)
        )
    }

    private func pillButton(for option: BookmarkListView.BookmarkFilter) -> some View {
        let isSelected = selection == option
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selection = option
            }
        } label: {
            Text(option.rawValue)
                .font(Theme.Typography.caption)
                .fontWeight(isSelected ? .medium : .regular)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .fill(isSelected ? accentColor.opacity(0.15) : Color.clear)
                )
                .foregroundStyle(isSelected ? accentColor : Theme.Colors.secondaryText)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Bookmark Media Type Picker

struct BookmarkMediaTypePicker: View {
    @Binding var selection: Bookmark.MediaType

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            mediaTypeButton(for: .readLater)
            mediaTypeButton(for: .listenLater)
            mediaTypeButton(for: .watchLater)
        }
    }

    private func mediaTypeButton(for mediaType: Bookmark.MediaType) -> some View {
        let isSelected = selection == mediaType
        let color = colorFor(mediaType)

        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selection = mediaType
            }
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: mediaType.iconName)
                    .font(.system(size: 10))

                Text(mediaType.rawValue)
                    .font(Theme.Typography.caption)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .fill(isSelected ? color.opacity(0.1) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .strokeBorder(isSelected ? color.opacity(0.3) : Theme.Colors.borderSubtle, lineWidth: 1)
            )
            .foregroundStyle(isSelected ? color : Theme.Colors.secondaryText)
        }
        .buttonStyle(.plain)
    }

    private func colorFor(_ mediaType: Bookmark.MediaType) -> Color {
        switch mediaType {
        case .readLater: return Theme.Colors.work
        case .listenLater: return Theme.Colors.hobby
        case .watchLater: return Theme.Colors.priorityHigh
        }
    }
}

// MARK: - Priority Selector

struct PrioritySelector: View {
    @Binding var selection: Todo.Priority

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            priorityButton(for: .low)
            priorityButton(for: .medium)
            priorityButton(for: .high)
            priorityButton(for: .urgent)
        }
    }

    private func priorityButton(for priority: Todo.Priority) -> some View {
        let isSelected = selection == priority
        let color = colorFor(priority)

        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selection = priority
            }
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: iconFor(priority))
                    .font(.system(size: 10))

                Text(priority.displayName)
                    .font(Theme.Typography.caption)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .fill(isSelected ? color.opacity(0.12) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .strokeBorder(isSelected ? color.opacity(0.4) : Theme.Colors.borderSubtle, lineWidth: 1)
            )
            .foregroundStyle(isSelected ? color : Theme.Colors.secondaryText)
        }
        .buttonStyle(.plain)
    }

    private func colorFor(_ priority: Todo.Priority) -> Color {
        switch priority {
        case .low: return Theme.Colors.priorityLow
        case .medium: return Theme.Colors.priorityMedium
        case .high: return Theme.Colors.priorityHigh
        case .urgent: return Theme.Colors.priorityUrgent
        }
    }

    private func iconFor(_ priority: Todo.Priority) -> String {
        switch priority {
        case .low: return "flag"
        case .medium: return "flag.fill"
        case .high: return "flag.fill"
        case .urgent: return "exclamationmark.triangle.fill"
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: Theme.Spacing.xl) {
        // Category selector
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Category")
                .font(Theme.Typography.headline)
            CategorySelector(selection: .constant(.work))
        }

        Divider()

        // Priority selector
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Priority")
                .font(Theme.Typography.headline)
            PrioritySelector(selection: .constant(.high))
        }

        Divider()

        // Status picker
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Status")
                .font(Theme.Typography.headline)
            IdeaStatusPicker(selection: .constant(.researched))
        }
    }
    .padding()
    .frame(width: 500)
}
