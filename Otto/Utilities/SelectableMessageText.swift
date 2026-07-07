import SwiftUI
import AppKit

// MARK: - Selectable Message Text
//
// SwiftUI's `.textSelection(.enabled)` on macOS treats every `Text` as its
// own selection island and drops drag-selections inside scroll views, which
// made chat messages nearly impossible to select. Each chat bubble instead
// wraps a single non-editable NSTextView, giving native AppKit selection:
// click-drag across the whole message, double-click for a word, triple-click
// for a paragraph, Cmd+C, and right-click → Copy.

struct SelectableMessageText: NSViewRepresentable {
    let attributed: NSAttributedString
    /// Called when the user clicks an inline `otto://<type>/<id>` item chip.
    /// Regular web links keep NSTextView's default open-in-browser handling.
    var onOttoLink: ((URL) -> Void)? = nil

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.isAutomaticLinkDetectionEnabled = false
        // Only the cursor here — link colors/underline/highlight are styled
        // per-run by ChatMessageRenderer so item chips and web links can
        // look different (linkTextAttributes would repaint both the same).
        view.linkTextAttributes = [
            .cursor: NSCursor.pointingHand,
        ]
        view.delegate = context.coordinator
        view.textStorage?.setAttributedString(attributed)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.onOttoLink = onOttoLink
        guard view.textStorage?.isEqual(to: attributed) != true else { return }
        view.textStorage?.setAttributedString(attributed)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onOttoLink: onOttoLink)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onOttoLink: ((URL) -> Void)?

        init(onOttoLink: ((URL) -> Void)?) {
            self.onOttoLink = onOttoLink
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL, url.scheme?.lowercased() == "otto" else {
                return false  // web links: fall through to default open-in-browser
            }
            onOttoLink?(url)
            return true
        }
    }

    // NSTextView has no useful intrinsic size for wrapped text, so answer
    // SwiftUI's width proposals by laying out the container at that width
    // and reporting the rect actually used. Returning the used width (not
    // the proposed one) lets short bubbles hug their content.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        guard let container = nsView.textContainer, let layout = nsView.layoutManager else { return nil }
        let width: CGFloat
        if let proposed = proposal.width, proposed.isFinite {
            width = max(proposed, 0)
        } else {
            width = .greatestFiniteMagnitude
        }
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return CGSize(width: ceil(used.width), height: ceil(used.height))
    }
}

// MARK: - Chat Message Renderer
//
// Builds the NSAttributedString a chat bubble displays. Mirrors the block
// styling `MarkdownContent` uses for SwiftUI (headers, bold headers,
// bullets) so switching bubbles to NSTextView didn't change their look.

enum ChatMessageRenderer {
    private static var bodyFont: NSFont { .systemFont(ofSize: 13) }
    private static var textColor: NSColor { NSColor(Theme.Colors.text) }
    private static var bulletColor: NSColor { NSColor(Theme.Colors.tertiaryText) }

    /// Plain text with the body style — used for user messages.
    static func plain(_ text: String) -> NSAttributedString {
        let style = paragraphStyle()
        return NSAttributedString(string: text, attributes: [
            .font: bodyFont,
            .foregroundColor: textColor,
            .paragraphStyle: style,
        ])
    }

    /// Markdown rendered block-by-block — used for assistant messages.
    static func markdown(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let blocks = MarkdownBlock.parse(text)

        for (index, block) in blocks.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n"))
            }
            result.append(render(block))
        }
        return result
    }

    private static func render(_ block: MarkdownBlock) -> NSAttributedString {
        switch block {
        case .h1(let text):
            return inline(text,
                          font: .systemFont(ofSize: 20, weight: .bold),
                          style: paragraphStyle(spacingBefore: Theme.Spacing.md,
                                                spacingAfter: Theme.Spacing.sm + Theme.Spacing.xs))
        case .h2(let text):
            return inline(text,
                          font: .systemFont(ofSize: 17, weight: .semibold),
                          style: paragraphStyle(spacingBefore: Theme.Spacing.sm))
        case .h3(let text):
            return inline(text,
                          font: .systemFont(ofSize: 15, weight: .semibold),
                          style: paragraphStyle(spacingBefore: Theme.Spacing.xs))
        case .boldHeader(let text):
            return inline(text,
                          font: .systemFont(ofSize: 13.5, weight: .semibold),
                          style: paragraphStyle(spacingBefore: Theme.Spacing.xs))
        case .bulletPoint(let text), .numberedItem(_, let text):
            let bullet = "• "
            let indent = (bullet as NSString).size(withAttributes: [.font: bodyFont]).width
            let style = paragraphStyle(headIndent: indent)
            let line = NSMutableAttributedString(string: bullet, attributes: [
                .font: bodyFont,
                .foregroundColor: bulletColor,
                .paragraphStyle: style,
            ])
            line.append(inline(text, font: bodyFont, style: style))
            return line
        case .regular(let text):
            return inline(text, font: bodyFont, style: paragraphStyle())
        }
    }

    /// Resolves inline markdown (bold, italic, code, links) into concrete
    /// attributes. `AttributedString(markdown:)` only records presentation
    /// intents; SwiftUI's `Text` resolves them at render time but AppKit
    /// needs real fonts.
    private static func inline(_ markdown: String, font: NSFont, style: NSParagraphStyle) -> NSAttributedString {
        let parsed = (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown)

        let result = NSMutableAttributedString()
        for run in parsed.runs {
            var substring = String(parsed[run.range].characters)
            var runFont = font
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) {
                    runFont = bolded(runFont)
                }
                if intent.contains(.emphasized) {
                    runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .italicFontMask)
                }
            }
            var attrs: [NSAttributedString.Key: Any] = [
                .font: runFont,
                .foregroundColor: textColor,
                .paragraphStyle: style,
            ]
            if let link = run.link {
                attrs[.link] = link
                if link.scheme?.lowercased() == "otto" {
                    // Inline item chip: accent pill flowing with the text.
                    // NBSP padding keeps the highlight hugging the title
                    // without breaking across it.
                    substring = "\u{00A0}\(substring)\u{00A0}"
                    attrs[.font] = mediumWeight(runFont)
                    attrs[.foregroundColor] = NSColor(Theme.Colors.accent)
                    attrs[.backgroundColor] = NSColor(Theme.Colors.accent).withAlphaComponent(0.14)
                } else {
                    // Web link: classic accent + underline (styled here
                    // because linkTextAttributes is cursor-only).
                    attrs[.foregroundColor] = NSColor(Theme.Colors.accent)
                    attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
            }
            result.append(NSAttributedString(string: substring, attributes: attrs))
        }
        return result
    }

    private static func mediumWeight(_ font: NSFont) -> NSFont {
        if font.fontDescriptor.symbolicTraits.contains(.bold) { return font }
        return .systemFont(ofSize: font.pointSize, weight: .medium)
    }

    private static func bolded(_ font: NSFont) -> NSFont {
        if font.fontDescriptor.symbolicTraits.contains(.monoSpace) {
            return .monospacedSystemFont(ofSize: font.pointSize, weight: .bold)
        }
        return .boldSystemFont(ofSize: font.pointSize)
    }

    private static func paragraphStyle(
        spacingBefore: CGFloat = 0,
        spacingAfter: CGFloat = Theme.Spacing.sm,
        headIndent: CGFloat = 0
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = spacingBefore
        style.paragraphSpacing = spacingAfter
        style.headIndent = headIndent
        style.lineBreakMode = .byWordWrapping
        return style
    }
}
