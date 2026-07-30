import SwiftUI
import AppKit

// MARK: - Block model

/// The kinds of blocks the note editor understands. Notes are stored as
/// markdown (`Note.content`) — one line per block, except code fences — so
/// agent tools, Notion import, mentions, and search keep working on plain
/// markdown while the editor renders real blocks.
enum NoteBlockKind: Equatable, Hashable {
    case paragraph
    case heading1
    case heading2
    case heading3
    case bullet
    case numbered
    case todo(done: Bool)
    case toggle
    case quote
    case callout(icon: String)
    case code(language: String)
    case divider
    case image(source: String, alt: String)

    /// True for kinds whose row hosts an editable text view.
    var isTextual: Bool {
        switch self {
        case .divider, .image: return false
        default: return true
        }
    }

    /// Blocks that participate in Tab/Shift-Tab indentation and carry
    /// children (visually) when deeper blocks follow them.
    var supportsIndent: Bool {
        switch self {
        case .divider, .image, .code: return false
        default: return true
        }
    }

    /// Same case, ignoring associated values — used by "Turn into" menus.
    func isSameFamily(as other: NoteBlockKind) -> Bool {
        switch (self, other) {
        case (.paragraph, .paragraph), (.heading1, .heading1), (.heading2, .heading2),
             (.heading3, .heading3), (.bullet, .bullet), (.numbered, .numbered),
             (.todo, .todo), (.toggle, .toggle), (.quote, .quote), (.callout, .callout),
             (.code, .code), (.divider, .divider), (.image, .image):
            return true
        default:
            return false
        }
    }
}

/// One block of a note. Reference type on purpose: the block's `storage` IS
/// the live NSTextStorage its text view edits — no copy-back binding loops,
/// no cursor resets, and the shared document UndoManager sees every change.
@Observable
final class EditorBlock: Identifiable {
    let id = UUID()
    var kind: NoteBlockKind
    var indent: Int
    /// Toggles only: collapsed state is ephemeral UI state (per session).
    /// It is deliberately NOT serialized — the legacy editor's "▾/▸ in the
    /// text" approach leaked glyphs into previews, search, and agent tools.
    var isCollapsed: Bool
    /// Rendered height of the block's text at the current width, measured by
    /// the AppKit side. Observable so the SwiftUI row resizes with typing.
    var measuredHeight: CGFloat = 0
    let storage: NSTextStorage

    init(
        kind: NoteBlockKind = .paragraph,
        text: NSAttributedString = NSAttributedString(),
        indent: Int = 0,
        isCollapsed: Bool = false
    ) {
        self.kind = kind
        self.indent = max(0, indent)
        self.isCollapsed = isCollapsed
        self.storage = NSTextStorage(attributedString: text)
    }

    var plainText: String { storage.string }
}

// MARK: - Editor typography

extension NSAttributedString.Key {
    /// Marks inline-code runs so serialization doesn't have to guess from the
    /// font alone.
    static let ottoInlineCode = NSAttributedString.Key("ottoInlineCode")
    /// Inline bold/italic markers. Custom attributes, NOT font traits: the
    /// system font reports semibold (H2/H3 bases) as "bold" to NSFontManager
    /// and trait conversion is lossy, so fonts are display-only here.
    static let ottoBold = NSAttributedString.Key("ottoBold")
    static let ottoItalic = NSAttributedString.Key("ottoItalic")
}

/// Fonts/colors/paragraph styles for each block kind. Sizes follow the app's
/// existing density (13.5pt body — same as the previous editor).
enum NoteEditorStyle {
    static let bodySize: CGFloat = 13.5

    static var textColor: NSColor { NSColor(Theme.Colors.text) }
    static var secondaryTextColor: NSColor { NSColor(Theme.Colors.secondaryText) }

    static func font(for kind: NoteBlockKind) -> NSFont {
        switch kind {
        case .heading1: return .systemFont(ofSize: 21, weight: .bold)
        case .heading2: return .systemFont(ofSize: 16, weight: .semibold)
        case .heading3: return .systemFont(ofSize: 14, weight: .semibold)
        case .toggle:   return .systemFont(ofSize: bodySize, weight: .medium)
        case .quote:    return italic(.systemFont(ofSize: bodySize))
        case .code:     return .monospacedSystemFont(ofSize: 12, weight: .regular)
        default:        return .systemFont(ofSize: bodySize)
        }
    }

