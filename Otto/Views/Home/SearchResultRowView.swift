import SwiftUI

struct SearchResultRowView: View {
    let result: UniversalSearchResult
    let searchQuery: String
    var isSelectionMode: Bool = false
    var isSelected: Bool = false
    var onSelect: (() -> Void)?
    var onToggleSelection: ((_ withShift: Bool) -> Void)?

    @State private var isHovered: Bool = false

    var body: some View {
        #if os(macOS)
        rowContent
            .simultaneousGesture(
                TapGesture()
                    .modifiers(.shift)
                    .onEnded { _ in
                        if isSelectionMode {
                            onToggleSelection?(true)
                        }
                    }
            )
            .onTapGesture {
                if isSelectionMode {
                    onToggleSelection?(false)
                } else {
                    onSelect?()
                }
            }
        #else
        rowContent
            .onTapGesture {
                if isSelectionMode {
                    onToggleSelection?(false)
                } else {
                    onSelect?()
                }
            }
        #endif
    }

    private var rowContent: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            // Selection checkbox (in selection mode)
            if isSelectionMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? Theme.Colors.accent : Theme.Colors.tertiaryText)
            }

            // Content type icon with color
            contentTypeIcon

            // Main content
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                // Title with highlighted search match
                highlightedTitle

                // Subtitle (category, date, etc.)
                if let subtitle = result.subtitle {
                    Text(subtitle)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .lineLimit(1)
                }

                // Snippet if available
                if let snippet = result.snippet, !snippet.isEmpty {
                    highlightedSnippet(snippet)
                }
            }

            Spacer()

            // Date and archived badge
            VStack(alignment: .trailing, spacing: Theme.Spacing.xs) {
                Text(formattedDate)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.tertiaryText)

                if result.isArchived {
                    archivedBadge
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(isSelected ? Theme.Colors.accent.opacity(0.08) : (isHovered ? Theme.Colors.borderSubtle.opacity(0.5) : Color.clear))
        )
        .contentShape(Rectangle())
        #if os(macOS)
        .onHover { hovering in
            isHovered = hovering
        }
        #endif
    }

    // MARK: - Content Type Icon

    private var contentTypeIcon: some View {
        Image(systemName: result.contentType.iconName)
            .font(.system(size: 14))
            .foregroundStyle(result.contentType.color)
            .frame(width: 28, height: 28)
            .background(result.contentType.color.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
    }

    // MARK: - Highlighted Title

    private var highlightedTitle: some View {
        highlightText(result.title, query: searchQuery)
            .font(Theme.Typography.headline)
            .foregroundStyle(result.isArchived ? Theme.Colors.secondaryText : Theme.Colors.text)
            .lineLimit(1)
    }

    // MARK: - Highlighted Snippet

    private func highlightedSnippet(_ snippet: String) -> some View {
        highlightText(snippet, query: searchQuery)
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Colors.tertiaryText)
            .lineLimit(2)
    }

    // MARK: - Highlight Text

    private func highlightText(_ text: String, query: String) -> Text {
        guard !query.isEmpty else {
            return Text(text)
        }

        let lowercaseText = text.lowercased()
        let lowercaseQuery = query.lowercased()

        guard let range = lowercaseText.range(of: lowercaseQuery) else {
            return Text(text)
        }

        let beforeRange = text.startIndex..<range.lowerBound
        let matchRange = range.lowerBound..<range.upperBound
        let afterRange = range.upperBound..<text.endIndex

        let before = String(text[beforeRange])
        let match = String(text[matchRange])
        let after = String(text[afterRange])

        return Text(before) +
            Text(match)
                .foregroundColor(Theme.Colors.accent)
                .fontWeight(.semibold) +
            Text(after)
    }

    // MARK: - Formatted Date

    private var formattedDate: String {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let dateDay = calendar.startOfDay(for: result.date)

        if dateDay == today {
            return "Today"
        } else if dateDay == calendar.date(byAdding: .day, value: -1, to: today) {
            return "Yesterday"
        } else if dateDay == calendar.date(byAdding: .day, value: 1, to: today) {
            return "Tomorrow"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "d MMM"
            return formatter.string(from: result.date)
        }
    }

    // MARK: - Archived Badge

    private var archivedBadge: some View {
        Text(archivedLabel)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(Theme.Colors.tertiaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.Colors.borderSubtle)
            .clipShape(Capsule())
    }

    private var archivedLabel: String {
        switch result.contentType {
        case .todo: return "Completed"
        case .reminder: return "Triggered"
        case .bookmark: return "Read"
        case .email: return "Read"
        case .idea: return "Archived"
        default: return "Archived"
        }
    }
}

#Preview {
    VStack(spacing: 0) {
        SearchResultRowView(
            result: UniversalSearchResult(
                id: UUID(),
                contentType: .todo,
                title: "Review project proposal for Q1",
                subtitle: "Due Tomorrow",
                snippet: "Need to review the quarterly proposal and provide feedback",
                date: Date(),
                isArchived: false
            ),
            searchQuery: "project"
        )

        Divider()

        SearchResultRowView(
            result: UniversalSearchResult(
                id: UUID(),
                contentType: .note,
                title: "Meeting Notes - Product Sync",
                subtitle: "Work",
                snippet: "Discussed the new feature roadmap and timeline",
                date: Date().addingTimeInterval(-86400),
                isArchived: false
            ),
            searchQuery: "meeting"
        )

        Divider()

        SearchResultRowView(
            result: UniversalSearchResult(
                id: UUID(),
                contentType: .email,
                title: "Re: Partnership Proposal",
                subtitle: "john@example.com",
                snippet: "Thank you for reaching out about the partnership...",
                date: Date().addingTimeInterval(-172800),
                isArchived: true
            ),
            searchQuery: "partnership"
        )
    }
    .frame(width: 500)
    #if os(macOS)
    .background(Theme.Colors.background)
    #else
    .background(Color(uiColor: .systemBackground))
    #endif
}
