import SwiftUI
import Charts

/// Inline chat card rendering a `visualize` tool call natively — table, bar,
/// line, pie, or stat tiles. Chrome mirrors `ItemPreviewCard`; unlike item
/// previews the full payload lives in the spec, so there are no AppState
/// lookups and saved sessions re-render identically.
struct VisualizationCard: View {
    let spec: VisualizationSpec
    /// Called with the `otto://<type>/<id>` URL when the user clicks an
    /// inline item chip in a table cell or stat detail. The chat view
    /// resolves it to a detail popup, same as chips in prose.
    var onOpenItem: ((URL) -> Void)? = nil

    /// Categorical series/slice palette, in Theme accent order.
    private static let palette: [Color] = [
        Theme.Colors.cyan, Theme.Colors.green, Theme.Colors.amber,
        Theme.Colors.violet, Theme.Colors.red, Theme.Colors.cyanDim,
    ]

    private static func colors(_ count: Int) -> [Color] {
        (0..<count).map { palette[$0 % palette.count] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            header
            content
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Colors.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(Theme.Colors.border, lineWidth: 1)
        )
        .padding(.horizontal, Theme.Spacing.lg)
        // Item chips inside cells route to the detail popup; ordinary web
        // links in cells keep the default open-in-browser behavior.
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme?.lowercased() == "otto" else { return .systemAction }
            onOpenItem?(url)
            return .handled
        })
    }

    // MARK: - Inline item chips

    /// Attributed rendering for a cell/detail string containing inline
    /// `[Title](otto://…)` item links — mirrors the accent-pill styling
    /// ChatMessageRenderer gives chips in prose. Returns nil for plain
    /// strings so callers keep their untouched fast path.
    private static func taggedText(_ raw: String, font: Font, baseColor: Color) -> AttributedString? {
        let fragments = VisualizationSpec.fragments(raw)
        guard fragments.contains(where: {
            if case .link = $0 { return true } else { return false }
        }) else { return nil }

        var out = AttributedString()
        for fragment in fragments {
            switch fragment {
            case .text(let s):
                var run = AttributedString(s)
                run.font = font
                run.foregroundColor = baseColor
                out += run
            case .link(let title, let url):
                let isItem = url.scheme?.lowercased() == "otto"
                // NBSP padding keeps the chip highlight hugging the title
                // without breaking across it (same trick as prose chips).
                var run = AttributedString(isItem ? "\u{00A0}\(title)\u{00A0}" : title)
                run.link = url
                run.font = isItem ? font.weight(.medium) : font
                run.foregroundColor = Theme.Colors.accent
                if isItem {
                    run.backgroundColor = Theme.Colors.accent.opacity(0.14)
                } else {
                    run.underlineStyle = .single
                }
                out += run
            }
        }
        return out
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Theme.Spacing.sm) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(Theme.Colors.cyan.opacity(0.12))
                Image(systemName: spec.kind.iconName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Colors.cyan)
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(spec.title ?? spec.kind.displayName)
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.Colors.text)
                    .lineLimit(1)
                if let subtitle = spec.subtitle {
                    Text(subtitle)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch spec.kind {
        case .stats: statsGrid
        case .table: table
        case .bar:   barChart
        case .line:  lineChart
        case .pie:   pieChart
        }
    }

    // MARK: Stats

    private var statsGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150), spacing: Theme.Spacing.sm)],
            alignment: .leading,
            spacing: Theme.Spacing.sm
        ) {
            ForEach(spec.stats.indices, id: \.self) { i in
                let stat = spec.stats[i]
                VStack(alignment: .leading, spacing: 3) {
                    Text(stat.label.uppercased())
                        .font(Theme.Typography.label)
                        .tracking(Theme.Tracking.xwide)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .lineLimit(1)
                    Text(verbatim: stat.value)
                        .font(.system(size: 21, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.Colors.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if let detail = stat.detail {
                        if let tagged = Self.taggedText(detail, font: Theme.Typography.caption, baseColor: Theme.Colors.textDim) {
                            Text(tagged)
                                .lineLimit(2)
                        } else {
                            Text(detail)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.textDim)
                                .lineLimit(2)
                        }
                    }
                }
                .padding(Theme.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Colors.bg1)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
            }
        }
    }

    // MARK: Table

    private static let maxVisibleTableRows = 12

    private var columnWidths: [CGFloat] {
        spec.columns.indices.map { col in
            var longest = spec.columns[col].count
            for row in spec.rows.prefix(40) where col < row.count {
                // Size by what the cell displays — link markup collapses
                // to its title, so `[Name](otto://…)` doesn't blow up the
                // column to the raw URL's length.
                longest = max(longest, min(VisualizationSpec.displayText(row[col]).count, 40))
            }
            return min(max(CGFloat(longest) * 7.2 + 20, 70), 280)
        }
    }

    private var table: some View {
        let widths = columnWidths
        let total = widths.reduce(0, +)
        return VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            ScrollView(.horizontal, showsIndicators: true) {
                VStack(spacing: 0) {
                    tableHeaderRow(widths)
                    if spec.rows.count > Self.maxVisibleTableRows {
                        ScrollView(.vertical, showsIndicators: true) {
                            LazyVStack(spacing: 0) {
                                ForEach(spec.rows.indices, id: \.self) { r in
                                    tableRow(r, widths)
                                }
                            }
                        }
                        .frame(height: CGFloat(Self.maxVisibleTableRows) * 30)
                    } else {
                        ForEach(spec.rows.indices, id: \.self) { r in
                            tableRow(r, widths)
                        }
                    }
                }
                .frame(width: total, alignment: .leading)
            }

            Text(verbatim: "\(spec.rows.count) row\(spec.rows.count == 1 ? "" : "s")")
                .font(Theme.Typography.monoCaption)
                .foregroundStyle(Theme.Colors.tertiaryText)
        }
    }

    private func tableHeaderRow(_ widths: [CGFloat]) -> some View {
        HStack(spacing: 0) {
            ForEach(spec.columns.indices, id: \.self) { c in
                Text(spec.columns[c].uppercased())
                    .font(Theme.Typography.label)
                    .tracking(Theme.Tracking.xwide)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .frame(width: widths[c], height: 26, alignment: .leading)
                    .cellTrailingDivider()
            }
        }
        .background(Theme.Colors.bg1)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Colors.border).frame(height: 1)
        }
    }

    private func tableRow(_ r: Int, _ widths: [CGFloat]) -> some View {
        HStack(spacing: 0) {
            ForEach(spec.columns.indices, id: \.self) { c in
                let value = c < spec.rows[r].count ? spec.rows[r][c] : ""
                cellText(value)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .frame(width: widths[c], height: 30, alignment: .leading)
                    .cellTrailingDivider()
            }
        }
        .background(r % 2 == 1 ? Theme.Colors.bg1.opacity(0.35) : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Colors.borderSubtle).frame(height: 1)
        }
    }

    @ViewBuilder
    private func cellText(_ value: String) -> some View {
        if let tagged = Self.taggedText(value, font: .system(size: 12), baseColor: Theme.Colors.textDim) {
            Text(tagged)
        } else {
            Text(value.isEmpty ? "—" : value)
                .font(.system(size: 12))
                .foregroundStyle(value.isEmpty ? Theme.Colors.tertiaryText.opacity(0.5) : Theme.Colors.textDim)
        }
    }

    // MARK: Charts

    /// Ordered unique category labels across all series — used as an explicit
    /// x-domain so Charts plots in data order instead of sorting labels.
    private var orderedLabels: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for series in spec.series {
            for p in series.points where !seen.contains(p.label) {
                seen.insert(p.label)
                out.append(p.label)
            }
        }
        return out
    }

    private var barChart: some View {
        let multi = spec.series.count > 1
        return Chart {
            ForEach(spec.series.indices, id: \.self) { s in
                let series = spec.series[s]
                ForEach(series.points.indices, id: \.self) { p in
                    BarMark(
                        x: .value("Category", series.points[p].label),
                        y: .value("Value", series.points[p].value)
                    )
                    .foregroundStyle(by: .value("Series", series.name))
                    .position(by: .value("Series", series.name))
                    .cornerRadius(2)
                }
            }
        }
        .chartXScale(domain: orderedLabels)
        .chartForegroundStyleScale(range: Self.colors(spec.series.count))
        .chartLegend(multi ? .visible : .hidden)
        .frame(height: 240)
    }

    private var lineChart: some View {
        let multi = spec.series.count > 1
        return Chart {
            ForEach(spec.series.indices, id: \.self) { s in
                let series = spec.series[s]
                ForEach(series.points.indices, id: \.self) { p in
                    LineMark(
                        x: .value("Label", series.points[p].label),
                        y: .value("Value", series.points[p].value)
                    )
                    .foregroundStyle(by: .value("Series", series.name))
                    .symbol(by: .value("Series", series.name))
                    .interpolationMethod(.monotone)
                }
            }
        }
        .chartXScale(domain: orderedLabels)
        .chartForegroundStyleScale(range: Self.colors(spec.series.count))
        .chartLegend(multi ? .visible : .hidden)
        .frame(height: 240)
    }

    private var pieChart: some View {
        let points = spec.series.first?.points ?? []
        return Chart {
            ForEach(points.indices, id: \.self) { p in
                SectorMark(
                    angle: .value("Value", points[p].value),
                    innerRadius: .ratio(0.6),
                    angularInset: 1.5
                )
                .foregroundStyle(by: .value("Label", points[p].label))
                .cornerRadius(2)
            }
        }
        .chartForegroundStyleScale(range: Self.colors(points.count))
        .chartLegend(position: .trailing, alignment: .center)
        .frame(height: 220)
    }
}
