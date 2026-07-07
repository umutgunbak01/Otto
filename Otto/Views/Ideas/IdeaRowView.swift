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
                    .font(Theme.Typography.monoSmall)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(statusTint)
                    .foregroundStyle(statusColor)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
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
                    .font(Theme.Typography.monoSmall)
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
                    .font(Theme.Typography.monoSmall)
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
        .ottoRow(isSelected: isSelected, isHovered: isHovered)
        #if os(macOS)
        .onHover { hovering in
            isHovered = hovering
        }
        #endif
    }

    private var statusColor: Color {
        switch idea.status {
        case .raw: return Theme.Colors.textDim
        case .researched: return Theme.Colors.amber
        case .validated: return Theme.Colors.green
        case .archived: return Theme.Colors.tertiaryText
        }
    }

    private var statusTint: Color {
        switch idea.status {
        case .raw: return Theme.Colors.hoverTint
        case .researched: return Theme.Colors.tintAmber
        case .validated: return Theme.Colors.tintGreen
        case .archived: return Theme.Colors.hoverTint
        }
    }

    private var categoryColor: Color {
        switch idea.primaryCategory {
        case .work: return Theme.Colors.accentText
        case .personal: return Theme.Colors.green
        case .hobby: return Theme.Colors.violet
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
