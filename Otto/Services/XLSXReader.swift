import Foundation
import Compression

/// Dependency-free .xlsx reader — enough OOXML to turn a workbook into rows
/// of display strings. Powers the in-app spreadsheet preview (agent-created
/// files via `create_file`, plus anything the user imports) and search-time
/// text extraction in `FileStorageService`.
///
/// Scope: cell values only (shared strings, inline strings, numbers, bools,
/// formula results). No styles, so date cells show as raw serial numbers —
/// acceptable for a preview; Quick Look / Excel remain the fidelity path.
enum XLSXReader {

    struct Sheet {
        let name: String
        let rows: [[String]]
    }

    enum ReadError: LocalizedError {
        case notAZip
        case corrupt(String)
        case noSheets

        var errorDescription: String? {
            switch self {
            case .notAZip: return "Not a valid xlsx (zip) file."
            case .corrupt(let why): return "Corrupt xlsx: \(why)"
            case .noSheets: return "No worksheets found."
            }
        }
    }

    /// Hard ceiling on a single decompressed part — a zip bomb must not
    /// balloon into app memory.
    private static let maxPartBytes = 64 * 1024 * 1024

    // MARK: - Public API

    /// Parse every worksheet into rows of strings, in workbook order.
    static func read(url: URL, maxRowsPerSheet: Int = 5_000) throws -> [Sheet] {
        let data = try Data(contentsOf: url)
        let entries = try zipEntries(data)
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })

        func part(_ name: String) -> Data? {
            byName[name].flatMap { try? extract($0, from: data) }
        }

        let shared = part("xl/sharedStrings.xml").map(parseSharedStrings) ?? []

        // Sheet order + names come from workbook.xml; the rId → part-path
        // mapping from workbook.xml.rels. Fall back to sheetN.xml enumeration
        // when either part is missing or unparseable.
        var sheetRefs: [(name: String, path: String)] = []
        if let workbook = part("xl/workbook.xml") {
            let declared = parseWorkbookSheets(workbook)
            let rels = part("xl/_rels/workbook.xml.rels").map(parseRelationships) ?? [:]
            for decl in declared {
                guard let target = rels[decl.relId] else { continue }
                sheetRefs.append((decl.name, normalizedPartPath(target)))
            }
        }
        if sheetRefs.isEmpty {
            let paths = entries.map(\.name)
                .filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            sheetRefs = paths.enumerated().map { ("Sheet \($0.offset + 1)", $0.element) }
        }
        guard !sheetRefs.isEmpty else { throw ReadError.noSheets }

        var sheets: [Sheet] = []
        for ref in sheetRefs {
            guard let xml = part(ref.path) else { continue }
            let rows = parseSheet(xml, sharedStrings: shared, maxRows: maxRowsPerSheet)
            sheets.append(Sheet(name: ref.name, rows: rows))
        }
        guard !sheets.isEmpty else { throw ReadError.noSheets }
        return sheets
    }

    /// One sheet as RFC-4180-ish CSV — feeds the same table UI the CSV
    /// preview uses.
    static func csv(for sheet: Sheet) -> String {
        sheet.rows.map { row in
            row.map { field in
                if field.contains(",") || field.contains("\"") || field.contains("\n") {
                    return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }
                return field
            }.joined(separator: ",")
        }.joined(separator: "\n")
    }

    /// Whole workbook flattened to text for search indexing / `read_file`.
    /// Multi-sheet workbooks get a `# Sheet:` header per sheet.
    static func csvText(from url: URL, maxChars: Int = 100_000) -> String? {
        guard let sheets = try? read(url: url, maxRowsPerSheet: 2_000), !sheets.isEmpty else {
            return nil
        }
        var out = ""
        for sheet in sheets {
            if sheets.count > 1 {
                out += "# Sheet: \(sheet.name)\n"
            }
            out += csv(for: sheet) + "\n"
            if out.count >= maxChars { break }
        }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count <= maxChars ? trimmed : String(trimmed.prefix(maxChars))
    }

    // MARK: - ZIP container

    private struct ZipEntry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private static func zipEntries(_ data: Data) throws -> [ZipEntry] {
        let minEOCD = 22
        guard data.count >= minEOCD else { throw ReadError.notAZip }

        // End-of-central-directory record: scan backwards (the trailing
        // comment can push it up to ~64 KB from the end).
        var eocd = -1
        let scanFloor = max(0, data.count - 66_000)
        var i = data.count - minEOCD
        while i >= scanFloor {
            if data[i] == 0x50, data[i + 1] == 0x4B, data[i + 2] == 0x05, data[i + 3] == 0x06 {
                eocd = i
                break
            }
            i -= 1
        }
        guard eocd >= 0 else { throw ReadError.notAZip }

        let count = Int(u16(data, eocd + 10))
        let cdSize = Int(u32(data, eocd + 12))
        let cdOffset = Int(u32(data, eocd + 16))
        guard cdOffset >= 0, cdSize >= 0, cdOffset + cdSize <= data.count else {
            throw ReadError.corrupt("central directory out of bounds")
        }

        var entries: [ZipEntry] = []
        var p = cdOffset
        for _ in 0..<count {
            guard p + 46 <= data.count, u32(data, p) == 0x0201_4B50 else { break }
            let method = u16(data, p + 10)
            let compressedSize = Int(u32(data, p + 20))
            let uncompressedSize = Int(u32(data, p + 24))
            let nameLen = Int(u16(data, p + 28))
            let extraLen = Int(u16(data, p + 30))
            let commentLen = Int(u16(data, p + 32))
            let localOffset = Int(u32(data, p + 42))
            guard p + 46 + nameLen <= data.count else { break }
            let name = String(data: data.subdata(in: (p + 46)..<(p + 46 + nameLen)), encoding: .utf8) ?? ""
            entries.append(ZipEntry(
                name: name,
                method: method,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localOffset
            ))
            p += 46 + nameLen + extraLen + commentLen
        }
        return entries
    }

    private static func extract(_ entry: ZipEntry, from data: Data) throws -> Data {
        let p = entry.localHeaderOffset
        guard p + 30 <= data.count, u32(data, p) == 0x0403_4B50 else {
            throw ReadError.corrupt("bad local header for \(entry.name)")
        }
        // Name/extra lengths in the LOCAL header can differ from the central
        // directory's copy — always re-read them here.
        let nameLen = Int(u16(data, p + 26))
        let extraLen = Int(u16(data, p + 28))
        let start = p + 30 + nameLen + extraLen
        guard start + entry.compressedSize <= data.count else {
            throw ReadError.corrupt("entry data out of bounds for \(entry.name)")
        }
        guard entry.uncompressedSize <= maxPartBytes else {
            throw ReadError.corrupt("\(entry.name) too large")
        }
        let payload = data.subdata(in: start..<(start + entry.compressedSize))
        switch entry.method {
        case 0:
            return payload
        case 8:
            return try inflate(payload, expectedSize: entry.uncompressedSize)
        default:
            throw ReadError.corrupt("unsupported compression method \(entry.method)")
        }
    }

    /// Raw DEFLATE (RFC 1951) — which is exactly what Apple's COMPRESSION_ZLIB
    /// implements (no zlib header), and exactly what zip entries store.
    private static func inflate(_ input: Data, expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        var out = Data(count: expectedSize)
        let written = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let dstPtr = dst.bindMemory(to: UInt8.self).baseAddress,
                      let srcPtr = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    dstPtr, dst.count,
                    srcPtr, src.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { throw ReadError.corrupt("deflate decode failed") }
        if written < out.count { out.removeSubrange(written..<out.count) }
        return out
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    // MARK: - Part path resolution

    /// Relationship targets are relative to `xl/` ("worksheets/sheet1.xml")
    /// or package-absolute ("/xl/worksheets/sheet1.xml").
    private static func normalizedPartPath(_ target: String) -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        if target.hasPrefix("xl/") { return target }
        return "xl/" + target
    }

    // MARK: - XML: shared strings

    private static func parseSharedStrings(_ xml: Data) -> [String] {
        let delegate = SharedStringsDelegate()
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        parser.parse()
        return delegate.strings
    }

    private final class SharedStringsDelegate: NSObject, XMLParserDelegate {
        var strings: [String] = []
        private var current = ""
        private var inT = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "si" { current = "" }
            // Rich-text runs put multiple <t> inside one <si>; concatenate.
            else if name == "t" { inT = true }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inT { current += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "t" { inT = false }
            else if name == "si" { strings.append(current) }
        }
    }

    // MARK: - XML: workbook + rels

    private static func parseWorkbookSheets(_ xml: Data) -> [(name: String, relId: String)] {
        let delegate = WorkbookDelegate()
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        parser.parse()
        return delegate.sheets
    }

    private final class WorkbookDelegate: NSObject, XMLParserDelegate {
        var sheets: [(name: String, relId: String)] = []

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            guard name == "sheet" else { return }
            let sheetName = attributes["name"] ?? "Sheet \(sheets.count + 1)"
            guard let relId = attributes["r:id"] ?? attributes["id"] else { return }
            sheets.append((sheetName, relId))
        }
    }

    private static func parseRelationships(_ xml: Data) -> [String: String] {
        let delegate = RelationshipsDelegate()
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        parser.parse()
        return delegate.targets
    }

    private final class RelationshipsDelegate: NSObject, XMLParserDelegate {
        var targets: [String: String] = [:]

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            guard name == "Relationship",
                  let id = attributes["Id"],
                  let target = attributes["Target"] else { return }
            targets[id] = target
        }
    }

    // MARK: - XML: worksheet

    private static func parseSheet(_ xml: Data, sharedStrings: [String], maxRows: Int) -> [[String]] {
        let delegate = SheetDelegate(sharedStrings: sharedStrings, maxRows: maxRows)
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        parser.parse()  // abortParsing() on row cap surfaces as a parse error — rows are still valid
        return delegate.rows
    }

    private final class SheetDelegate: NSObject, XMLParserDelegate {
        private let sharedStrings: [String]
        private let maxRows: Int
        var rows: [[String]] = []

        private var currentRow: [String] = []
        private var nextColumn = 0
        private var cellColumn = 0
        private var cellType = ""
        private var value = ""
        private var inlineText = ""
        private var inV = false
        private var inT = false

        init(sharedStrings: [String], maxRows: Int) {
            self.sharedStrings = sharedStrings
            self.maxRows = maxRows
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            switch name {
            case "row":
                currentRow = []
                nextColumn = 0
            case "c":
                cellType = attributes["t"] ?? ""
                cellColumn = attributes["r"].flatMap(Self.columnIndex) ?? nextColumn
                value = ""
                inlineText = ""
            case "v":
                inV = true
            case "t":
                inT = true
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inV { value += string }
            else if inT { inlineText += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "v":
                inV = false
            case "t":
                inT = false
            case "c":
                let text: String
                switch cellType {
                case "s":
                    let idx = Int(value) ?? -1
                    text = sharedStrings.indices.contains(idx) ? sharedStrings[idx] : ""
                case "inlineStr":
                    text = inlineText
                case "b":
                    text = value == "1" ? "TRUE" : "FALSE"
                default:
                    // Numbers, "str" (formula results), "e" (errors) — the
                    // raw value is the best display we have without styles.
                    text = value.isEmpty ? inlineText : value
                }
                // Place by cell reference so skipped (empty) cells keep
                // later columns aligned.
                while currentRow.count < cellColumn { currentRow.append("") }
                if currentRow.count == cellColumn {
                    currentRow.append(text)
                } else if cellColumn < currentRow.count {
                    currentRow[cellColumn] = text
                }
                nextColumn = cellColumn + 1
            case "row":
                if rows.count < maxRows {
                    rows.append(currentRow)
                } else {
                    parser.abortParsing()
                }
            default:
                break
            }
        }

        /// "BC12" → 54 (0-based column index from the letters prefix).
        private static func columnIndex(_ ref: String) -> Int? {
            var idx = 0
            var sawLetter = false
            for ch in ref.uppercased() {
                guard let ascii = ch.asciiValue, ascii >= 65, ascii <= 90 else { break }
                idx = idx * 26 + Int(ascii - 64)
                sawLetter = true
            }
            return sawLetter ? idx - 1 : nil
        }
    }
}
