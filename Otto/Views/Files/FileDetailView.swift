import SwiftUI
import QuickLook
#if canImport(PDFKit)
import PDFKit
#endif
#if os(macOS)
import Quartz
#endif

struct FileDetailView: View {
    @Environment(AppState.self) private var appState
    let file: FileItem

    @State private var editingName: String = ""
    @State private var editingNotes: String = ""
    @State private var editingTags: String = ""
    @State private var isEditing: Bool = false
    @State private var showingQuickLook: Bool = false
    @State private var previewURL: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                // Header with file icon and name
                header

                OttoDivider()

                // Preview section
                previewSection

                OttoDivider()

                // File info
                infoSection

                OttoDivider()

                // Notes section
                notesSection

                // Tags section
                tagsSection

                Spacer(minLength: Theme.Spacing.xl)
            }
            .padding(Theme.Spacing.xl)
        }
        .background(Theme.Colors.secondaryBackground)
        .onAppear {
            editingName = file.name
            editingNotes = file.notes
            editingTags = file.tags.joined(separator: ", ")
            loadPreviewURL()
        }
        .onChange(of: file.id) { _, _ in
            editingName = file.name
            editingNotes = file.notes
            editingTags = file.tags.joined(separator: ", ")
            loadPreviewURL()
        }
        #if os(macOS)
        .sheet(isPresented: $showingQuickLook) {
            if let url = previewURL {
                QuickLookPreview(url: url)
                    .frame(minWidth: 600, minHeight: 500)
            }
        }
        #endif
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Theme.Spacing.lg) {
            // File icon
            fileIcon
                .frame(width: 60, height: 60)

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                if isEditing {
                    TextField("File name", text: $editingName)
                        .font(Theme.Typography.title)
                        .textFieldStyle(.plain)
                } else {
                    Text(file.name)
                        .font(Theme.Typography.title)
                        .lineLimit(2)
                }

                Text(".\(file.fileExtension) • \(file.formattedSize)")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }

            Spacer()

            // Action buttons
            HStack(spacing: Theme.Spacing.sm) {
                if isEditing {
                    Button("Cancel") {
                        cancelEditing()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.Colors.secondaryText)

                    Button("Save") {
                        saveChanges()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        isEditing = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                    #if os(macOS)
                    .help("Edit file details")
                    #endif

                    Button {
                        openInFinder()
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                    #if os(macOS)
                    .help("Open in Finder")
                    #endif

                    Button {
                        showingQuickLook = true
                    } label: {
                        Image(systemName: "eye")
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                    #if os(macOS)
                    .help("Quick Look")
                    #endif

                    Button(role: .destructive) {
                        let captured = file
                        Task { await appState.deleteFile(captured) }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 14))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    #if os(macOS)
                    .help("Delete file")
                    #endif
                }
            }
        }
    }

    // MARK: - File Icon

    private var fileIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(
                    LinearGradient(
                        colors: [iconColor.opacity(0.15), iconColor.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            VStack(spacing: 4) {
                Image(systemName: fileIconName)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(iconColor)

                Text(".\(file.fileExtension.uppercased())")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(iconColor.opacity(0.9))
            }
        }
    }

    private var fileIconName: String {
        switch file.fileType {
        case .csv:
            return "tablecells"
        case .excel:
            return "tablecells.fill"
        case .image:
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

    private var iconColor: Color {
        switch file.fileType {
        case .csv: return .green
        case .excel: return Color(red: 0.13, green: 0.55, blue: 0.13)
        case .image: return .blue
        case .pdf: return .red
        case .text: return .secondary
        }
    }

    // MARK: - Preview Section

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Preview")
                .font(Theme.Typography.headline)

            Group {
                switch file.fileType {
                case .image:
                    imagePreview
                case .pdf:
                    pdfPreview
                case .csv:
                    csvPreview
                case .excel:
                    excelPreview
                case .text:
                    csvPreview  // Plain text uses the same scrollable text viewer.
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 300)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .stroke(Theme.Colors.border, lineWidth: 1)
            )
        }
    }

    private var imagePreview: some View {
        Group {
            #if os(macOS)
            if let url = previewURL, let nsImage = NSImage(contentsOf: url) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    .padding(Theme.Spacing.md)
            } else {
                placeholderPreview(icon: "photo", message: "Unable to load image")
            }
            #else
            if let url = previewURL, let data = try? Data(contentsOf: url), let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    .padding(Theme.Spacing.md)
            } else {
                placeholderPreview(icon: "photo", message: "Unable to load image")
            }
            #endif
        }
    }

    private var pdfPreview: some View {
        Group {
            #if canImport(PDFKit)
            if let url = previewURL {
                PDFKitView(url: url)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
            } else {
                placeholderPreview(icon: "doc.richtext", message: "Unable to load PDF")
            }
            #else
            placeholderPreview(icon: "doc.richtext", message: "PDF preview not available")
            #endif
        }
    }

    private var csvPreview: some View {
        Group {
            if let text = csvContent, !text.isEmpty {
                CSVTableView(csvText: text)
            } else {
                placeholderPreview(icon: "tablecells", message: "Unable to load CSV content")
            }
        }
    }

    private var csvContent: String? {
        // First try extractedText
        if let text = file.extractedText, !text.isEmpty {
            return text
        }
        // Fall back to reading from file directly
        guard let url = previewURL else { return nil }
        if let utf8Content = try? String(contentsOf: url, encoding: .utf8) {
            return utf8Content
        }
        return try? String(contentsOf: url, encoding: .isoLatin1)
    }

    private var excelPreview: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Image(systemName: "tablecells.fill")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(Color(red: 0.13, green: 0.55, blue: 0.13))

            VStack(spacing: Theme.Spacing.sm) {
                Text("Excel Spreadsheet")
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.Colors.text)

                Text(".\(file.fileExtension.uppercased()) • \(file.formattedSize)")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }

            Button {
                showingQuickLook = true
            } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "eye")
                    Text("Open with Quick Look")
                }
                .font(Theme.Typography.body)
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.sm)
                .background(Color(red: 0.13, green: 0.55, blue: 0.13))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func placeholderPreview(icon: String, message: String) -> some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(Theme.Colors.tertiaryText)

            Text(message)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Info Section

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Information")
                .font(Theme.Typography.headline)

            Grid(alignment: .leading, horizontalSpacing: Theme.Spacing.xl, verticalSpacing: Theme.Spacing.sm) {
                GridRow {
                    Text("Type")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.secondaryText)
                    Text(file.fileType.displayName)
                        .font(Theme.Typography.body)
                }

                GridRow {
                    Text("Extension")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.secondaryText)
                    Text(".\(file.fileExtension)")
                        .font(Theme.Typography.body)
                }

                GridRow {
                    Text("Size")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.secondaryText)
                    Text(file.formattedSize)
                        .font(Theme.Typography.body)
                }

                GridRow {
                    Text("Added")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.secondaryText)
                    Text(formatDate(file.createdAt))
                        .font(Theme.Typography.body)
                }

                GridRow {
                    Text("Modified")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.secondaryText)
                    Text(formatDate(file.updatedAt))
                        .font(Theme.Typography.body)
                }

                if file.extractedText != nil {
                    GridRow {
                        Text("Searchable")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.secondaryText)
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Theme.Colors.personal)
                            Text("Text extracted for search")
                                .font(Theme.Typography.body)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Notes Section

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Notes")
                .font(Theme.Typography.headline)

            if isEditing {
                TextEditor(text: $editingNotes)
                    .font(Theme.Typography.body)
                    .frame(minHeight: 100)
                    .padding(Theme.Spacing.sm)
                    .background(Theme.Colors.borderSubtle.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
            } else if file.notes.isEmpty {
                Text("No notes added")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .italic()
            } else {
                Text(file.notes)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.text)
            }
        }
    }

    // MARK: - Tags Section

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Tags")
                .font(Theme.Typography.headline)

            if isEditing {
                TextField("Enter tags separated by commas", text: $editingTags)
                    .textFieldStyle(.plain)
                    .font(Theme.Typography.body)
                    .padding(Theme.Spacing.sm)
                    .background(Theme.Colors.borderSubtle.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
            } else if file.tags.isEmpty {
                Text("No tags")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .italic()
            } else {
                FlowLayout(spacing: Theme.Spacing.xs) {
                    ForEach(file.tags, id: \.self) { tag in
                        Text(tag)
                            .font(Theme.Typography.caption)
                            .padding(.horizontal, Theme.Spacing.sm)
                            .padding(.vertical, Theme.Spacing.xs)
                            .background(Theme.Colors.accent.opacity(0.1))
                            .foregroundStyle(Theme.Colors.accent)
                            .clipShape(Capsule())
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func loadPreviewURL() {
        Task {
            previewURL = await FileStorageService.shared.getFileURL(for: file)
        }
    }

    private func cancelEditing() {
        editingName = file.name
        editingNotes = file.notes
        editingTags = file.tags.joined(separator: ", ")
        isEditing = false
    }

    private func saveChanges() {
        var updatedFile = file
        updatedFile.name = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        updatedFile.notes = editingNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        updatedFile.tags = editingTags
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        Task {
            await appState.updateFile(updatedFile)
            await MainActor.run {
                appState.selectedFile = updatedFile
                isEditing = false
            }
        }
    }

    private func openInFinder() {
        guard let url = previewURL else { return }
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #endif
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - PDF View

#if canImport(PDFKit)
#if os(macOS)
struct PDFKitView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.document = PDFDocument(url: url)
        return pdfView
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document?.documentURL != url {
            nsView.document = PDFDocument(url: url)
        }
    }
}
#else
struct PDFKitView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.document = PDFDocument(url: url)
        return pdfView
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document?.documentURL != url {
            uiView.document = PDFDocument(url: url)
        }
    }
}
#endif
#endif

// MARK: - Quick Look

#if os(macOS)
struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let preview = QLPreviewView()
        preview.previewItem = url as QLPreviewItem
        return preview
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        nsView.previewItem = url as QLPreviewItem
    }
}
#endif

