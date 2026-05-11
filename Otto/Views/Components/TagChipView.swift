import SwiftUI

struct TagChipView: View {
    let tag: DomainTag
    var isCompact: Bool = false
    var isRemovable: Bool = false
    var onRemove: (() -> Void)?

    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text(tag.name)
                .font(isCompact ? Theme.Typography.small : Theme.Typography.caption)

            if isRemovable && isHovered {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(tagColor.opacity(0.7))
                    .onTapGesture {
                        onRemove?()
                    }
            }
        }
        .padding(.horizontal, isCompact ? Theme.Spacing.sm : Theme.Spacing.md)
        .padding(.vertical, isCompact ? 2 : Theme.Spacing.xs)
        .background(tagColor.opacity(0.1))
        .foregroundStyle(tagColor)
        .overlay(
            Rectangle().stroke(tagColor.opacity(0.4), lineWidth: 1)
        )
        #if os(macOS)
        .onHover { hovering in
            isHovered = hovering
        }
        #endif
    }

    private var tagColor: Color {
        // Map common domain tags to theme-consistent colors
        let tagName = tag.name.lowercased()

        switch tagName {
        case "ai", "technical", "research":
            return Theme.Colors.cyan
        case "marketing", "communication", "design":
            return Theme.Colors.aiAccent
        case "creative", "learning", "hobby":
            return Theme.Colors.amber
        case "ops", "planning", "finance":
            return Theme.Colors.cyanDim
        case "health", "wellness":
            return Theme.Colors.green
        case "urgent", "important":
            return Theme.Colors.red
        default:
            // Stable mapping into the Otto palette based on tag name hash.
            let hash = abs(tag.name.hashValue)
            let colors: [Color] = [
                Theme.Colors.cyan,
                Theme.Colors.cyanDim,
                Theme.Colors.aiAccent,
                Theme.Colors.amber,
                Theme.Colors.green
            ]
            return colors[hash % colors.count]
        }
    }
}

// Category chip variant for primary categories
struct CategoryChipView: View {
    let category: PrimaryCategory
    var isCompact: Bool = false

    var body: some View {
        Text(category.rawValue)
            .font(isCompact ? Theme.Typography.small : Theme.Typography.caption)
            .padding(.horizontal, isCompact ? Theme.Spacing.sm : Theme.Spacing.md)
            .padding(.vertical, isCompact ? 2 : Theme.Spacing.xs)
            .background(categoryColor.opacity(0.1))
            .foregroundStyle(categoryColor)
            .overlay(
                Rectangle().stroke(categoryColor.opacity(0.4), lineWidth: 1)
            )
    }

    private var categoryColor: Color {
        switch category {
        case .work:     return Theme.Colors.cyan
        case .personal: return Theme.Colors.green
        case .hobby:    return Theme.Colors.amber
        }
    }
}

#Preview {
    VStack(spacing: Theme.Spacing.lg) {
        // Domain tags
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Domain Tags")
                .font(Theme.Typography.headline)

            HStack(spacing: Theme.Spacing.sm) {
                TagChipView(tag: DomainTag(name: "AI"))
                TagChipView(tag: DomainTag(name: "Marketing"))
                TagChipView(tag: DomainTag(name: "Technical"), isCompact: true)
            }

            HStack(spacing: Theme.Spacing.sm) {
                TagChipView(tag: DomainTag(name: "Research"), isRemovable: true) {}
                TagChipView(tag: DomainTag(name: "Design"))
            }
        }

        Divider()

        // Category chips
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Category Chips")
                .font(Theme.Typography.headline)

            HStack(spacing: Theme.Spacing.sm) {
                CategoryChipView(category: .work)
                CategoryChipView(category: .personal)
                CategoryChipView(category: .hobby)
            }
        }
    }
    .padding()
}
