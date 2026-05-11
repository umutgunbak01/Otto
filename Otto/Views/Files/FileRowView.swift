import SwiftUI

struct FileRowView: View {
    @Environment(AppState.self) private var appState
    let file: FileItem
    var isSelected: Bool = false
    /// Called after the file is deleted so the parent list can clear any
    /// stale `previewingFile` / selection state pointing at it.
    var onDelete: (() -> Void)? = nil

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            // File type icon
            fileTypeIcon

            // File info
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(file.name)
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.Colors.text)
                    .lineLimit(1)

                HStack(spacing: Theme.Spacing.sm) {
                    Text(file.fileType.displayName)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.secondaryText)

                    Text("•")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.tertiaryText)

                    Text(file.formattedSize)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.secondaryText)

                    if !file.tags.isEmpty {
                        Text("•")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.tertiaryText)

                        Text(file.tags.prefix(2).joined(separator: ", "))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.accent)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            // Date + "Searchable" badge
            VStack(alignment: .trailing, spacing: Theme.Spacing.xs) {
                Text(formattedDate)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.tertiaryText)

                if file.extractedText != nil {
                    Text("Searchable")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.Colors.personal)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.Colors.personal.opacity(0.1))
                        .clipShape(Capsule())
                }
            }

            // Hover-revealed delete button (mirrors NoteRowView).
            if isHovered {
                Button {
                    let captured = file
                    onDelete?()
                    Task { await appState.deleteFile(captured) }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .padding(.leading, Theme.Spacing.sm)
                }
                .buttonStyle(.plain)
                .help("Delete file")
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(isSelected ? Theme.Colors.accent.opacity(0.1) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    // MARK: - File Type Icon

    private var fileTypeIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(iconBackgroundColor.opacity(0.12))

            VStack(spacing: 2) {
                Image(systemName: iconSystemName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(iconBackgroundColor)

                Text(".\(file.fileExtension.uppercased())")
                    .font(.system(size: 7, weight: .bold, design: .rounded))
                    .foregroundStyle(iconBackgroundColor.opacity(0.8))
            }
        }
        .frame(width: 40, height: 40)
    }

    private var iconSystemName: String {
        switch file.fileType {
        case .csv:
            return "tablecells"
        case .excel:
            return "tablecells.fill"
        case .image:
            // Show different icon based on extension
            switch file.fileExtension.lowercased() {
            case "png": return "photo"
            case "jpg", "jpeg": return "photo.fill"
            case "heic": return "livephoto"
            default: return "photo"
            }
        case .pdf:
            return "doc.richtext.fill"
        case .text:
            return "doc.text"
        }
    }

    private var iconBackgroundColor: Color {
        switch file.fileType {
        case .csv: return Theme.Colors.green
        case .excel: return Color(red: 0.13, green: 0.55, blue: 0.13) // Darker green for Excel
        case .image: return Theme.Colors.cyan
        case .pdf: return Theme.Colors.red
        case .text: return Theme.Colors.secondaryText
        }
    }

    // MARK: - Formatted Date

    private var formattedDate: String {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let dateDay = calendar.startOfDay(for: file.updatedAt)

        if dateDay == today {
            return "Today"
        } else if dateDay == calendar.date(byAdding: .day, value: -1, to: today) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "d MMM yyyy"
            return formatter.string(from: file.updatedAt)
        }
    }
}

#Preview {
    VStack(spacing: 0) {
        FileRowView(
            file: FileItem(
                name: "Sales Report Q4",
                fileType: .excel,
                fileExtension: "xlsx",
                fileSize: 2_500_000,
                tags: ["Finance", "2024"]
            )
        )

        Divider()

        FileRowView(
            file: FileItem(
                name: "Project Documentation",
                fileType: .pdf,
                fileExtension: "pdf",
                fileSize: 5_200_000,
                extractedText: "Some extracted content..."
            ),
            isSelected: true
        )

        Divider()

        FileRowView(
            file: FileItem(
                name: "Product Screenshot",
                fileType: .image,
                fileExtension: "png",
                fileSize: 850_000
            )
        )

        Divider()

        FileRowView(
            file: FileItem(
                name: "Customer Data Export",
                fileType: .csv,
                fileExtension: "csv",
                fileSize: 125_000,
                extractedText: "name,email,phone..."
            )
        )
    }
    .frame(width: 500)
    .background(Theme.Colors.background)
    .environment(AppState())
}