    static func color(for kind: NoteBlockKind) -> NSColor {
        switch kind {
        case .quote: return secondaryTextColor
        default:     return textColor
        }
    }

    static func paragraphStyle(for kind: NoteBlockKind) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        switch kind {
        case .heading1:     style.lineSpacing = 4
        case .heading2:     style.lineSpacing = 4
        case .heading3:     style.lineSpacing = 3
        case .code:         style.lineSpacing = 2.5
        default:            style.lineSpacing = 4.5
        }
        return style
    }

    static func baseAttributes(for kind: NoteBlockKind) -> [NSAttributedString.Key: Any] {
        [
            .font: font(for: kind),
            .foregroundColor: color(for: kind),
            .paragraphStyle: paragraphStyle(for: kind)
        ]
    }

    /// One text line's height for a kind — used for empty-block sizing and
    /// trailing-newline measurement.
    static func lineHeight(for kind: NoteBlockKind) -> CGFloat {
        let font = font(for: kind)
        return ceil(font.ascender - font.descender + font.leading)
    }

    static var inlineCodeFont: NSFont { .monospacedSystemFont(ofSize: bodySize - 1, weight: .regular) }
    static var inlineCodeColor: NSColor { NSColor(Theme.Colors.accentText) }
    static var inlineCodeBackground: NSColor { NSColor(Theme.Colors.hoverTint) }

    // NSFontManager, not NSFontDescriptor.withSymbolicTraits: descriptor
    // trait conversion silently fails for the SF system font. These fonts
    // are DISPLAY-ONLY — bold/italic truth lives in .ottoBold/.ottoItalic.
    static func italic(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    }

    static func isBold(_ font: NSFont) -> Bool {
        NSFontManager.shared.traits(of: font).contains(.boldFontMask)
    }

    /// Display font for a block's base typography plus inline flags. Bases
    /// that are already semibold+ (headings) step up to heavy so inline bold
    /// stays visible.
    static func displayFont(for kind: NoteBlockKind, bold: Bool, italicFlag: Bool) -> NSFont {
        var font = self.font(for: kind)
        if bold {
            font = isBold(font)
                ? .systemFont(ofSize: font.pointSize, weight: .heavy)
                : NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        }
        if italicFlag {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        return font
    }
}

// MARK: - Markdown ⇄ blocks codec

/// Line-oriented markdown codec. Dialect notes:
/// - One line = one block (matches the previous editor and agent-written
///   content). Lines ending in two+ spaces continue the same block with a
///   soft line break (standard markdown hard-break syntax).
/// - Toggles serialize as `+ ` (a valid CommonMark bullet). Legacy `▾ `/`▸ `
///   markers are still parsed and migrate on next save.
/// - Callouts use `> [!💡] text` (icon between the brackets).
/// - Images are whole-line `![alt](source)` blocks.
enum NoteDocument {

    // MARK: Parse

    static func normalizeSeparators(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
    }

