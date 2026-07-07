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
                .font(Theme.Typography.monoSmall)

            if isRemovable && isHovered {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .onTapGesture {
                        onRemove?()
                    }
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Theme.Colors.hoverTint)
        .foregroundStyle(Theme.Colors.textDim)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        #if os(macOS)
        .onHover { hovering in
            isHovered = hovering
        }
        #endif
    }

}

// Category chip variant for primary categories
struct CategoryChipView: View {
    let category: PrimaryCategory
    var isCompact: Bool = false

    var body: some View {
        Text(category.rawValue)
            .font(Theme.Typography.monoSmall)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(categoryColor.opacity(0.12))
            .foregroundStyle(categoryColor)
            .clipShape(RoundedRectangle(cornerRadius: 4))
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
