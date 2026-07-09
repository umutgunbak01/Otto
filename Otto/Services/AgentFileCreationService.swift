import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Builds real file bytes for the `create_file` agent tool. Text formats
/// (csv / txt / md / json / …) are written by the executor directly; this
/// service covers the two formats that need actual encoding work:
///   - `.xlsx` — a minimal OOXML workbook (one sheet, inline strings) packed
///     into a hand-rolled ZIP container with STORED entries, so we don't
///     need a zip dependency. Opens in Excel, Numbers, and Quick Look.
///   - `.pdf`  — markdown-ish text rendered through CoreText into paginated
///     US-Letter pages (same drawing approach as `PDFExportService`).
enum AgentFileCreation {

    enum BuildError: LocalizedError {
        case emptyRows
        case tooManyRows(Int)
        case rowTooWide(Int)
        case pdfRenderFailed

        var errorDescription: String? {
            switch self {
            case .emptyRows:
                return "The 'rows' array is empty — pass at least one row of cell values."
            case .tooManyRows(let n):
                return "Too many rows (\(n)); the limit is \(maxRows)."
            case .rowTooWide(let n):
                return "A row has \(n) cells; the limit is \(maxColumns) columns."
            case .pdfRenderFailed:
                return "PDF rendering failed."
            }
        }
    }

    static let maxRows = 20_000
    static let maxColumns = 256

    // MARK: - XLSX

    /// Cell style ids — must match the `cellXfs` order in the styles part.
    private enum CellStyle: Int {
        case none = 0
        /// Bold on a light fill with a bottom border — the header row.
        case header = 1
        /// Faint fill — every other data row (banded-table look).
        case banded = 2
    }

    /// Single-sheet convenience wrapper around the multi-sheet builder.
    static func xlsxData(rows: [[Any]], sheetName: String) throws -> Data {
        try xlsxData(sheets: [(name: sheetName, rows: rows)])
    }