// MARK: - CSV Table View

struct CSVTableView: View {
    let csvText: String

    private var parsedData: [[String]] {
        let lines = csvText.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        return lines.map { line in
            parseCSVLine(line)
        }
    }

    private func parseCSVLine(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false

        for char in line {
            if char == "\"" {
                inQuotes.toggle()
            } else if char == "," && !inQuotes {
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(char)
            }
        }
        result.append(current.trimmingCharacters(in: .whitespaces))
        return result
    }

    private var headers: [String] {
        parsedData.first ?? []
    }

    private var rows: [[String]] {
        Array(parsedData.dropFirst())
    }

    private var columnCount: Int {
        parsedData.map { $0.count }.max() ?? 0
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                // Header row
                if !headers.isEmpty {
                    HStack(spacing: 0) {
                        ForEach(0..<columnCount, id: \.self) { colIndex in
                            Text(colIndex < headers.count ? headers[colIndex] : "")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.Colors.text)
                                .lineLimit(1)
                                .frame(minWidth: 80, maxWidth: 150, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(Theme.Colors.accent.opacity(0.1))
                        }
                    }

                    OttoDivider()
                }

                // Data rows (limit to first 50 for performance)
                ForEach(Array(rows.prefix(50).enumerated()), id: \.offset) { rowIndex, row in
                    HStack(spacing: 0) {
                        ForEach(0..<columnCount, id: \.self) { colIndex in
                            Text(colIndex < row.count ? row[colIndex] : "")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.Colors.text)
                                .lineLimit(2)
                                .frame(minWidth: 80, maxWidth: 150, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(rowIndex % 2 == 0 ? Color.clear : Theme.Colors.secondaryBackground.opacity(0.5))
                        }
                    }

                    if rowIndex < rows.prefix(50).count - 1 {
                        OttoDivider()
                            .opacity(0.5)
                    }
                }

                // Show indicator if truncated
                if rows.count > 50 {
                    HStack {
                        Spacer()
                        Text("Showing 50 of \(rows.count) rows")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.secondaryText)
                            .padding(Theme.Spacing.sm)
                        Spacer()
                    }
                }
            }
        }
        .padding(Theme.Spacing.sm)
    }
}

#Preview {
    FileDetailView(
        file: FileItem(
            name: "Sample Document",
            fileType: .pdf,
            fileExtension: "pdf",
            fileSize: 2_500_000,
            notes: "This is a sample document with some notes.",
            tags: ["Important", "Work", "2024"],
            extractedText: "Some extracted text content..."
        )
    )
    .environment(AppState())
    .frame(width: 500, height: 700)
}
