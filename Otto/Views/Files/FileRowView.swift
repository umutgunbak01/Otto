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
            typeBadge

            // File info
            VStack(alignment: .leading, spacing: 4) {
                Text(file.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.Colors.text)
                    .lineLimit(1)

                HStack(spacing: 7) {
                    Text(file.formattedSize)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.Colors.tertiaryText)

                    if file.extractedText != nil {
                        Text("searchable")
                            .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                            .tracking(0.5)
                            .foregroundStyle(Theme.Colors.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Theme.Colors.tintGreen))
                    }

                    if !file.tags.isEmpty {
                        Text(file.tags.prefix(2).joined(separator: ", "))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.Colors.accentText)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            Text(formattedDate)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.Colors.tertiaryText)

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
        .padding(.vertical, 11)
        .padding(.horizontal, Theme.Spacing.md)
        .background(
            // Quiet list row (mockup .lrow) — no border, wash on hover,
            // teal tint while previewing.
            RoundedRectangle(cornerRadius: 11)
                .fill(
                    isSelected
                        ? Theme.Colors.selectTint
                        : (isHovered ? Theme.Colors.panel : Color.clear)
                )
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    // MARK: - Type badge

    /// 38pt extension badge — tinted wash in the type's canonical accent
    /// (FileType.color) with a mono extension label.
    private var typeBadge: some View {
        Text(file.fileExtension.uppercased())
            .font(.system(size: 8.5, weight: .medium, design: .monospaced))
            .tracking(0.5)
            .foregroundStyle(file.fileType.color)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, 3)
            .frame(width: 38, height: 38)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(file.fileType.color.opacity(0.10))
            )
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

        FileRowView(
            file: FileItem(
                name: "Product Screenshot",
                fileType: .image,
                fileExtension: "png",
                fileSize: 850_000
            )
        )

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
    .padding()
    .environment(AppState())
}
