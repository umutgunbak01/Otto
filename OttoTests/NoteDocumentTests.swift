import Testing
import Foundation
import AppKit
@testable import Otto

/// Round-trip and edge-case coverage for the notes markdown ⇄ blocks codec.
/// The editor's correctness rests on serialize(parse(x)) being stable — the
/// old editor corrupted content by leaking UI state (▾/▸) into the text.
@MainActor
struct NoteDocumentTests {

    private func roundTrip(_ markdown: String) -> String {
        NoteDocument.serialize(NoteDocument.parse(markdown))
    }

    /// serialize∘parse must be idempotent: a second pass changes nothing.
    private func expectStable(_ markdown: String,
                              sourceLocation: SourceLocation = #_sourceLocation) {
        let once = roundTrip(markdown)
        let twice = roundTrip(once)
        #expect(once == twice, sourceLocation: sourceLocation)
    }

    // MARK: - Basic block kinds

    @Test func parsesEveryBlockKind() {
        let md = """
        # H1
        ## H2
        ### H3
        plain text
        - bullet
        1. numbered
        - [ ] open todo
        - [x] done todo
        + toggle head
        > a quote
        > [!🔥] a callout
        ---
        ![alt text](noteasset:abc.png)
        ```swift
        let x = 1
        ```
        """
        let blocks = NoteDocument.parse(md)
        let kinds = blocks.map(\.kind)
        #expect(kinds[0] == .heading1)
        #expect(kinds[1] == .heading2)
        #expect(kinds[2] == .heading3)
        #expect(kinds[3] == .paragraph)
        #expect(kinds[4] == .bullet)
        #expect(kinds[5] == .numbered)
        #expect(kinds[6] == .todo(done: false))
        #expect(kinds[7] == .todo(done: true))
        #expect(kinds[8] == .toggle)
        #expect(kinds[9] == .quote)
        #expect(kinds[10] == .callout(icon: "🔥"))
        #expect(kinds[11] == .divider)
        #expect(kinds[12] == .image(source: "noteasset:abc.png", alt: "alt text"))
        #expect(kinds[13] == .code(language: "swift"))
        #expect(blocks[13].plainText == "let x = 1")
    }

    @Test func fullDocumentRoundTripsVerbatim() {
        let md = """
        # Title
        intro paragraph
        - one
        - two
        1. first
        2. second
        - [ ] task
        - [x] done
        + details
          hidden child
        > quoted
        > [!💡] tip text
        ---
        ```python
        print("hi")

        print("bye")
        ```
        closing text
        """
        #expect(roundTrip(md) == md)
        expectStable(md)
    }

    // MARK: - Legacy toggle migration

    @Test func legacyToggleGlyphsBecomeToggleBlocks() {
        let blocks = NoteDocument.parse("▾ open toggle\n▸ closed toggle")
        #expect(blocks[0].kind == .toggle)
        #expect(blocks[0].isCollapsed == false)
        #expect(blocks[1].kind == .toggle)
        #expect(blocks[1].isCollapsed == true)
        // Glyphs never re-serialize — the canonical form is "+ ".
        let out = NoteDocument.serialize(blocks)
        #expect(out == "+ open toggle\n+ closed toggle")
        #expect(!out.contains("▾") && !out.contains("▸"))
    }

    // MARK: - Nesting

    @Test func indentationRoundTrips() {
        let md = "- a\n  - b\n    - c\n  back\ntop"
        let blocks = NoteDocument.parse(md)
        #expect(blocks.map(\.indent) == [0, 1, 2, 1, 0])
        #expect(roundTrip(md) == md)
    }

    @Test func tabsCountAsIndentLevels() {
        let blocks = NoteDocument.parse("+ head\n\tchild")
        #expect(blocks[1].indent == 1)
        #expect(blocks[1].kind == .paragraph)
        // Tabs normalize to two-space indents on save.
        #expect(NoteDocument.serialize(blocks) == "+ head\n  child")
    }

    @Test func notionStyleIndentedListsParse() {
        // NotionService.convertBlocksToMarkdown emits nested lists like this —
        // the old editor rendered them as unstyled plain text.
        let md = "- parent\n  - child\n    1. grandchild"
        let blocks = NoteDocument.parse(md)
        #expect(blocks[1].kind == .bullet)
        #expect(blocks[1].indent == 1)
        #expect(blocks[2].kind == .numbered)
        #expect(blocks[2].indent == 2)
    }

    // MARK: - Numbered list canonicalization

    @Test func numberedListsRenumberOnSave() {
        #expect(roundTrip("1. a\n7. b\n5. c") == "1. a\n2. b\n3. c")
    }

