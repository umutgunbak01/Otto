import Testing
import Foundation
@testable import Otto

struct OttoTests {

    // MARK: - OttoTools tool-name canonicalization

    @Test func canonicalToolNameStripsMcpPrefix() {
        #expect(OttoTools.canonicalToolName("mcp__otto__attach_item_preview") == "attach_item_preview")
        #expect(OttoTools.canonicalToolName("mcp__calendar__list_events") == "list_events")
    }

    @Test func canonicalToolNameLeavesBareNamesAlone() {
        #expect(OttoTools.canonicalToolName("attach_item_preview") == "attach_item_preview")
        #expect(OttoTools.canonicalToolName("search_items") == "search_items")
        // A lone "mcp__" with no second separator shouldn't be mangled.
        #expect(OttoTools.canonicalToolName("mcp__weird") == "mcp__weird")
    }

    @Test func isAttachItemPreviewMatchesAllNamings() {
        #expect(OttoTools.isAttachItemPreview("attach_item_preview"))
        #expect(OttoTools.isAttachItemPreview("mcp__otto__attach_item_preview"))
        #expect(OttoTools.isAttachItemPreview("Attach Item Preview"))
        #expect(!OttoTools.isAttachItemPreview("search_items"))
        #expect(!OttoTools.isAttachItemPreview("mcp__otto__get_item"))
    }

    // MARK: - Preview type mapping

    @Test func previewContentTypeMapsSnakeCaseNames() {
        #expect(OttoTools.previewContentType("network") == .networkHub)
        #expect(OttoTools.previewContentType("x_post") == .xPost)
        #expect(OttoTools.previewContentType("x_follower") == .xFollower)
        #expect(OttoTools.previewContentType("x_dm") == .xDm)
        #expect(OttoTools.previewContentType("todo") == .todo)
        #expect(OttoTools.previewContentType("connection") == .connection)
        #expect(OttoTools.previewContentType("file") == .file)
        #expect(OttoTools.previewContentType("nonsense") == nil)
    }

    // MARK: - Preview recovery from the executor's result line

    @Test func parsePreviewResultExtractsTypeAndId() {
        let id = UUID()
        let parsed = OttoTools.parsePreviewResult("Attached preview: connection \(id.uuidString) — Adam Shuaib, PhD")
        #expect(parsed?.typeString == "connection")
        #expect(parsed?.id == id)
    }

