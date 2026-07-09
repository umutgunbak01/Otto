import Foundation

/// Payload for the `visualize` chat tool. The full spec rides inside the
/// tool call's input JSON — persisted as the `.toolUse` block's `JSONValue`
/// — so saved sessions re-render cards on reload with no extra storage and
/// no new ChatBlock kind (mirrors how attach_item_preview round-trips).
///
/// Parsing is deliberately lenient about value types (numbers may arrive as
/// Int, Double, or formatted strings like "2,971") because three different
/// agent backends produce the input.
struct VisualizationSpec: Hashable {

    enum Kind: String, CaseIterable {
        case table, bar, line, pie, stats

        var iconName: String {
            switch self {
            case .table: return "tablecells"
            case .bar:   return "chart.bar"
            case .line:  return "chart.line.uptrend.xyaxis"
            case .pie:   return "chart.pie"
            case .stats: return "number.square"
            }
        }

        var displayName: String {
            switch self {
            case .table: return "Table"
            case .bar:   return "Bar Chart"
            case .line:  return "Line Chart"
            case .pie:   return "Breakdown"
            case .stats: return "Metrics"
            }
        }
    }

    struct Point: Hashable {
        var label: String
        var value: Double
    }

    struct Series: Hashable {
        var name: String
        var points: [Point]
    }

    struct Stat: Hashable {
        var label: String
        var value: String
        var detail: String?
    }

    var kind: Kind
    var title: String?
    var subtitle: String?
    var columns: [String] = []
    var rows: [[String]] = []
    var series: [Series] = []
    var stats: [Stat] = []

    struct ParseError: Error {
        let message: String
    }

    // MARK: - Inline item links

    /// One parsed piece of a cell/label: plain text, or a markdown-style
    /// link (`[Title](url)`). The agent tags items inside visualizations
    /// with the same `[Title](otto://<type>/<id>)` syntax it uses in prose;
    /// the card renders those as the same clickable accent chips.
    enum InlineFragment: Hashable {
        case text(String)
        case link(title: String, url: URL)
    }

    /// Split a raw cell/label into text and link fragments. Only well-formed
    /// `[title](scheme://…)` spans become links — the title must be
    /// non-empty and bracket-free, the URL must parse with a scheme;
    /// anything else stays literal text. Hand-rolled instead of
    /// AttributedString(markdown:) so data cells containing `*`, `_`, or
    /// backticks aren't reinterpreted as formatting.
    static func fragments(_ raw: String) -> [InlineFragment] {
        guard raw.contains("](") else { return [.text(raw)] }
        var out: [InlineFragment] = []
        var plain = ""
        var i = raw.startIndex
        while i < raw.endIndex {
            if raw[i] == "[",
               let close = raw.range(of: "](", range: i..<raw.endIndex),
               let end = raw[close.upperBound...].firstIndex(of: ")") {
                let title = String(raw[raw.index(after: i)..<close.lowerBound])
                let urlString = String(raw[close.upperBound..<end])
                if !title.isEmpty,
                   !title.contains(where: { $0 == "[" || $0 == "]" || $0.isNewline }),
                   !urlString.contains(where: \.isWhitespace),
                   let url = URL(string: urlString), url.scheme != nil {
                    if !plain.isEmpty { out.append(.text(plain)); plain = "" }
                    out.append(.link(title: title, url: url))
                    i = raw.index(after: end)
                    continue
                }
            }
            plain.append(raw[i])
            i = raw.index(after: i)
        }
        if !plain.isEmpty { out.append(.text(plain)) }
        return out
    }

    /// `fragments` flattened for surfaces that can't render links (chart
    /// axis labels, legends, column headers, stat values): links collapse
    /// to their bare titles.
    static func displayText(_ raw: String) -> String {
        guard raw.contains("](") else { return raw }
        return fragments(raw).map { fragment in
            switch fragment {
            case .text(let s): return s
            case .link(let title, _): return title
            }
        }.joined()
    }

    // Caps keep a malformed payload from building an absurd view tree.
    static let maxColumns = 40
    static let maxRows = 500
    static let maxSeries = 8
    static let maxPoints = 200
    static let maxPieSlices = 24
    static let maxStats = 12

    // MARK: - Parsing

    /// Rebuild from a persisted `.toolUse` block's input.
    static func parse(json: JSONValue) -> VisualizationSpec? {
        guard let dict = json.asDictionary else { return nil }
        return try? parse(dict)
    }