    static func parse(_ markdown: String) -> [EditorBlock] {
        let text = normalizeSeparators(markdown)
        guard !text.isEmpty else { return [EditorBlock()] }

        let lines = text.components(separatedBy: "\n")
        var blocks: [EditorBlock] = []
        var index = 0

        while index < lines.count {
            let rawLine = lines[index]
            let (indent, content) = splitIndent(rawLine)

            // Code fence: consume until the closing fence.
            if content.hasPrefix("```") {
                let language = String(content.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                index += 1
                while index < lines.count {
                    let (_, fenceCheck) = splitIndent(lines[index])
                    if fenceCheck == "```" { index += 1; break }
                    codeLines.append(dropIndent(lines[index], levels: indent))
                    index += 1
                }
                let code = codeLines.joined(separator: "\n")
                let kind = NoteBlockKind.code(language: language)
                blocks.append(EditorBlock(
                    kind: kind,
                    text: NSAttributedString(string: code, attributes: NoteEditorStyle.baseAttributes(for: kind)),
                    indent: indent
                ))
                continue
            }

            let (kind, body, collapsed) = classify(content)

            // Soft-break continuation: a line ending in 2+ spaces pulls the
            // following line(s) into the same block, unless the next line
            // starts a block of its own (markdown semantics).
            var textBody = body
            var lastRaw = rawLine
            while lastRaw.hasSuffix("  "), index + 1 < lines.count {
                let nextRaw = lines[index + 1]
                let (_, nextContent) = splitIndent(nextRaw)
                let (nextKind, nextBody, _) = classify(nextContent)

                let continues: Bool
                let continuationText: String
                switch kind {
                case .quote, .callout:
                    // Quotes/callouts continue across `> `-prefixed lines.
                    if case .quote = nextKind { continues = true; continuationText = nextBody }
                    else { continues = false; continuationText = "" }
                default:
                    // Plain continuation only if the next line isn't a block.
                    if case .paragraph = nextKind, !nextContent.isEmpty, !nextContent.hasPrefix("```") {
                        continues = true; continuationText = nextBody
                    } else { continues = false; continuationText = "" }
                }
                guard continues else { break }

                textBody = trimTrailingHardBreak(textBody) + "\n" + continuationText
                lastRaw = nextRaw
                index += 1
            }
            textBody = trimTrailingHardBreak(textBody)

            switch kind {
            case .divider:
                blocks.append(EditorBlock(kind: .divider, indent: indent))
            case .image(let source, let alt):
                blocks.append(EditorBlock(kind: .image(source: source, alt: alt), indent: indent))
            default:
                blocks.append(EditorBlock(
                    kind: kind,
                    text: inlineAttributed(fromMarkdown: textBody, kind: kind),
                    indent: indent,
                    isCollapsed: collapsed
                ))
            }
            index += 1
        }

        if blocks.isEmpty { blocks = [EditorBlock()] }
        return blocks
    }

    /// (indent level, remaining content). Tabs count one level, 2 spaces one.
    private static func splitIndent(_ line: String) -> (Int, String) {
        var level = 0
        var spaceRun = 0
        var idx = line.startIndex
        while idx < line.endIndex {
            let ch = line[idx]
            if ch == "\t" {
                level += 1
                spaceRun = 0
            } else if ch == " " {
                spaceRun += 1
                if spaceRun == 2 { level += 1; spaceRun = 0 }
            } else {
                break
            }
            idx = line.index(after: idx)
        }
        // A dangling single space stays with the content.
        if spaceRun == 1 { idx = line.index(before: idx) }
        return (level, String(line[idx...]))
    }

    private static func dropIndent(_ line: String, levels: Int) -> String {
        var remaining = levels
        var idx = line.startIndex
        while remaining > 0, idx < line.endIndex {
            if line[idx] == "\t" {
                idx = line.index(after: idx)
                remaining -= 1
            } else if line[idx] == " " {
                let next = line.index(after: idx)
                if next < line.endIndex, line[next] == " " {
                    idx = line.index(next, offsetBy: 1)
                    remaining -= 1
                } else { break }
            } else { break }
        }
        return String(line[idx...])
    }

    private static func trimTrailingHardBreak(_ text: String) -> String {
        var result = text
        while result.hasSuffix(" ") { result.removeLast() }
        return result
    }

    /// Classify one line's content (indent already stripped).
    /// Returns (kind, text body, initially-collapsed).
    private static func classify(_ content: String) -> (NoteBlockKind, String, Bool) {
        if content == "---" || content == "***" || content == "___" {
            return (.divider, "", false)
        }
        if content.hasPrefix("### ") { return (.heading3, String(content.dropFirst(4)), false) }
        if content.hasPrefix("## ") { return (.heading2, String(content.dropFirst(3)), false) }
        if content.hasPrefix("# ") { return (.heading1, String(content.dropFirst(2)), false) }
        if content.hasPrefix("- [x] ") || content.hasPrefix("- [X] ") {
            return (.todo(done: true), String(content.dropFirst(6)), false)
        }
        if content.hasPrefix("- [ ] ") { return (.todo(done: false), String(content.dropFirst(6)), false) }
        if content == "- [ ]" { return (.todo(done: false), "", false) }
        if content == "- [x]" || content == "- [X]" { return (.todo(done: true), "", false) }
        if content.hasPrefix("- ") || content.hasPrefix("* ") {
            return (.bullet, String(content.dropFirst(2)), false)
        }
        if content.hasPrefix("+ ") { return (.toggle, String(content.dropFirst(2)), false) }
        // Legacy toggle markers from the previous editor.
        if content.hasPrefix("▾ ") { return (.toggle, String(content.dropFirst(2)), false) }
        if content.hasPrefix("▸ ") { return (.toggle, String(content.dropFirst(2)), true) }
        if let calloutMatch = content.range(of: #"^> \[!(.{1,8}?)\] ?"#, options: .regularExpression) {
            let inside = String(content[calloutMatch.lowerBound..<calloutMatch.upperBound])
            let icon = inside
                .replacingOccurrences(of: "> [!", with: "")
                .replacingOccurrences(of: "] ", with: "")
                .replacingOccurrences(of: "]", with: "")
            return (.callout(icon: icon.isEmpty ? "💡" : icon), String(content[calloutMatch.upperBound...]), false)
        }
        if content.hasPrefix("> ") { return (.quote, String(content.dropFirst(2)), false) }
        if content == ">" { return (.quote, "", false) }
        if let match = content.range(of: #"^\d{1,4}[.)] "#, options: .regularExpression) {
            return (.numbered, String(content[match.upperBound...]), false)
        }
        if let match = content.range(of: #"^!\[([^\]]*)\]\((.+?)\)\s*$"#, options: .regularExpression),
           match.lowerBound == content.startIndex {
            let inner = String(content[match.lowerBound..<match.upperBound])
            if let altRange = inner.range(of: #"(?<=^!\[)[^\]]*"#, options: .regularExpression),
               let srcRange = inner.range(of: #"(?<=\().+?(?=\)\s*$)"#, options: .regularExpression) {
                return (.image(source: String(inner[srcRange]), alt: String(inner[altRange])), "", false)
            }
        }
        return (.paragraph, content, false)
    }

    // MARK: Serialize

    static func serialize(_ blocks: [EditorBlock]) -> String {
        var lines: [String] = []
        // Per-indent counters for canonical numbered-list numbering.
        var numberCounters: [Int: Int] = [:]

        for block in blocks {
            let prefix = String(repeating: "  ", count: max(0, block.indent))

            // Any non-numbered block (or shallower indent) resets deeper counters.
            if case .numbered = block.kind {
                for level in numberCounters.keys where level > block.indent {
                    numberCounters.removeValue(forKey: level)
                }
            } else {
                for level in numberCounters.keys where level >= block.indent {
                    numberCounters.removeValue(forKey: level)
                }
            }

            switch block.kind {
            case .divider:
                lines.append(prefix + "---")
            case .image(let source, let alt):
                lines.append(prefix + "![\(alt)](\(source))")
            case .code(let language):
                lines.append(prefix + "```" + language)
                let codeLines = block.plainText.components(separatedBy: "\n")
                for codeLine in codeLines {
                    lines.append(codeLine.isEmpty ? "" : prefix + codeLine)
                }
                lines.append(prefix + "```")
            default:
                let inline = inlineMarkdown(from: block.storage, kind: block.kind)
                let parts = inline.components(separatedBy: "\n")
                let marker: String
                switch block.kind {
                case .heading1: marker = "# "
                case .heading2: marker = "## "
                case .heading3: marker = "### "
                case .bullet: marker = "- "
                case .numbered:
                    let count = (numberCounters[block.indent] ?? 0) + 1
                    numberCounters[block.indent] = count
                    marker = "\(count). "
                case .todo(let done): marker = done ? "- [x] " : "- [ ] "
                case .toggle: marker = "+ "
                case .quote: marker = "> "
                case .callout(let icon): marker = "> [!\(icon)] "
                default: marker = ""
                }

                for (partIndex, part) in parts.enumerated() {
                    let isLast = partIndex == parts.count - 1
                    let hardBreak = isLast ? "" : "  "
                    if partIndex == 0 {
                        lines.append(prefix + marker + part + hardBreak)
                    } else {
                        // Continuation lines: quotes/callouts re-prefix with
                        // "> " so the markdown stays valid; other kinds emit
                        // the bare text (parser joins via the hard break).
                        switch block.kind {
                        case .quote, .callout:
                            lines.append(prefix + "> " + part + hardBreak)
                        default:
                            lines.append(prefix + part + hardBreak)
                        }
                    }
                }
            }
        }

        // A lone empty paragraph serializes to an empty document.
        if lines.count == 1, lines[0].isEmpty { return "" }
        return lines.joined(separator: "\n")
    }

    // MARK: Inline codec (markdown ↔ attributed runs)

    /// Parse inline markdown (bold/italic/code/strikethrough/links) into an
    /// attributed string carrying the block's base typography. WYSIWYG: the
    /// markers exist only in storage, never on screen.
    static func inlineAttributed(fromMarkdown markdown: String, kind: NoteBlockKind) -> NSAttributedString {
        let base = NoteEditorStyle.baseAttributes(for: kind)
        guard !markdown.isEmpty else { return NSAttributedString(string: "", attributes: base) }

        // Code blocks are literal — no inline parsing.
        if case .code = kind {
            return NSAttributedString(string: markdown, attributes: base)
        }

        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return NSAttributedString(string: markdown, attributes: base)
        }

        let result = NSMutableAttributedString()

        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            guard !text.isEmpty else { continue }
            var attrs = base

            let intent = run.inlinePresentationIntent ?? []
            let isBold = intent.contains(.stronglyEmphasized)
            let isItalic = intent.contains(.emphasized)
            let isCode = intent.contains(.code)
            let isStrike = intent.contains(.strikethrough)

            if isCode {
                attrs[.font] = NoteEditorStyle.inlineCodeFont
                attrs[.foregroundColor] = NoteEditorStyle.inlineCodeColor
                attrs[.backgroundColor] = NoteEditorStyle.inlineCodeBackground
                attrs[.ottoInlineCode] = true
            } else if isBold || isItalic {
                attrs[.font] = NoteEditorStyle.displayFont(for: kind, bold: isBold, italicFlag: isItalic)
                if isBold { attrs[.ottoBold] = true }
                if isItalic { attrs[.ottoItalic] = true }
            }
            if isStrike {
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link {
                attrs[.link] = link
            }

            result.append(NSAttributedString(string: text, attributes: attrs))
        }

        if result.length == 0 {
            return NSAttributedString(string: markdown, attributes: base)
        }
        return result
    }

    private struct InlineFlags: Equatable {
        var bold = false
        var italic = false
        var code = false
        var strike = false
        var link: URL?
    }

    /// Serialize attributed runs back to inline markdown. Bold/italic truth
    /// comes from the .ottoBold/.ottoItalic attributes — never from font
    /// traits (the system font reports semibold heading bases as "bold").
    static func inlineMarkdown(from attributed: NSAttributedString, kind: NoteBlockKind = .paragraph) -> String {
        guard attributed.length > 0 else { return "" }

        // Collect (text, flags) segments, merging adjacent equal-flag runs.
        var segments: [(text: String, flags: InlineFlags)] = []
        let full = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttributes(in: full) { attrs, range, _ in
            let text = (attributed.string as NSString).substring(with: range)
            var flags = InlineFlags()
            flags.bold = attrs[.ottoBold] as? Bool == true
            flags.italic = attrs[.ottoItalic] as? Bool == true
            if attrs[.ottoInlineCode] as? Bool == true { flags.code = true }
            if let strike = attrs[.strikethroughStyle] as? Int, strike != 0 { flags.strike = true }
            if let url = attrs[.link] as? URL { flags.link = url }
            else if let str = attrs[.link] as? String { flags.link = URL(string: str) }

            if flags.code { flags.bold = false; flags.italic = false }

            if var last = segments.last, last.flags == flags {
                last.text += text
                segments[segments.count - 1] = last
            } else {
                segments.append((text, flags))
            }
        }

        var out = ""
        for segment in segments {
            // Emit soft-break lines separately: markers can't span newlines.
            let lines = segment.text.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                if index > 0 { out += "\n" }
                out += wrapInline(line, flags: segment.flags)
            }
        }
        return out
    }

    private static func wrapInline(_ text: String, flags: InlineFlags) -> String {
        guard !text.isEmpty else { return text }
        // Plain text: emit verbatim.
        if flags == InlineFlags() { return text }

        // Markers hug the content — hoist surrounding whitespace outside
        // (`**bold **` would not re-parse as bold).
        let core = text.trimmingCharacters(in: .whitespaces)
        guard !core.isEmpty else { return text }
        let leadingCount = text.prefix(while: { $0 == " " }).count
        let trailingCount = text.reversed().prefix(while: { $0 == " " }).count
        let leading = String(repeating: " ", count: leadingCount)
        let trailing = String(repeating: " ", count: trailingCount)

        var wrapped = core
        if flags.code {
            // Pick a backtick fence longer than any run inside the code.
            let maxRun = longestBacktickRun(in: core)
            let fence = String(repeating: "`", count: maxRun + 1)
            let pad = maxRun > 0 ? " " : ""
            wrapped = fence + pad + wrapped + pad + fence
        } else {
            if flags.strike { wrapped = "~~" + wrapped + "~~" }
            if flags.bold && flags.italic { wrapped = "***" + wrapped + "***" }
            else if flags.bold { wrapped = "**" + wrapped + "**" }
            else if flags.italic { wrapped = "*" + wrapped + "*" }
        }
        if let link = flags.link {
            wrapped = "[" + wrapped + "](" + link.absoluteString + ")"
        }
        return leading + wrapped + trailing
    }

    private static func longestBacktickRun(in text: String) -> Int {
        var longest = 0
        var current = 0
        for ch in text {
            if ch == "`" { current += 1; longest = max(longest, current) }
            else { current = 0 }
        }
        return longest
    }

    /// Re-apply a block kind's base typography to existing text while
    /// preserving inline formatting (bold/italic/code/strike/links).
    static func restyle(_ storage: NSTextStorage, from oldKind: NoteBlockKind, to kind: NoteBlockKind) {
        let markdown: String
        if case .code = oldKind {
            markdown = storage.string
        } else {
            markdown = inlineMarkdown(from: storage, kind: oldKind)
        }
        let restyled = inlineAttributed(fromMarkdown: markdown, kind: kind)
        storage.setAttributedString(restyled)
    }

    // MARK: Plain text (search, previews, word count)

    /// All visible text, markers stripped — one line per source line. Pure
    /// string ops (no attributed parsing): sidebar rows and search call this
    /// per note per render.
    static func plainText(_ markdown: String) -> String {
        let text = normalizeSeparators(markdown)
        guard !text.isEmpty else { return "" }
        var lines: [String] = []
        var inFence = false
        for raw in text.components(separatedBy: "\n") {
            let (_, content) = splitIndent(raw)
            if content.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if inFence {
                lines.append(raw)
                continue
            }
            let (kind, body, _) = classify(content)
            switch kind {
            case .divider: lines.append("")
            case .image(_, let alt): lines.append(alt)
            default: lines.append(stripInlineMarkers(body))
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func stripInlineMarkers(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        if result.contains("](") {
            // [text](url) and ![alt](url) → text/alt
            result = result.replacingOccurrences(
                of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression
            )
        }
        for marker in ["**", "~~", "`", "*"] where result.contains(marker) {
            result = result.replacingOccurrences(of: marker, with: "")
        }
        return result.hasSuffix(" ") ? trimTrailingHardBreak(result) : result
    }

    /// Single-line preview used by sidebar rows (replaces the old
    /// `strippedNotePreview`, which leaked `▾`/`▸` toggle glyphs).
    static func preview(_ markdown: String) -> String {
        plainText(markdown)
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func wordCount(_ markdown: String) -> Int {
        plainText(markdown)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .count
    }
}
