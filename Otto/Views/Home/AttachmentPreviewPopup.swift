import SwiftUI
import AppKit
#if canImport(PDFKit)
import PDFKit
#endif

/// Full-size preview for a chat attachment — the in-memory file the user
/// staged in the composer or already sent with a message. Unlike
/// `FilePreviewPopup` (which fronts a Files-tab item on disk), this renders
/// straight from `ChatAttachment.data`.
///
/// Markdown renders formatted with the same renderer chat bubbles use;
/// the rest of the text family shows as selectable monospaced text; images
/// and PDFs render natively; anything else gets an icon + metadata block.
struct AttachmentPreviewPopup: View {
    let attachment: ChatAttachment
    var onClose: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            header

            OttoDivider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.background)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Theme.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(Theme.Colors.accent.opacity(0.12))

                Image(systemName: iconName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.Colors.accent)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.filename)
                    .font(Theme.Typography.headline)
                    .lineLimit(1)

                Text("\(attachment.mediaType) • \(attachment.formattedSize)")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }

            Spacer()

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
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
    }

    private var iconName: String {
        switch attachment.kind {
        case .image:  return "photo"
        case .pdf:    return "doc.richtext"
        case .text:
            let ext = (attachment.filename as NSString).pathExtension.lowercased()
            return ext == "csv" || ext == "tsv" ? "tablecells" : "doc.text"
        case .binary: return "doc"
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch attachment.kind {
        case .text:
            if let text = attachment.textContent, !text.isEmpty {
                if attachment.isMarkdown {
                    markdownPreview(text)
                } else {
                    plainTextPreview(text)
                }
            } else {
                placeholder(icon: "doc.text", message: "Unable to decode text content")
            }
        case .image:
            if let nsImage = NSImage(data: attachment.data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(Theme.Spacing.md)
                    .background(Theme.Colors.bg1.opacity(0.03))
            } else {
                placeholder(icon: "photo", message: "Unable to load image")
            }
        case .pdf:
            #if canImport(PDFKit)
            if let document = PDFDocument(data: attachment.data) {
                PDFDocumentView(document: document)
            } else {
                placeholder(icon: "doc.richtext", message: "Unable to load PDF")
            }
            #else
            placeholder(icon: "doc.richtext", message: "PDF preview not available")
            #endif
        case .binary:
            placeholder(icon: "doc", message: "No inline preview for .\((attachment.filename as NSString).pathExtension.lowercased()) files")
        }
    }

    /// Rendered markdown — same block styling as assistant chat bubbles
    /// (headings, bold headers, bullets, inline bold/italic/links), fully
    /// selectable.
    private func markdownPreview(_ text: String) -> some View {
        ScrollView {
            SelectableMessageText(attributed: ChatMessageRenderer.markdown(text))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Spacing.xl)
        }
    }

    private func plainTextPreview(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(Theme.Typography.monoBody)
                .foregroundStyle(Theme.Colors.textDim)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Spacing.lg)
        }
    }

    private func placeholder(icon: String, message: String) -> some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(Theme.Colors.tertiaryText)

            Text(message)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.secondaryText)

            Text("\(attachment.filename) • \(attachment.formattedSize)")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.tertiaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - PDF from Data

#if canImport(PDFKit)
private struct PDFDocumentView: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.document = document
        return pdfView
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document !== document {
            nsView.document = document
        }
    }
}
#endif

#Preview {
    AttachmentPreviewPopup(
        attachment: ChatAttachment(
            filename: "notes.md",
            mediaType: "text/markdown",
            data: Data("""
            # Project Notes

            Some **bold** thoughts and *italic* asides.

            ## Next steps
            - Ship the markdown preview
            - Verify uploads reach the model
            """.utf8)
        ),
        onClose: {}
    )
    .frame(width: 720, height: 520)
}
