import SwiftUI
import QuickLook
#if canImport(PDFKit)
import PDFKit
#endif
#if os(macOS)
import Quartz
#endif

struct FilePreviewPopup: View {
    @Environment(AppState.self) private var appState
    let file: FileItem
    var onClose: (() -> Void)?

    @State private var previewURL: URL?
    @State private var loadedText: String?
    @State private var textLoadFinished = false

    // Parsed .xlsx workbook (agent-created or imported). nil while loading;
    // `xlsxLoadFinished` + nil = unparseable → icon/open-externally fallback.
    @State private var xlsxSheets: [XLSXReader.Sheet]?
    @State private var xlsxLoadFinished = false
    @State private var selectedSheet = 0

    var body: some View {
        VStack(spacing: 0) {
            // Minimal header
            header

            OttoDivider()

            // Preview fills all available space
            previewContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.background)
        .onAppear {
            loadPreviewURL()
        }
        .task(id: file.id) {
            await loadTextContent()
            await loadWorkbook()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Theme.Spacing.md) {
            // File type icon
            fileIcon
                .frame(width: 32, height: 32)

            // File name + extension
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name)
                    .font(Theme.Typography.headline)
                    .lineLimit(1)

                Text(".\(file.fileExtension.uppercased()) • \(file.formattedSize)")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }

            Spacer()

            HStack(spacing: Theme.Spacing.sm) {
                // Open in Finder
                Button {
                    openInFinder()
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
                .buttonStyle(.plain)
                #if os(macOS)
                .help("Open in Finder")
                #endif

                // Delete — closes the popup, then removes the file. Mirrors
                // the row-level trash button (NoteRowView-style) so the
                // affordance is discoverable from both surfaces.
                Button {
                    let captured = file
                    onClose?()
                    Task { await appState.deleteFile(captured) }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.red)
                }
                .buttonStyle(.plain)
                #if os(macOS)
                .help("Delete file")
                #endif

                // Close
                Button {
                    onClose?()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .frame(width: 22, height: 22)
                        .background(Theme.Colors.borderSubtle)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
    }

    // MARK: - File Icon

    private var fileIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(iconColor.opacity(0.12))

            Image(systemName: fileIconName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(iconColor)
        }
    }

    private var fileIconName: String {
        switch file.fileType {
        case .csv: return "tablecells"
        case .excel: return "tablecells.fill"
        case .image:
            switch file.fileExtension.lowercased() {
            case "png": return "photo"
            case "jpg", "jpeg": return "photo.fill"
            case "heic": return "livephoto"
            default: return "photo"
            }
        case .pdf: return "doc.richtext.fill"
        case .text: return "doc.text"
        case .video: return "film"
        case .audio: return "waveform"
        }
    }

    private var iconColor: Color { file.fileType.color }

    // MARK: - Preview Content

