import SwiftUI

/// A view that renders markdown-formatted text with proper styling
struct MarkdownText: View {
    let text: String
    let font: Font
    let color: Color

    init(_ text: String, font: Font = Theme.Typography.body, color: Color = Theme.Colors.text) {
        self.text = text
        self.font = font
        self.color = color
    }

    var body: some View {
        Text(attributedString)
            .font(font)
            .foregroundStyle(color)
    }

    private var attributedString: AttributedString {
        // Try to parse as markdown with full inline support (bold, italic, links)
        do {
            let attributed = try AttributedString(markdown: preprocessMarkdown(text), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            return attributed
        } catch {
            return AttributedString(text)
        }
    }

    /// Preprocess the text to handle common markdown patterns
    private func preprocessMarkdown(_ input: String) -> String {
        var result = input

        // Convert **text** headers on their own line to bold (they render correctly as bold)
        // The markdown parser handles **bold** and *italic* natively

        return result
    }
}

/// A view that renders multi-line markdown content with proper line handling
struct MarkdownContent: View {
    let text: String
    let font: Font
    let color: Color

    init(_ text: String, font: Font = Theme.Typography.body, color: Color = Theme.Colors.text) {
        self.text = text
        self.font = font
        self.color = color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ForEach(Array(parseLines().enumerated()), id: \.offset) { _, line in
                lineView(for: line)
            }
        }
    }

    private enum LineType {
        case h1(String)          // # Heading
        case h2(String)          // ## Heading
        case h3(String)          // ### Heading
        case boldHeader(String)  // **Header**
        case bulletPoint(String) // - Item
        case numberedItem(Int, String) // 1. Item
        case regular(String)
    }

    private func parseLines() -> [LineType] {
        let lines = text.components(separatedBy: "\n")
        var result: [LineType] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                continue
            }

            // Check for markdown headings: # ## ###
            if trimmed.hasPrefix("### ") {
                let headerText = String(trimmed.dropFirst(4))
                result.append(.h3(headerText))
            }
            else if trimmed.hasPrefix("## ") {
                let headerText = String(trimmed.dropFirst(3))
                result.append(.h2(headerText))
            }
            else if trimmed.hasPrefix("# ") {
                let headerText = String(trimmed.dropFirst(2))
                result.append(.h1(headerText))
            }
            // Check for bold header pattern: line starts and ends with **
            else if trimmed.hasPrefix("**") && trimmed.hasSuffix("**") && trimmed.count > 4 {
                let headerText = String(trimmed.dropFirst(2).dropLast(2))
                result.append(.boldHeader(headerText))
            }
            // Check for bullet point: starts with - or • or *
            else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("• ") {
                let content = String(trimmed.dropFirst(2))
                result.append(.bulletPoint(content))
            }
            else if trimmed.hasPrefix("* ") && !(trimmed.hasSuffix("*") || trimmed.hasSuffix("**")) {
                // * bullet (but not italic/bold markers like *text* or **text**)
                let content = String(trimmed.dropFirst(2))
                result.append(.bulletPoint(content))
            }
            // Check for numbered item: starts with number followed by . or )
            else if let match = trimmed.firstMatch(of: /^(\d+)[.)]\s+(.+)/) {
                let number = Int(match.1) ?? 1
                let content = String(match.2)
                result.append(.numberedItem(number, content))
            }
            // Regular line (may contain inline markdown)
            else {
                result.append(.regular(trimmed))
            }
        }

        return result
    }

    @ViewBuilder
    private func lineView(for line: LineType) -> some View {
        switch line {
        case .h1(let text):
            MarkdownText(text, font: .system(size: 20, weight: .bold), color: color)
                .padding(.top, Theme.Spacing.md)
                .padding(.bottom, Theme.Spacing.xs)

        case .h2(let text):
            MarkdownText(text, font: .system(size: 17, weight: .semibold), color: color)
                .padding(.top, Theme.Spacing.sm)

        case .h3(let text):
            MarkdownText(text, font: .system(size: 15, weight: .semibold), color: color)
                .padding(.top, Theme.Spacing.xs)

        case .boldHeader(let text):
            MarkdownText(text, font: Theme.Typography.headline, color: color)
                .padding(.top, Theme.Spacing.xs)

        case .bulletPoint(let text):
            HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                Text("•")
                    .font(font)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                MarkdownText(text, font: font, color: color)
            }

        case .numberedItem(_, let text):
            HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                Text("•")
                    .font(font)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                MarkdownText(text, font: font, color: color)
            }

        case .regular(let text):
            MarkdownText(text, font: font, color: color)
        }
    }
}

#Preview("Markdown Text") {
    ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            MarkdownText("This is **bold** and this is *italic*")

            MarkdownContent("""
            # Main Heading
            This is content under the main heading.

            ## Section Heading
            Content under section heading.

            ### Subsection
            More detailed content here.

            **Alice Doe**
            - First action item with **bold** text
            - Second action item

            **Bob Smith**
            - Another item here
            - One more item
            """)

            MarkdownContent("""
            ## Overview
            - **Pilot Launch:** Scheduled for end of month
            - **Competitive Advantage:** Tailored video generation
            - Regular item without bold header
            """)
        }
        .padding()
    }
    .frame(width: 400, height: 500)
}