    static func parse(_ input: [String: Any]) throws -> VisualizationSpec {
        guard let typeStr = (input["type"] as? String)?.lowercased(),
              let kind = Kind(rawValue: typeStr) else {
            throw ParseError(message: "'type' must be one of: \(Kind.allCases.map(\.rawValue).joined(separator: ", ")).")
        }

        var spec = VisualizationSpec(kind: kind)
        spec.title = cleanString(input["title"])
        spec.subtitle = cleanString(input["subtitle"])

        switch kind {
        case .table:
            // Headers can't carry clickable chips — collapse stray links.
            let columns = (input["columns"] as? [Any])?.compactMap(stringValue).map(displayText) ?? []
            guard !columns.isEmpty else {
                throw ParseError(message: "type='table' requires a non-empty 'columns' array of header strings.")
            }
            guard columns.count <= maxColumns else {
                throw ParseError(message: "Too many columns (\(columns.count)); maximum is \(maxColumns).")
            }
            let rawRows = (input["rows"] as? [Any]) ?? []
            var rows: [[String]] = rawRows.compactMap { raw in
                guard let cells = raw as? [Any] else { return nil }
                var row = cells.map { stringValue($0) ?? "" }
                if row.count < columns.count {
                    row.append(contentsOf: Array(repeating: "", count: columns.count - row.count))
                } else if row.count > columns.count {
                    row = Array(row.prefix(columns.count))
                }
                return row
            }
            guard !rows.isEmpty else {
                throw ParseError(message: "type='table' requires a non-empty 'rows' array (each row is an array of cell values).")
            }
            if rows.count > maxRows { rows = Array(rows.prefix(maxRows)) }
            spec.columns = columns
            spec.rows = rows

        case .bar, .line, .pie:
            var series = try parseSeries(input)
            guard !series.isEmpty else {
                throw ParseError(message: "type='\(kind.rawValue)' requires 'series' — an array of {name, points:[{label, value}]}.")
            }
            if kind == .pie {
                series = [series[0]]
                if series[0].points.count > maxPieSlices {
                    series[0].points = Array(series[0].points.prefix(maxPieSlices))
                }
                guard series[0].points.allSatisfy({ $0.value >= 0 }) else {
                    throw ParseError(message: "Pie slice values must be >= 0.")
                }
            }
            guard series.count <= maxSeries else {
                throw ParseError(message: "Too many series (\(series.count)); maximum is \(maxSeries).")
            }
            spec.series = series

        case .stats:
            let rawStats = (input["stats"] as? [Any]) ?? []
            let stats: [Stat] = rawStats.compactMap { raw in
                guard let dict = raw as? [String: Any],
                      let label = cleanString(dict["label"]).map(displayText),
                      let value = stringValue(dict["value"]).map(displayText) else { return nil }
                // `detail` stays raw: the card renders its inline item links
                // as clickable chips. Label/value can't, so collapse there.
                return Stat(label: label, value: value, detail: cleanString(dict["detail"]))
            }
            guard !stats.isEmpty else {
                throw ParseError(message: "type='stats' requires 'stats' — an array of {label, value, detail?}.")
            }
            spec.stats = Array(stats.prefix(maxStats))
        }

        return spec
    }

    private static func parseSeries(_ input: [String: Any]) throws -> [Series] {
        var rawSeries = input["series"] as? [Any] ?? []
        // Leniency: accept a bare top-level `points` array as a single series.
        if rawSeries.isEmpty, let points = input["points"] as? [Any] {
            rawSeries = [["points": points] as [String: Any]]
        }
        var out: [Series] = []
        for (idx, raw) in rawSeries.enumerated() {
            guard let dict = raw as? [String: Any] else { continue }
            let points: [Point] = ((dict["points"] as? [Any]) ?? []).compactMap { p in
                guard let pd = p as? [String: Any],
                      let label = stringValue(pd["label"]),
                      let value = doubleValue(pd["value"]),
                      value.isFinite else { return nil }
                // Chart axes/legends can't render clickable chips — show the
                // bare title if the agent tagged a point label anyway.
                return Point(label: displayText(label), value: value)
            }
            guard !points.isEmpty else {
                throw ParseError(message: "Series \(idx + 1) has no valid points — each point needs {label, value}.")
            }
            guard points.count <= maxPoints else {
                throw ParseError(message: "Series \(idx + 1) has too many points (\(points.count)); maximum is \(maxPoints).")
            }
            let name = cleanString(dict["name"]).map(displayText) ?? "Series \(idx + 1)"
            out.append(Series(name: name, points: points))
        }
        return out
    }

    // MARK: - Lenient value coercion

    private static func cleanString(_ any: Any?) -> String? {
        guard let s = stringValue(any)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else { return nil }
        return s
    }

    /// Cell/label/value as display string; numbers are formatted plainly.
    private static func stringValue(_ any: Any?) -> String? {
        switch any {
        case let s as String: return s
        case let b as Bool: return b ? "true" : "false"
        case let i as Int: return String(i)
        case let d as Double:
            return d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(d)
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    /// Numeric value; tolerates formatted strings ("2,971", "45%").
    private static func doubleValue(_ any: Any?) -> Double? {
        switch any {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String:
            let cleaned = s
                .replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: "%", with: "")
                .trimmingCharacters(in: .whitespaces)
            return Double(cleaned)
        default: return nil
        }
    }
}