    @Test func numberedCountersResetAcrossInterruptions() {
        #expect(roundTrip("1. a\n2. b\n\n9. c") == "1. a\n2. b\n\n1. c")
    }

    @Test func nestedNumberedCountersAreIndependent() {
        let md = "1. a\n  1. x\n  2. y\n2. b"
        #expect(roundTrip(md) == md)
    }

    @Test func parenNumberStyleNormalizes() {
        #expect(roundTrip("1) a\n2) b") == "1. a\n2. b")
    }

    // MARK: - Todos

    @Test func todoVariantsNormalize() {
        #expect(roundTrip("- [X] shouty\n- [ ] open") == "- [x] shouty\n- [ ] open")
        // Marker-only lines (no trailing space) still count as todos.
        let blocks = NoteDocument.parse("- [ ]")
        #expect(blocks[0].kind == .todo(done: false))
    }

    // MARK: - Quotes, callouts, soft breaks

    @Test func multiLineQuoteJoinsIntoOneBlock() {
        let md = "> first  \n> second"
        let blocks = NoteDocument.parse(md)
        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .quote)
        #expect(blocks[0].plainText == "first\nsecond")
        #expect(roundTrip(md) == md)
    }

    @Test func calloutParsesIconAndText() {
        let blocks = NoteDocument.parse("> [!⚠️] watch out")
        #expect(blocks[0].kind == .callout(icon: "⚠️"))
        #expect(blocks[0].plainText == "watch out")
        #expect(roundTrip("> [!⚠️] watch out") == "> [!⚠️] watch out")
    }

    @Test func hardBreakContinuationJoinsParagraphLines() {
        let blocks = NoteDocument.parse("line one  \nline two")
        #expect(blocks.count == 1)
        #expect(blocks[0].plainText == "line one\nline two")
    }

    @Test func hardBreakDoesNotSwallowFollowingBlocks() {
        let blocks = NoteDocument.parse("para  \n- bullet")
        #expect(blocks.count == 2)
        #expect(blocks[0].plainText == "para")
        #expect(blocks[1].kind == .bullet)
    }

    // MARK: - Code fences

    @Test func codeFenceKeepsBlankLinesAndLiteralMarkers() {
        let md = "```js\nconst a = `tpl`\n\n# not a heading\n- not a bullet\n```"
        let blocks = NoteDocument.parse(md)
        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .code(language: "js"))
        #expect(blocks[0].plainText == "const a = `tpl`\n\n# not a heading\n- not a bullet")
        #expect(roundTrip(md) == md)
    }

    @Test func unterminatedCodeFenceConsumesToEnd() {
        let blocks = NoteDocument.parse("```\ndangling")
        #expect(blocks.count == 1)
        #expect(blocks[0].plainText == "dangling")
        // Normalizes to a closed fence on save.
        #expect(NoteDocument.serialize(blocks) == "```\ndangling\n```")
    }

    // MARK: - Dividers & images

    @Test func dividerVariantsAllParse() {
        for md in ["---", "***", "___"] {
            #expect(NoteDocument.parse(md)[0].kind == .divider)
        }
        #expect(roundTrip("***") == "---")
    }

    @Test func imageLineRoundTrips() {
        let md = "![screenshot](noteasset:1234.png)"
        #expect(roundTrip(md) == md)
        let remote = "![](https://example.com/pic.jpg)"
        let blocks = NoteDocument.parse(remote)
        #expect(blocks[0].kind == .image(source: "https://example.com/pic.jpg", alt: ""))
    }

    // MARK: - Inline formatting

    @Test func inlineFormattingRoundTrips() {
        let cases = [
            "plain with **bold** middle",
            "an *italic* word",
            "some `code span` here",
            "a ~~struck~~ word",
            "combo ***bold italic*** run",
            "a [link](https://fal.ai) inline",
        ]
        for md in cases {
            #expect(roundTrip(md) == md, "\(md)")
        }
    }

    @Test func boldInsideLinkTextDegradesToPlainLink() {
        // Known Foundation limitation: AttributedString(markdown:) drops
        // emphasis intents INSIDE link text, so `[**x**](url)` parses as a
        // plain link. The serializer still emits bold links when the user
        // applies Cmd+B to linked text in the editor.
        #expect(roundTrip("bold link [**inside**](https://x.com) text")
            == "bold link [inside](https://x.com) text")
    }

    @Test func boldInsideHeadingsRoundTrips() {
        // Regression: heading bases are semibold/bold system fonts, which
        // NSFontManager mis-reports — bold truth must come from .ottoBold.
        #expect(roundTrip("## With **extra** bold") == "## With **extra** bold")
        #expect(roundTrip("# Big **and bold** title") == "# Big **and bold** title")
    }

    @Test func headingsDontGrowBoldMarkers() {
        // Heading base font is bold — that must not serialize as `**`.
        #expect(roundTrip("# Big Title") == "# Big Title")
        #expect(roundTrip("## With **extra** bold") == "## With **extra** bold")
    }

    @Test func quotesDontGrowItalicMarkers() {
        // Quote base font is italic — same guard.
        #expect(roundTrip("> quoted words") == "> quoted words")
    }

    @Test func inlineAttributesLandOnRuns() {
        let attr = NoteDocument.inlineAttributed(fromMarkdown: "a **b** c", kind: .paragraph)
        #expect(attr.string == "a b c")
        var foundBold = false
        attr.enumerateAttribute(.font, in: NSRange(location: 0, length: attr.length)) { value, range, _ in
            guard let font = value as? NSFont else { return }
            if font.fontDescriptor.symbolicTraits.contains(.bold) {
                foundBold = true
                #expect((attr.string as NSString).substring(with: range) == "b")
            }
        }
        #expect(foundBold)
    }

    // MARK: - Unicode

    @Test func unicodeContentRoundTrips() {
        // Note: bold inside an H1 can't round-trip (the heading base font is
        // already bold), so the styled run lives in a paragraph here.
        let md = "🚀 emoji lead\n- 中文项目\n- [ ] görev tamamla 🇹🇷\n# 見出し\n本文の **強調** です"
        #expect(roundTrip(md) == md)
    }

    // MARK: - Separators & empties

    @Test func foreignSeparatorsNormalize() {
        let blocks = NoteDocument.parse("a\r\nb\rc\u{2028}d\u{2029}e")
        #expect(blocks.count == 5)
        #expect(NoteDocument.serialize(blocks) == "a\nb\nc\nd\ne")
    }

    @Test func emptyDocumentIsOneEmptyParagraph() {
        let blocks = NoteDocument.parse("")
        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .paragraph)
        #expect(NoteDocument.serialize(blocks) == "")
    }

    @Test func trailingNewlinePreservesEmptyLastBlock() {
        let blocks = NoteDocument.parse("a\n")
        #expect(blocks.count == 2)
        #expect(roundTrip("a\n") == "a\n")
    }

    // MARK: - Plain text, previews, word count

    @Test func plainTextStripsAllMarkers() {
        let md = "# Head\n- [x] done thing\n+ toggle\n▸ legacy\n> quote\n```\ncode\n```\n![shot](noteasset:x.png)"
        let plain = NoteDocument.plainText(md)
        #expect(!plain.contains("#"))
        #expect(!plain.contains("- ["))
        #expect(!plain.contains("+ "))
        #expect(!plain.contains("▸"))
        #expect(!plain.contains(">"))
        #expect(!plain.contains("```"))
        #expect(plain.contains("Head"))
        #expect(plain.contains("done thing"))
        #expect(plain.contains("legacy"))
        #expect(plain.contains("code"))
        #expect(plain.contains("shot"))
    }

    @Test func previewIsSingleLine() {
        let preview = NoteDocument.preview("# A\n\n- b\n▾ old toggle")
        #expect(preview == "A b old toggle")
    }

    @Test func wordCountCountsWordsNotMarkers() {
        #expect(NoteDocument.wordCount("# two words\n- [ ] three more words") == 5)
    }

    // MARK: - Asset references

    @Test func assetReferencesExtractFromContent() {
        let content = "text ![a](noteasset:11-aa.png) more ![b](noteasset:22-bb.jpeg) and ![c](https://x.com/p.png)"
        let refs = NoteAssetStore.assetReferences(in: content)
        #expect(refs == ["noteasset:11-aa.png", "noteasset:22-bb.jpeg"])
    }

    @Test func assetURLRejectsPathEscapes() {
        #expect(NoteAssetStore.url(for: "noteasset:../evil.png") == nil)
        #expect(NoteAssetStore.url(for: "noteasset:a/b.png") == nil)
        #expect(NoteAssetStore.url(for: "noteasset:ok.png") != nil)
    }

    // MARK: - Restyle (turn-into) keeps inline formatting

    @Test func restylePreservesInlineRuns() {
        let blocks = NoteDocument.parse("some **bold** text")
        let block = blocks[0]
        NoteDocument.restyle(block.storage, from: .paragraph, to: .heading2)
        block.kind = .heading2
        #expect(NoteDocument.serialize([block]) == "## some **bold** text")
    }
}