    private var previewContent: some View {
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
                textPreview
            case .video:
                if let url = previewURL {
                    InlineVideoPlayer(url: url, maxHeight: .infinity)
                        .padding(Theme.Spacing.md)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    placeholderView(icon: "film", message: "Unable to load video")
                }
            case .audio:
                if let url = previewURL {
                    VStack {
                        Spacer()
                        InlineAudioPlayer(url: url, accent: file.fileType.color)
                            .padding(.horizontal, Theme.Spacing.xl)
                            .frame(maxWidth: 460)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    placeholderView(icon: "waveform", message: "Unable to load audio")
                }
            }
        }
    }

    private var imagePreview: some View {
        Group {
            #if os(macOS)
            if let url = previewURL, let nsImage = NSImage(contentsOf: url) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(Theme.Spacing.md)
            } else {
                placeholderView(icon: "photo", message: "Unable to load image")
            }
            #else
            if let url = previewURL, let data = try? Data(contentsOf: url), let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(Theme.Spacing.md)
            } else {
                placeholderView(icon: "photo", message: "Unable to load image")
            }
            #endif
        }
        .background(Theme.Colors.bg1.opacity(0.03))
    }

    private var pdfPreview: some View {
        Group {
            #if canImport(PDFKit)
            if let url = previewURL {
                PDFKitPreview(url: url)
            } else {
                placeholderView(icon: "doc.richtext", message: "Unable to load PDF")
            }
            #else
            placeholderView(icon: "doc.richtext", message: "PDF preview not available")
            #endif
        }
    }

    private var csvPreview: some View {
        Group {
            if let text = loadedText, !text.isEmpty {
                // The editor snapshots the text into @State on init, so it
                // must only appear once the real content is loaded — and be
                // keyed to it — or it would edit a stale copy.
                CSVTableEditor(csvText: text) { updatedText in
                    saveEditedText(updatedText)
                }
                .id(file.id)
            } else if textLoadFinished {
                placeholderView(icon: "tablecells", message: "Unable to load CSV content")
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var textPreview: some View {
        Group {
            if let text = loadedText, !text.isEmpty {
                ScrollView {
                    Text(text)
                        .font(Theme.Typography.monoBody)
                        .foregroundStyle(Theme.Colors.textDim)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.Spacing.lg)
                }
            } else if textLoadFinished {
                placeholderView(icon: "doc.text", message: "Unable to load text content")
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Disk is the source of truth (this popup edits the file); the stored
    /// `extractedText` is only an import-time search snapshot and may be
    /// stale, so it's the fallback rather than the preferred source.
    private func loadTextContent() async {
        guard file.fileType == .csv || file.fileType == .text else { return }
        let url = await FileStorageService.shared.getFileURL(for: file)
        if let utf8Content = try? String(contentsOf: url, encoding: .utf8) {
            loadedText = utf8Content
        } else if let latin1 = try? String(contentsOf: url, encoding: .isoLatin1) {
            loadedText = latin1
        } else {
            loadedText = file.extractedText
        }
        textLoadFinished = true
    }

    /// Persist an edited CSV: overwrite the stored file, then refresh the
    /// FileItem's extractedText/fileSize so search and future previews see
    /// the new content.
    private func saveEditedText(_ text: String) {
        var updated = file
        updated.extractedText = text
        updated.fileSize = Int64(text.utf8.count)
        Task {
            try? await FileStorageService.shared.writeText(text, for: file)
            await appState.updateFile(updated)
        }
    }

    /// Parsed table view (same grid the CSV preview uses, read-only) with a
    /// sheet switcher for multi-sheet workbooks. Files XLSXReader can't parse
    /// (.xls, encrypted, corrupt) fall back to the open-externally block.
    private var excelPreview: some View {
        Group {
            if let sheets = xlsxSheets, !sheets.isEmpty {
                VStack(spacing: 0) {
                    if sheets.count > 1 {
                        sheetPicker(sheets)
                        OttoDivider()
                    }
                    let idx = min(selectedSheet, sheets.count - 1)
                    CSVTableEditor(csvText: XLSXReader.csv(for: sheets[idx]))
                        .id("\(file.id)-\(idx)")
                }
            } else if xlsxLoadFinished {
                excelFallback
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func sheetPicker(_ sheets: [XLSXReader.Sheet]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.xs) {
                ForEach(sheets.indices, id: \.self) { idx in
                    Button {
                        selectedSheet = idx
                    } label: {
                        Text(sheets[idx].name)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(idx == selectedSheet ? Theme.Colors.text : Theme.Colors.tertiaryText)
                            .padding(.horizontal, Theme.Spacing.sm)
                            .padding(.vertical, 4)
                            .background(idx == selectedSheet ? Theme.Colors.bg1 : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.xs)
        }
    }

    private var excelFallback: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Spacer()

            Image(systemName: "tablecells.fill")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(Theme.Colors.green)

            VStack(spacing: Theme.Spacing.sm) {
                Text("Excel Spreadsheet")
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.Colors.text)

                Text(".\(file.fileExtension.uppercased()) • \(file.formattedSize)")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }

            Button {
                openInFinder()
            } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "arrow.up.right.square")
                    Text("Open in Default App")
                }
                .font(Theme.Typography.body)
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.sm)
                .background(Theme.Colors.green)
                .foregroundStyle(Theme.Colors.bg0)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Parse the workbook off the main thread — XLSXReader is pure CPU
    /// (unzip + XML) and a big sheet shouldn't hitch the popup animation.
    private func loadWorkbook() async {
        guard file.fileType == .excel else { return }
        xlsxLoadFinished = false
        xlsxSheets = nil
        selectedSheet = 0
        let url = await FileStorageService.shared.getFileURL(for: file)
        let sheets = await Task.detached(priority: .userInitiated) {
            try? XLSXReader.read(url: url)
        }.value
        xlsxSheets = sheets
        xlsxLoadFinished = true
    }

    private func placeholderView(icon: String, message: String) -> some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(Theme.Colors.tertiaryText)

            Text(message)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func loadPreviewURL() {
        Task {
            previewURL = await FileStorageService.shared.getFileURL(for: file)
        }
    }

    private func openInFinder() {
        guard let url = previewURL else { return }
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #endif
    }
}

// MARK: - PDF Preview

#if canImport(PDFKit)
#if os(macOS)
private struct PDFKitPreview: NSViewRepresentable {
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
private struct PDFKitPreview: UIViewRepresentable {
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

// MARK: - Quick Look Sheet

#if os(macOS)
private struct QuickLookPreviewSheet: NSViewRepresentable {
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

#Preview {
    FilePreviewPopup(
        file: FileItem(
            name: "Sample Document",
            fileType: .pdf,
            fileExtension: "pdf",
            fileSize: 2_500_000,
            notes: "This is a sample document with some notes.",
            tags: ["Important", "Work", "2024"],
            extractedText: "Some extracted text content..."
        ),
        onClose: {}
    )
    .environment(AppState())
}
