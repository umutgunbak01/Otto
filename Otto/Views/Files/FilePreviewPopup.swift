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
    @State private var isFullScreen: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Minimal header
            header

            OttoDivider()

            // Preview fills all available space
            previewContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(
            minWidth: isFullScreen ? 900 : 500,
            idealWidth: isFullScreen ? 1200 : 650,
            maxWidth: .infinity,
            minHeight: isFullScreen ? 700 : 400,
            idealHeight: isFullScreen ? 900 : 600,
            maxHeight: .infinity
        )
        .background(Theme.Colors.background)
        .onAppear {
            loadPreviewURL()
        }
        .animation(.easeInOut(duration: 0.2), value: isFullScreen)
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

                // Full screen toggle
                Button {
                    isFullScreen.toggle()
                } label: {
                    Image(systemName: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
                .buttonStyle(.plain)
                #if os(macOS)
                .help(isFullScreen ? "Exit Full Screen" : "Full Screen")
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
                        .foregroundStyle(.red)
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

    private var iconColor: Color {
        switch file.fileType {
        case .csv: return Theme.Colors.green
        case .excel: return Color(red: 0.13, green: 0.55, blue: 0.13)
        case .image: return Theme.Colors.cyan
        case .pdf: return Theme.Colors.red
        case .text: return Theme.Colors.secondaryText
        case .video: return .purple
        case .audio: return .orange
        }
    }

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
                csvPreview  // Plain text renders fine through the CSV viewer (it's just a text scroll view)
            case .video, .audio:
                // No in-app player — point users at Quick Look. Hover popup
                // stays compact; the full FileDetailView has a dedicated
                // mediaUnsupportedPreview with a button.
                VStack(spacing: Theme.Spacing.md) {
                    Image(systemName: file.fileType == .video ? "film" : "waveform")
                        .font(.system(size: 32, weight: .thin))
                        .foregroundStyle(file.fileType == .video ? Color.purple : Color.orange)
                    Text("Use Quick Look or open the file from the Files tab.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            if let text = csvContent, !text.isEmpty {
                CSVTableView(csvText: text)
            } else {
                placeholderView(icon: "tablecells", message: "Unable to load CSV content")
            }
        }
    }

    private var csvContent: String? {
        if let text = file.extractedText, !text.isEmpty {
            return text
        }
        guard let url = previewURL else { return nil }
        if let utf8Content = try? String(contentsOf: url, encoding: .utf8) {
            return utf8Content
        }
        return try? String(contentsOf: url, encoding: .isoLatin1)
    }

    private var excelPreview: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Spacer()

            Image(systemName: "tablecells.fill")
                .font(.system(size: 48, weight: .thin))
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
                openInFinder()
            } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "arrow.up.right.square")
                    Text("Open in Default App")
                }
                .font(Theme.Typography.body)
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.sm)
                .background(Color(red: 0.13, green: 0.55, blue: 0.13))
                .foregroundStyle(Theme.Colors.bg0)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
