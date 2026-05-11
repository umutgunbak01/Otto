import SwiftUI

struct NoteRowView: View {
    @Environment(AppState.self) private var appState
    let note: Note
    var isSelected: Bool = false

    @State private var isHovered: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            // Title row
            HStack(spacing: Theme.Spacing.sm) {
                // Page icon
                Image(systemName: "doc.text")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.Colors.tertiaryText)

                Text(note.title)
                    .font(Theme.Typography.body)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Spacer()

                // Category badge
                Text(note.primaryCategory.rawValue)
                    .font(Theme.Typography.small)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(categoryColor.opacity(0.12))
                    .foregroundStyle(categoryColor)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
            }

            // Preview text
            if !note.content.isEmpty {
                Text(strippedNotePreview(note.content))
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .lineLimit(2)
                    .padding(.leading, 22) // Align with title
            }

            // Tags and meta
            HStack(spacing: Theme.Spacing.sm) {
                // Tags
                ForEach(appState.tags(for: note.domainTagIds).prefix(2)) { tag in
                    Text(tag.name)
                        .font(Theme.Typography.small)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.Colors.hoverTint)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                }

                Spacer()

                // Time ago
                Text(timeAgo(note.updatedAt))
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.tertiaryText)

                // Hover actions
                if isHovered {
                    Button {
                        Task {
                            await appState.deleteNote(note)
                        }
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

    private var categoryColor: Color {
        switch note.primaryCategory {
        case .work: return Theme.Colors.work
        case .personal: return Theme.Colors.personal
        case .hobby: return Theme.Colors.hobby
        }
    }

    private func timeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)

        if interval < 60 {
            return "Just now"
        } else if interval < 3600 {
            let mins = Int(interval / 60)
            return "\(mins)m ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        } else if interval < 604800 {
            let days = Int(interval / 86400)
            return "\(days)d ago"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return formatter.string(from: date)
        }
    }
}

#Preview {
    VStack(spacing: 2) {
        NoteRowView(note: Note(title: "Meeting Notes", content: "Discussed Q1 goals and priorities for the team.", primaryCategory: .work))
        NoteRowView(note: Note(title: "Learning SwiftUI", content: "Key concepts: Views, State, Bindings", primaryCategory: .personal), isSelected: true)
    }
    .environment(AppState())
    .padding()
    .frame(width: 300)
}