    /// Build a styled multi-sheet .xlsx workbook. Each sheet's `rows` is
    /// JSON-decoded cell data: strings become inline-string cells, numbers
    /// stay numeric (so Excel can sum them), booleans render as TRUE/FALSE
    /// text, nulls as empty cells. Every sheet gets a bold frozen header row,
    /// an autofilter, banded data rows, and column widths sized to content.
    static func xlsxData(sheets: [(name: String, rows: [[Any]])]) throws -> Data {
        guard !sheets.isEmpty, sheets.allSatisfy({ !$0.rows.isEmpty }) else { throw BuildError.emptyRows }
        let totalRows = sheets.reduce(0) { $0 + $1.rows.count }
        guard totalRows <= maxRows else { throw BuildError.tooManyRows(totalRows) }
        if let widest = sheets.flatMap({ $0.rows.map(\.count) }).max(), widest > maxColumns {
            throw BuildError.rowTooWide(widest)
        }

        // Sheet names: sanitized, then de-duplicated (Excel rejects repeats).
        var usedNames: [String] = []
        for (name, _) in sheets {
            var candidate = sanitizedSheetName(name)
            if usedNames.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
                var n = 2
                repeat {
                    let suffix = " \(n)"
                    candidate = String(sanitizedSheetName(name).prefix(31 - suffix.count)) + suffix
                    n += 1
                } while usedNames.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame })
            }
            usedNames.append(candidate)
        }

        var contentTypeOverrides = ""
        var sheetRefs = ""
        var relEntries = ""
        var zipEntries: [(name: String, data: Data)] = []

        for (index, sheet) in sheets.enumerated() {
            let sheetId = index + 1
            contentTypeOverrides += "<Override PartName=\"/xl/worksheets/sheet\(sheetId).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
            sheetRefs += "<sheet name=\"\(xmlEscape(usedNames[index]))\" sheetId=\"\(sheetId)\" r:id=\"rId\(sheetId)\"/>"
            relEntries += "<Relationship Id=\"rId\(sheetId)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(sheetId).xml\"/>"
            zipEntries.append(("xl/worksheets/sheet\(sheetId).xml", Data(worksheetXML(rows: sheet.rows).utf8)))
        }
        let stylesRelId = sheets.count + 1

        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\(contentTypeOverrides)<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>
        """
        let rootRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """
        let workbook = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>\(sheetRefs)</sheets></workbook>
        """
        let workbookRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(relEntries)<Relationship Id="rId\(stylesRelId)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
        """
        // fills[1] must be gray125 per the spec's implicit-defaults quirk;
        // fills[2] is the header fill, fills[3] the banded-row tint. cellXfs
        // order must track the `CellStyle` enum.
        let styles = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="2"><font><sz val="12"/><name val="Calibri"/><family val="2"/></font><font><b/><sz val="12"/><color rgb="FF1A2733"/><name val="Calibri"/><family val="2"/></font></fonts><fills count="4"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FFE9EDF2"/><bgColor indexed="64"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FFF6F8FA"/><bgColor indexed="64"/></patternFill></fill></fills><borders count="2"><border><left/><right/><top/><bottom/><diagonal/></border><border><left/><right/><top/><bottom style="thin"><color rgb="FFC7CDD6"/></bottom><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="3"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment vertical="center"/></xf><xf numFmtId="0" fontId="0" fillId="3" borderId="0" xfId="0" applyFill="1"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>
        """

        return zipArchive(entries: [
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(rootRels.utf8)),
            ("xl/workbook.xml", Data(workbook.utf8)),
            ("xl/_rels/workbook.xml.rels", Data(workbookRels.utf8)),
            ("xl/styles.xml", Data(styles.utf8))
        ] + zipEntries)
    }

    /// One worksheet: frozen styled header row (when there are data rows
    /// under it), content-sized column widths, banded rows, autofilter.
    private static func worksheetXML(rows: [[Any]]) -> String {
        let columnCount = rows.map(\.count).max() ?? 1
        let hasHeader = rows.count > 1

        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        """
        if hasHeader {
            xml += "<sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/></sheetView></sheetViews>"
        }

        // Column widths ≈ longest rendered line per column (Excel width units
        // are roughly characters), padded and clamped so one huge notes cell
        // can't blow the layout up.
        xml += "<cols>"
        for c in 0..<columnCount {
            var maxLen = 4
            for row in rows where c < row.count {
                maxLen = max(maxLen, displayLength(row[c]))
            }
            let width = min(Double(maxLen) + 3.0, 64.0)
            xml += "<col min=\"\(c + 1)\" max=\"\(c + 1)\" width=\"\(String(format: "%.1f", width))\" customWidth=\"1\"/>"
        }
        xml += "</cols><sheetData>"

        for (r, row) in rows.enumerated() {
            let style: CellStyle = {
                guard hasHeader else { return .none }
                if r == 0 { return .header }
                return r % 2 == 0 ? .banded : .none  // 2nd data row, 4th, …
            }()
            xml += "<row r=\"\(r + 1)\">"
            // Emit every column up to the sheet's width so header/band fills
            // paint the whole row, not just cells that happen to hold values.
            for c in 0..<columnCount {
                let value: Any = c < row.count ? row[c] : NSNull()
                xml += cellXML(ref: "\(columnName(c))\(r + 1)", value: value, style: style)
            }
            xml += "</row>"
        }
        xml += "</sheetData>"

        // Filter dropdowns only make sense on a real table.
        if hasHeader && rows.count > 2 {
            xml += "<autoFilter ref=\"A1:\(columnName(columnCount - 1))\(rows.count)\"/>"
        }
        xml += "</worksheet>"
        return xml
    }

    /// Longest line of the value's rendered text — multi-line cells size by
    /// their widest line, not their total length.
    private static func displayLength(_ value: Any) -> Int {
        if value is NSNull { return 0 }
        if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return 5 }
            return n.stringValue.count
        }
        let text = value as? String ?? String(describing: value)
        return text.components(separatedBy: "\n").map(\.count).max() ?? 0
    }

    private static func cellXML(ref: String, value: Any, style: CellStyle = .none) -> String {
        let styleAttr = style == .none ? "" : " s=\"\(style.rawValue)\""
        if value is NSNull {
            // Styled empties keep header/band fills continuous across gaps.
            return style == .none ? "" : "<c r=\"\(ref)\"\(styleAttr)/>"
        }
        if let n = value as? NSNumber {
            // NSNumber wraps both numbers and JSON booleans; only a genuine
            // CFBoolean should render as text — `as? Bool` alone would also
            // catch 0/1 integers.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return "<c r=\"\(ref)\"\(styleAttr) t=\"inlineStr\"><is><t>\(n.boolValue ? "TRUE" : "FALSE")</t></is></c>"
            }
            return "<c r=\"\(ref)\"\(styleAttr)><v>\(n.stringValue)</v></c>"
        }
        let text = value as? String ?? String(describing: value)
        if text.isEmpty {
            return style == .none ? "" : "<c r=\"\(ref)\"\(styleAttr)/>"
        }
        return "<c r=\"\(ref)\"\(styleAttr) t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xmlEscape(text))</t></is></c>"
    }

    /// 0 → A, 25 → Z, 26 → AA …
    private static func columnName(_ index: Int) -> String {
        var i = index
        var name = ""
        repeat {
            name = String(UnicodeScalar(UInt8(65 + i % 26))) + name
            i = i / 26 - 1
        } while i >= 0
        return name
    }

    /// Excel sheet names: non-empty, ≤31 chars, no []:*?/\ characters.
    private static func sanitizedSheetName(_ raw: String) -> String {
        let stripped = raw
            .components(separatedBy: CharacterSet(charactersIn: "[]:*?/\\"))
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let clipped = String(stripped.prefix(31))
        return clipped.isEmpty ? "Sheet1" : clipped
    }

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - ZIP container (STORED entries, no compression)

    private static func zipArchive(entries: [(name: String, data: Data)]) -> Data {
        var out = Data()
        var central = Data()
        let (dosTime, dosDate) = dosDateTime(Date())

        for (name, data) in entries {
            let nameBytes = Array(name.utf8)
            let crc = crc32(data)
            let size = UInt32(data.count)
            let offset = UInt32(out.count)

            // Local file header
            out.append(le32(0x0403_4B50))
            out.append(le16(20))                      // version needed
            out.append(le16(0x0800))                  // flags: UTF-8 names
            out.append(le16(0))                       // method: stored
            out.append(le16(dosTime))
            out.append(le16(dosDate))
            out.append(le32(crc))
            out.append(le32(size))                    // compressed
            out.append(le32(size))                    // uncompressed
            out.append(le16(UInt16(nameBytes.count)))
            out.append(le16(0))                       // extra length
            out.append(contentsOf: nameBytes)
            out.append(data)

            // Central directory record
            central.append(le32(0x0201_4B50))
            central.append(le16(20))                  // version made by
            central.append(le16(20))                  // version needed
            central.append(le16(0x0800))
            central.append(le16(0))
            central.append(le16(dosTime))
            central.append(le16(dosDate))
            central.append(le32(crc))
            central.append(le32(size))
            central.append(le32(size))
            central.append(le16(UInt16(nameBytes.count)))
            central.append(le16(0))                   // extra length
            central.append(le16(0))                   // comment length
            central.append(le16(0))                   // disk number
            central.append(le16(0))                   // internal attrs
            central.append(le32(0))                   // external attrs
            central.append(le32(offset))
            central.append(contentsOf: nameBytes)
        }

        let cdOffset = UInt32(out.count)
        out.append(central)
        // End of central directory
        out.append(le32(0x0605_4B50))
        out.append(le16(0))
        out.append(le16(0))
        out.append(le16(UInt16(entries.count)))
        out.append(le16(UInt16(entries.count)))
        out.append(le32(UInt32(central.count)))
        out.append(le32(cdOffset))
        out.append(le16(0))
        return out
    }

    private static let crcTable: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                if c & 1 != 0 {
                    c = 0xEDB8_8320 ^ (c >> 1)
                } else {
                    c >>= 1
                }
            }
            table[i] = c
        }
        return table
    }()

    private static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data {
            c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
        }
        return c ^ 0xFFFF_FFFF
    }

    private static func dosDateTime(_ date: Date) -> (time: UInt16, date: UInt16) {
        let comp = Calendar(identifier: .gregorian)
            .dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year: Int = max(comp.year ?? 1980, 1980)
        let month: Int = comp.month ?? 1
        let day: Int = comp.day ?? 1
        let hour: Int = comp.hour ?? 0
        let minute: Int = comp.minute ?? 0
        let second: Int = comp.second ?? 0
        let d: Int = ((year - 1980) << 9) | (month << 5) | day
        let t: Int = (hour << 11) | (minute << 5) | (second / 2)
        return (UInt16(t), UInt16(d))
    }

    private static func le16(_ v: UInt16) -> Data {
        Data([UInt8(v & 0xFF), UInt8(v >> 8)])
    }

    private static func le32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)])
    }

    // MARK: - PDF

    /// Render markdown-ish text into a paginated US-Letter PDF. Supports the
    /// subset agents actually emit: #/##/### headings, - and * bullets,
    /// **bold** spans, | table rows and 4-space-indented lines as monospace.
    /// Fixed black-on-white — PDF output must not follow the app's appearance.
    static func pdfData(markdown: String) throws -> Data {
        #if canImport(AppKit)
        let body = attributedString(fromMarkdownLite: markdown)
        let pageWidth: CGFloat = 612
        let pageHeight: CGFloat = 792
        let margin: CGFloat = 54
        let contentRect = CGRect(
            x: margin, y: margin,
            width: pageWidth - margin * 2, height: pageHeight - margin * 2
        )

        let output = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        guard let consumer = CGDataConsumer(data: output),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw BuildError.pdfRenderFailed
        }

        let framesetter = CTFramesetterCreateWithAttributedString(body)
        let path = CGPath(rect: contentRect, transform: nil)
        var location = 0
        repeat {
            ctx.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(
                framesetter, CFRange(location: location, length: 0), path, nil
            )
            CTFrameDraw(frame, ctx)
            ctx.endPDFPage()
            let visible = CTFrameGetVisibleStringRange(frame)
            // max(…, 1) guards against a zero-progress loop when a single
            // unbreakable run can't fit the frame at all.
            location += max(visible.length, 1)
        } while location < body.length
        ctx.closePDF()
        return output as Data
        #else
        throw BuildError.pdfRenderFailed
        #endif
    }

    #if canImport(AppKit)
    private static func attributedString(fromMarkdownLite text: String) -> NSAttributedString {
        let bodyFont = NSFont.systemFont(ofSize: 11)
        let boldFont = NSFont.boldSystemFont(ofSize: 11)
        let h1Font = NSFont.systemFont(ofSize: 20, weight: .bold)
        let h2Font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        let h3Font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        let monoFont = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular)
        let ink = NSColor.black

        func paragraph(spacingBefore: CGFloat = 0, spacingAfter: CGFloat = 4, indent: CGFloat = 0) -> NSParagraphStyle {
            let ps = NSMutableParagraphStyle()
            ps.paragraphSpacingBefore = spacingBefore
            ps.paragraphSpacing = spacingAfter
            ps.lineSpacing = 2
            ps.firstLineHeadIndent = indent
            ps.headIndent = indent + (indent > 0 ? 11 : 0)  // wrap bullets under their text
            return ps
        }

        /// Body text with **bold** spans resolved.
        func inlineStyled(_ line: String, font: NSFont, bold: NSFont, style: NSParagraphStyle) -> NSAttributedString {
            let out = NSMutableAttributedString()
            let pieces = line.components(separatedBy: "**")
            for (i, piece) in pieces.enumerated() {
                guard !piece.isEmpty else { continue }
                // Odd segments sit between ** markers → bold (only when the
                // markers are balanced; a dangling ** renders literally).
                let isBold = i % 2 == 1 && pieces.count % 2 == 1
                out.append(NSAttributedString(string: piece, attributes: [
                    .font: isBold ? bold : font,
                    .foregroundColor: ink,
                    .paragraphStyle: style
                ]))
            }
            return out
        }

        let out = NSMutableAttributedString()
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let piece: NSAttributedString
            if line.hasPrefix("### ") {
                piece = NSAttributedString(string: String(line.dropFirst(4)), attributes: [
                    .font: h3Font, .foregroundColor: ink,
                    .paragraphStyle: paragraph(spacingBefore: 8, spacingAfter: 3)
                ])
            } else if line.hasPrefix("## ") {
                piece = NSAttributedString(string: String(line.dropFirst(3)), attributes: [
                    .font: h2Font, .foregroundColor: ink,
                    .paragraphStyle: paragraph(spacingBefore: 12, spacingAfter: 4)
                ])
            } else if line.hasPrefix("# ") {
                piece = NSAttributedString(string: String(line.dropFirst(2)), attributes: [
                    .font: h1Font, .foregroundColor: ink,
                    .paragraphStyle: paragraph(spacingBefore: 14, spacingAfter: 6)
                ])
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                let content = inlineStyled(String(line.dropFirst(2)), font: bodyFont, bold: boldFont, style: paragraph(spacingAfter: 2, indent: 10))
                let bullet = NSMutableAttributedString(string: "•  ", attributes: [
                    .font: bodyFont, .foregroundColor: ink,
                    .paragraphStyle: paragraph(spacingAfter: 2, indent: 10)
                ])
                bullet.append(content)
                piece = bullet
            } else if line.hasPrefix("|") || rawLine.hasPrefix("    ") {
                piece = NSAttributedString(string: rawLine, attributes: [
                    .font: monoFont, .foregroundColor: ink,
                    .paragraphStyle: paragraph(spacingAfter: 1)
                ])
            } else if line == "---" || line == "***" {
                piece = NSAttributedString(string: "⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯", attributes: [
                    .font: bodyFont, .foregroundColor: NSColor.gray,
                    .paragraphStyle: paragraph(spacingBefore: 6, spacingAfter: 6)
                ])
            } else {
                piece = inlineStyled(line, font: bodyFont, bold: boldFont, style: paragraph())
            }
            out.append(piece)
            out.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
        }
        return out
    }
    #endif
}
