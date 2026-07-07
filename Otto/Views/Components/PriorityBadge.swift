import SwiftUI

struct PriorityBadge: View {
    let priority: Todo.Priority
    var showLabel: Bool = true
    var isCompact: Bool = false
    var animated: Bool = false

    @State private var isVisible = false

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: iconName)
                .font(.system(size: isCompact ? 9 : 10))

            if showLabel {
                Text(priority.displayName)
                    .font(Theme.Typography.monoSmall)
            }
        }
        .padding(.horizontal, isCompact ? Theme.Spacing.sm : Theme.Spacing.md)
        .padding(.vertical, isCompact ? 2 : Theme.Spacing.xs)
        .background(chipBackground)
        .foregroundStyle(priorityColor)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .scaleEffect(animated && !isVisible ? 0.8 : 1.0)
        .opacity(animated && !isVisible ? 0 : 1)
        .onAppear {
            if animated {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                    isVisible = true
                }
            }
        }
    }

    private var iconName: String {
        switch priority {
        case .low: return "flag"
        case .medium: return "flag.fill"
        case .high: return "flag.fill"
        case .urgent: return "flag.fill"
        }
    }

    private var priorityColor: Color {
        switch priority {
        case .low: return Theme.Colors.textDim
        case .medium: return Theme.Colors.accentText
        case .high: return Theme.Colors.amber
        case .urgent: return Theme.Colors.red
        }
    }

    private var chipBackground: Color {
        switch priority {
        case .low: return Theme.Colors.hoverTint
        case .medium: return Theme.Colors.selectTint
        case .high: return Theme.Colors.tintAmber
        case .urgent: return Theme.Colors.tintRed
        }
    }
}

// Inline priority indicator (just the icon, for row views)
struct PriorityIndicator: View {
    let priority: Todo.Priority

    var body: some View {
        Image(systemName: iconName)
            .font(.system(size: 10))
            .foregroundStyle(priorityColor)
    }

    private var iconName: String {
        switch priority {
        case .low: return "flag"
        case .medium: return "flag.fill"
        case .high: return "flag.fill"
        case .urgent: return "flag.fill"
        }
    }

    private var priorityColor: Color {
        switch priority {
        case .low: return Theme.Colors.priorityLow
        case .medium: return Theme.Colors.priorityMedium
        case .high: return Theme.Colors.priorityHigh
        case .urgent: return Theme.Colors.priorityUrgent
        }
    }
}

#Preview {
    VStack(spacing: Theme.Spacing.lg) {
        // Full badges
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Priority Badges")
                .font(Theme.Typography.headline)

            HStack(spacing: Theme.Spacing.sm) {
                PriorityBadge(priority: .low)
                PriorityBadge(priority: .medium)
                PriorityBadge(priority: .high)
                PriorityBadge(priority: .urgent)
            }
        }

        Divider()

        // Compact badges
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Compact Badges")
                .font(Theme.Typography.headline)

            HStack(spacing: Theme.Spacing.sm) {
                PriorityBadge(priority: .low, isCompact: true)
                PriorityBadge(priority: .high, isCompact: true)
            }
        }

        Divider()

        // Icon-only indicators
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Priority Indicators")
                .font(Theme.Typography.headline)

            HStack(spacing: Theme.Spacing.md) {
                PriorityIndicator(priority: .low)
                PriorityIndicator(priority: .medium)
                PriorityIndicator(priority: .high)
                PriorityIndicator(priority: .urgent)
            }
        }
    }
    .padding()
}
