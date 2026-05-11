import SwiftUI

struct IdeaRowView: View {
    @Environment(AppState.self) private var appState
    let idea: Idea
    var isSelected: Bool = false

    @State private var isHovered: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            // Title row
            HStack(spacing: Theme.Spacing.sm) {
                // Lightbulb icon
                Image(systemName: "lightbulb")
                    .font(.system(size: 14))
                    .foregroundStyle(statusColor)

                Text(idea.title)
                    .font(Theme.Typography.body)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Spacer()

                // Status badge
                Text(idea.status.rawValue)
                    .font(Theme.Typography.small)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(statusColor.opacity(0.12))
                    .foregroundStyle(statusColor)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
            }

            // Preview text
            if !idea.content.isEmpty {
                Text(idea.content)
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .lineLimit(2)
                    .padding(.leading, 22)
            }

            // Tags and meta
            HStack(spacing: Theme.Spacing.sm) {
                // Category
                Text(idea.primaryCategory.rawValue)
                    .font(Theme.Typography.small)
                    .foregroundStyle(categoryColor)

                // Research/Validation prompt indicators
                if !idea.researchPrompt.isEmpty {
                    HStack(spacing: 2) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 9))
                        Text("Research Prompt")
                    }
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.work)
                }

                if !idea.validationPrompt.isEmpty {
                    HStack(spacing: 2) {
                        Image(systemName: "checkmark.seal")
                            .font(.system(size: 9))
                        Text("Validation Prompt")
                    }
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.personal)
                }

                Spacer()

                // Time ago
                Text(timeAgo(idea.updatedAt))
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.tertiaryText)

                // Hover actions
                if isHovered {
                    Button {
                        Task { await appState.deleteIdea(idea) }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Colors.secondaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, 22)
        }
        .padding(Theme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(isSelected ? Theme.Colors.accent.opacity(0.08) :
                      isHovered ? Theme.Colors.borderSubtle.opacity(0.5) : Color.clear)
        )
        #if os(macOS)
        .onHover { hovering in
            isHovered = hovering
        }
        #endif
    }

    private var statusColor: Color {
        switch idea.status {
        case .raw: return Theme.Colors.tertiaryText
        case .researched: return Theme.Colors.work
        case .validated: return Theme.Colors.personal
        case .archived: return Theme.Colors.priorityHigh
        }
    }

    private var categoryColor: Color {
        switch idea.primaryCategory {
        case .work: return Theme.Colors.work
        case .personal: return Theme.Colors.personal
        case .hobby: return Theme.Colors.hobby
        }
    }

    private func timeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "Just now" }
        else if interval < 3600 { return "\(Int(interval / 60))m ago" }
        else if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        else if interval < 604800 { return "\(Int(interval / 86400))d ago" }
        else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return formatter.string(from: date)
        }
    }
}

#Preview {
    VStack(spacing: 2) {
        IdeaRowView(idea: Idea(title: "AI-powered habit tracker", content: "An app that uses AI to suggest optimal times", primaryCategory: .personal, status: .researched, researchPrompt: "Research prompt here"))
        IdeaRowView(idea: Idea(title: "New feature idea", content: "Add dark mode support", primaryCategory: .work, status: .raw), isSelected: true)
    }
    .environment(AppState())
    .padding()
    .frame(width: 300)
}