    @Test func parsePreviewResultHandlesJsonWrappedSummary() {
        // Over MCP the tool result reaches the UI wrapped as {"result": "..."}.
        let id = UUID()
        let parsed = OttoTools.parsePreviewResult(#"{"result": "Attached preview: meeting \#(id.uuidString) — E2vc webinar"}"#)
        #expect(parsed?.typeString == "meeting")
        #expect(parsed?.id == id)
    }

    @Test func parsePreviewResultRejectsErrors() {
        #expect(OttoTools.parsePreviewResult(#"{"error": "No connection found with id 361F9B43."}"#) == nil)
        #expect(OttoTools.parsePreviewResult("Attached preview: connection not-a-uuid — x") == nil)
    }

    // MARK: - Inline otto:// item links

    @Test func parseItemURLHandlesAllTypeSpellings() throws {
        let id = UUID()
        let cases: [(String, ContentType)] = [
            ("otto://connection/\(id.uuidString)", .connection),
            ("otto://network/\(id.uuidString)", .networkHub),
            ("otto://x_post/\(id.uuidString)", .xPost),
            ("otto://meeting/\(id.uuidString)", .meeting),
            ("otto://file/\(id.uuidString)", .file),
        ]
        for (raw, expected) in cases {
            let url = try #require(URL(string: raw))
            let parsed = OttoTools.parseItemURL(url)
            #expect(parsed?.type == expected)
            #expect(parsed?.id == id)
        }
    }

    @Test func parseItemURLRejectsForeignSchemesAndGarbage() throws {
        #expect(OttoTools.parseItemURL(try #require(URL(string: "https://example.com/x"))) == nil)
        #expect(OttoTools.parseItemURL(try #require(URL(string: "otto://connection/not-a-uuid"))) == nil)
        #expect(OttoTools.parseItemURL(try #require(URL(string: "otto://nonsense/\(UUID().uuidString)"))) == nil)
        #expect(OttoTools.parseItemURL(try #require(URL(string: "otto://connection"))) == nil)
    }

    // MARK: - Attachment flattening (uploads reaching the model)

    @Test func flattenInlinesTextAttachmentContents() {
        let md = ChatAttachment(
            filename: "notes.md",
            mediaType: "text/markdown",
            data: Data("# Title\n\nSome **bold** body".utf8)
        )
        let turn = ChatTurn(role: "user", blocks: [.text("summarize this")], attachments: [md])
        let flat = ChatTranscript.flatten([turn])
        #expect(flat.contains("summarize this"))
        #expect(flat.contains("Attached file: notes.md"))
        #expect(flat.contains("# Title"))
        #expect(flat.contains("Some **bold** body"))
        #expect(flat.contains("End of attached file: notes.md"))
    }

    @Test func flattenStubsBinaryAttachments() {
        let img = ChatAttachment(
            filename: "photo.png",
            mediaType: "image/png",
            data: Data([0x89, 0x50, 0x4E, 0x47])
        )
        let turn = ChatTurn(role: "user", blocks: [.text("look at this")], attachments: [img])
        let flat = ChatTranscript.flatten([turn])
        #expect(flat.contains("photo.png"))
        #expect(flat.contains("content not inlined"))
    }

    @Test func flattenTruncatesOversizedTextAttachments() {
        let big = String(repeating: "a", count: 40_000)
        let file = ChatAttachment(filename: "big.log", mediaType: "text/plain", data: Data(big.utf8))
        let turn = ChatTurn(role: "user", blocks: [.text("read this")], attachments: [file])
        let flat = ChatTranscript.flatten([turn])
        #expect(flat.contains("truncated"))
        #expect(flat.count < 33_000)  // 32k cap + markers, not the raw 40k
    }

    @Test func markdownAttachmentClassification() {
        let md = ChatAttachment(filename: "README.md", mediaType: "text/markdown", data: Data("hello".utf8))
        #expect(md.kind == .text)
        #expect(md.isMarkdown)
        #expect(md.textContent == "hello")

        let csv = ChatAttachment(filename: "data.csv", mediaType: "text/csv", data: Data("a,b".utf8))
        #expect(csv.kind == .text)
        #expect(!csv.isMarkdown)

        let xlsx = ChatAttachment(filename: "sheet.xlsx", mediaType: "application/vnd.ms-excel", data: Data([0x50]))
        #expect(xlsx.kind == .binary)
        #expect(xlsx.textContent == nil)
    }

    @Test func markdownFallbackMediaType() {
        #expect(ChatAttachment.fallbackMediaType(forExtension: "md") == "text/markdown")
        #expect(ChatAttachment.fallbackMediaType(forExtension: "MARKDOWN") == "text/markdown")
        #expect(ChatAttachment.fallbackMediaType(forExtension: "bin") == "application/octet-stream")
    }

    // MARK: - ACP tool_call rawInput parsing

    @Test func acpToolCallCarriesRawInput() throws {
        let line = """
        {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"tool_call","toolCallId":"tc1","title":"mcp__otto__attach_item_preview","kind":"fetch","rawInput":{"type":"connection","id":"E70011F6-539E-44BD-AC51-C5800F01C526"}}}}
        """
        guard case .sessionUpdate(_, .toolCall(let id, let title, _, let rawInput)) = try #require(ACPParser.parse(line: line)) else {
            Issue.record("Expected a toolCall session update")
            return
        }
        #expect(id == "tc1")
        #expect(title == "mcp__otto__attach_item_preview")
        #expect(rawInput?["type"] as? String == "connection")
        #expect(rawInput?["id"] as? String == "E70011F6-539E-44BD-AC51-C5800F01C526")
    }

    @Test func acpToolCallUpdateCarriesRawInputAndSummary() throws {
        let line = """
        {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"tool_call_update","toolCallId":"tc1","status":"completed","rawInput":{"type":"todo","id":"11111111-2222-3333-4444-555555555555"},"content":[{"type":"content","content":{"type":"text","text":"Attached preview: todo 11111111-2222-3333-4444-555555555555 — Ship it"}}]}}}
        """
        guard case .sessionUpdate(_, .toolCallUpdate(let id, let status, let summary, let isError, let rawInput)) = try #require(ACPParser.parse(line: line)) else {
            Issue.record("Expected a toolCallUpdate session update")
            return
        }
        #expect(id == "tc1")
        #expect(status == "completed")
        #expect(!isError)
        #expect(summary.contains("Attached preview: todo"))
        #expect(rawInput?["type"] as? String == "todo")
    }

    @Test func acpToolCallWithoutRawInputStillParses() throws {
        let line = """
        {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"tool_call","toolCallId":"tc2","title":"mcp__otto__search_items"}}}
        """
        guard case .sessionUpdate(_, .toolCall(let id, _, _, let rawInput)) = try #require(ACPParser.parse(line: line)) else {
            Issue.record("Expected a toolCall session update")
            return
        }
        #expect(id == "tc2")
        #expect(rawInput == nil)
    }
}
