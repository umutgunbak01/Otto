import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - Full-redesign primitives (otto-redesign-full.html)
//
// The shared vocabulary of the redesign: the page backdrop (near-black with
// faint radial tints and film grain), the serif view chrome, filter pills,
// mono group labels, colored icon squares, gradient avatars, empty states,
// and the animated orb. Everything here is dumb presentation — no AppState.

// MARK: - Backdrop

/// The app-wide page background: near-black base, three faint radial tints
/// (teal top, amber bottom-right, teal bottom-left), and a static film-grain
/// tile at 5%. Painted once by MainView; panes above it use alpha-white
/// washes instead of opaque fills.
struct OttoBackdrop: View {
    var body: some View {
        ZStack {
            Theme.Colors.bgPage

            EllipticalGradient(
                colors: [Theme.Colors.cyan.opacity(0.055), .clear],
                center: UnitPoint(x: 0.5, y: -0.12),
                startRadiusFraction: 0,
                endRadiusFraction: 0.62
            )
            EllipticalGradient(
                colors: [Theme.Colors.amber.opacity(0.038), .clear],
                center: UnitPoint(x: 0.88, y: 1.12),
                startRadiusFraction: 0,
                endRadiusFraction: 0.55
            )
            EllipticalGradient(
                colors: [Theme.Colors.cyan.opacity(0.025), .clear],
                center: UnitPoint(x: -0.08, y: 1.0),
                startRadiusFraction: 0,
                endRadiusFraction: 0.5
            )

            OttoGrain()
        }
        .ignoresSafeArea()
    }
}

/// Deterministic film-grain tile (mockup body::after). Generated once and
/// tiled; alpha is baked into the texture so the overlay composites cheaply.
struct OttoGrain: View {
    var body: some View {
        #if os(macOS)
        if let image = Self.tile {
            Image(nsImage: image)
                .resizable(resizingMode: .tile)
                .opacity(0.05)
                .allowsHitTesting(false)
        }
        #else
        EmptyView()
        #endif
    }

    #if os(macOS)
    static let tile: NSImage? = {
        let size = 128
        var rng: UInt64 = 0x9E3779B97F4A7C15
        func next() -> UInt64 {
            // SplitMix64 — deterministic so the grain never shimmers between
            // launches or view reloads.
            rng &+= 0x9E3779B97F4A7C15
            var z = rng
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }

        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for i in 0..<(size * size) {
            let v = UInt8(truncatingIfNeeded: next())
            pixels[i * 4 + 0] = v
            pixels[i * 4 + 1] = v
            pixels[i * 4 + 2] = v
            pixels[i * 4 + 3] = 255
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cg = CGImage(
                  width: size, height: size,
                  bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: size * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false,
                  intent: .defaultIntent
              )
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: size, height: size))
    }()
    #endif
}

// MARK: - Overline

/// Mono uppercase letter-spaced micro-label (mockup .ovl).
struct OttoOverline: View {
    let text: String
    var color: Color = Theme.Colors.tertiaryText

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
            .tracking(Theme.Tracking.xxwide)
            .foregroundStyle(color)
    }
}

// MARK: - View chrome

/// The redesign's viewbar (mockup .viewbar): serif display title + mono
/// count chip + trailing controls. No hairline underneath — content scrolls
/// directly below.
struct OttoViewBar<Trailing: View>: View {
    let title: String
    var countText: String?
    @ViewBuilder var trailing: () -> Trailing

    init(title: String, countText: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.countText = countText
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title)
                .font(Theme.Typography.display)
                .foregroundStyle(Theme.Colors.text)
            if let countText {
                OttoCountChip(text: countText)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }
}

extension OttoViewBar where Trailing == EmptyView {
    init(title: String, countText: String? = nil) {
        self.init(title: title, countText: countText) { EmptyView() }
    }
}

/// Mono count pill (mockup .count-chip) — takes pre-formatted text so views
/// can show "42 active" or "369 · 23 unread".
struct OttoCountChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .regular, design: .monospaced))
            .tracking(0.5)
            .foregroundStyle(Theme.Colors.tertiaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(Capsule().fill(Theme.Colors.panel))
            .overlay(Capsule().strokeBorder(Theme.Colors.border, lineWidth: 1))
            .lineLimit(1)
            .fixedSize()
    }
}

// MARK: - Filter pills

/// Segmented filter pills in a capsule rail (mockup .pills / .pill).
struct OttoPillRail<T: Hashable>: View {
    let options: [(value: T, label: String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                OttoPillButton(
                    label: option.label,
                    isOn: selection == option.value,
                    action: { selection = option.value }
                )
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.014)))
        .overlay(Capsule().strokeBorder(Theme.Colors.border, lineWidth: 1))
    }
}

struct OttoPillButton: View {
    let label: String
    let isOn: Bool
    let action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isOn ? Theme.Colors.text : (hover ? Theme.Colors.text : Theme.Colors.tertiaryText))
                .padding(.horizontal, 11)
                .frame(height: 24)
                .background(
                    Capsule().fill(isOn ? Theme.Colors.panel2 : Color.clear)
                )
                .overlay(
                    Capsule().strokeBorder(isOn ? Theme.Colors.border : Color.clear, lineWidth: 1)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeInOut(duration: 0.15), value: isOn)
    }
}

// MARK: - Toolbar buttons

/// Quiet icon button (mockup .gbtn) — bare glyph, wash on hover.
struct OttoGlyphButton: View {
    let systemImage: String
    var help: String = ""
    var isActive: Bool = false
    var size: CGFloat = 28
    let action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isActive ? Theme.Colors.accentText : (hover ? Theme.Colors.text : Theme.Colors.tertiaryText))
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .fill(isActive ? Theme.Colors.selectTint : (hover ? Theme.Colors.panel2 : Color.clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// Bordered menu-ish button (mockup .mbtn) — small label + optional caret.
struct OttoBarButton: View {
    let label: String
    var systemImage: String? = nil
    var showsCaret: Bool = false
    let action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            OttoBarButtonLabel(label: label, systemImage: systemImage, showsCaret: showsCaret, hover: hover)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Label-only variant so `Menu` can reuse the same look.
struct OttoBarButtonLabel: View {
    let label: String
    var systemImage: String? = nil
    var showsCaret: Bool = false
    var hover: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(hover ? Theme.Colors.text : Theme.Colors.textDim)
            if showsCaret {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.Colors.panel))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .strokeBorder(hover ? Theme.Colors.borderStrong : Theme.Colors.border, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}

/// Primary CTA (mockup .newbtn) — teal gradient, dark ink.
struct OttoNewButton: View {
    let label: String
    var systemImage: String? = "plus"
    let action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .bold))
                }
                Text(label)
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(Theme.Colors.onAccent)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .fill(
                        LinearGradient(
                            colors: [Theme.Colors.accentGradTop, Theme.Colors.accentGradBottom],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .brightness(hover ? 0.05 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Group label

/// Mono uppercase list-group label with optional count (mockup .glabel).
struct OttoGroupLabel: View {
    let text: String
    var count: Int? = nil
    var color: Color = Theme.Colors.tertiaryText

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(text.uppercased())
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .tracking(Theme.Tracking.xxwide)
                .foregroundStyle(color)
            if let count {
                Text("· \(count)")
                    .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(color.opacity(0.7))
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 22)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Icon squares & avatars

/// Colored icon square (mockup .sq — 34pt, radius 9, tinted wash).
struct OttoSquare: View {
    let systemImage: String
    var color: Color = Theme.Colors.cyan
    var dim: Bool = false
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(dim ? Theme.Colors.tertiaryText : color)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.26)
                    .fill(dim ? Theme.Colors.panel2 : color.opacity(0.10))
            )
    }
}

/// Gradient initials avatar (mockup .fava — five stable gradient pairs
/// picked by hashing the name, so a given person keeps their color).
struct OttoAvatar: View {
    let name: String
    var size: CGFloat = 30

    private static let gradients: [(Color, Color)] = [
        (Color(red: 0.373, green: 0.890, blue: 0.769), Color(red: 0.090, green: 0.478, blue: 0.388)), // teal
        (Color(red: 0.788, green: 0.722, blue: 1.0),   Color(red: 0.357, green: 0.290, blue: 0.620)), // violet
        (Color(red: 0.957, green: 0.816, blue: 0.541), Color(red: 0.604, green: 0.451, blue: 0.149)), // amber
        (Color(red: 0.576, green: 0.765, blue: 0.961), Color(red: 0.165, green: 0.353, blue: 0.541)), // blue
        (Color(red: 0.961, green: 0.627, blue: 0.604), Color(red: 0.541, green: 0.227, blue: 0.204)), // red
    ]

    private var gradient: (Color, Color) {
        var hash: UInt64 = 1469598103934665603
        for byte in name.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        let pair = Self.gradients[Int(hash % UInt64(Self.gradients.count))]
        return pair
    }

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first.map(String.init) }
        if letters.isEmpty { return "?" }
        return letters.joined().uppercased()
    }

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.34, weight: .bold))
            .foregroundStyle(Color(red: 0.02, green: 0.08, blue: 0.06).opacity(0.9))
            .frame(width: size, height: size)
            .background(
                Circle().fill(
                    LinearGradient(
                        colors: [gradient.0, gradient.1],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            )
            .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
    }
}

/// The user's own avatar — teal gradient circle with an initial
/// (mockup .ava).
struct OttoUserAvatar: View {
    var size: CGFloat = 28

    private static var initial: String {
        #if os(macOS)
        let name = NSFullUserName()
        if let first = name.first { return String(first).uppercased() }
        #endif
        return "U"
    }

    var body: some View {
        Text(Self.initial)
            .font(.system(size: size * 0.41, weight: .bold))
            .foregroundStyle(Color(red: 0.016, green: 0.129, blue: 0.106))
            .frame(width: size, height: size)
            .background(
                Circle().fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.247, green: 0.847, blue: 0.729),
                            Color(red: 0.043, green: 0.435, blue: 0.365),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            )
            .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
    }
}

// MARK: - Empty state

/// Full-pane empty state (mockup .empty): dashed icon tile, serif headline,
/// body copy, optional suggestion chips, mono tip line.
struct OttoEmptyState<Chips: View>: View {
    let systemImage: String
    let title: String
    let message: String
    var tip: String? = nil
    @ViewBuilder var chips: () -> Chips

    init(
        systemImage: String,
        title: String,
        message: String,
        tip: String? = nil,
        @ViewBuilder chips: @escaping () -> Chips
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.tip = tip
        self.chips = chips
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(Theme.Colors.tertiaryText)
                .frame(width: 54, height: 54)
                .background(
                    RoundedRectangle(cornerRadius: 17)
                        .fill(Theme.Colors.panel)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 17)
                        .strokeBorder(
                            Color.white.opacity(0.17),
                            style: StrokeStyle(lineWidth: 1, dash: [3.5, 3.5])
                        )
                )
                .padding(.bottom, 22)

            Text(title)
                .font(Theme.Typography.displayMd)
                .foregroundStyle(Theme.Colors.text)

            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Colors.textDim)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 400)
                .padding(.top, 11)

            chips()
                .padding(.top, 24)

            if let tip {
                Text(tip.uppercased())
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .tracking(Theme.Tracking.xxwide)
                    .foregroundStyle(Theme.Colors.tertiaryText.opacity(0.75))
                    .padding(.top, 30)
            }

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Theme.Spacing.xxl)
    }
}

extension OttoEmptyState where Chips == EmptyView {
    init(systemImage: String, title: String, message: String, tip: String? = nil) {
        self.init(systemImage: systemImage, title: title, message: message, tip: tip) { EmptyView() }
    }
}

/// Suggestion chip with a leading icon (mockup .chip).
struct OttoSuggestionChip: View {
    let systemImage: String
    let label: String
    var dimSuffix: String? = nil
    let action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(hover ? Theme.Colors.accentText : Theme.Colors.tertiaryText)
                Text(label)
                    .font(.system(size: 12.5))
                    .foregroundStyle(hover ? Theme.Colors.text : Theme.Colors.textDim)
                    .lineLimit(1)
                if let dimSuffix {
                    Text(dimSuffix)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(hover ? Theme.Colors.panel2 : Theme.Colors.panel))
            .overlay(
                Capsule().strokeBorder(hover ? Theme.Colors.borderStrong : Theme.Colors.border, lineWidth: 1)
            )
            .contentShape(Capsule())
            .offset(y: hover ? -1 : 0)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeInOut(duration: 0.18), value: hover)
    }
}

// MARK: - Orb

/// The hero orb (mockup .orb): two counter-rotating dashed teal rings, a
/// center dot, a breathing glow, and faint dashed halo circles behind.
struct OttoOrb: View {
    var size: CGFloat = 72
    var showsHalo: Bool = true

    private var tealGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.710, green: 0.961, blue: 0.902), // #b5f5e6
                Color(red: 0.369, green: 0.918, blue: 0.831), // #5eead4
                Color(red: 0.169, green: 0.749, blue: 0.643), // #2bbfa4
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        ZStack {
            if showsHalo {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .strokeBorder(
                            Color.white.opacity(0.05 * (1.0 - Double(i) * 0.25)),
                            style: StrokeStyle(lineWidth: 1, dash: [2, 6])
                        )
                        .frame(
                            width: size * (2.9 + CGFloat(i) * 1.8),
                            height: size * (2.9 + CGFloat(i) * 1.8)
                        )
                }
            }

            TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate

                ZStack {
                    // Breathing glow.
                    let phase = 0.5 + 0.5 * sin((t.truncatingRemainder(dividingBy: 11)) / 11 * .pi * 2)
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Theme.Colors.cyan.opacity(0.22), .clear],
                                center: .center,
                                startRadius: 0,
                                endRadius: size * 0.85
                            )
                        )
                        .frame(width: size * 1.7, height: size * 1.7)
                        .scaleEffect(0.94 + 0.14 * phase)
                        .opacity(0.65 + 0.35 * phase)

                    // Outer dashed ring — slow clockwise.
                    let a1 = (t.truncatingRemainder(dividingBy: 26) / 26) * 360
                    Circle()
                        .stroke(
                            tealGradient,
                            style: StrokeStyle(lineWidth: size * 0.036, lineCap: .round, dash: [size * 0.033, size * 0.075])
                        )
                        .frame(width: size * 0.75, height: size * 0.75)
                        .rotationEffect(.degrees(a1))

                    // Inner dotted ring — slower, counter-clockwise.
                    let a2 = (t.truncatingRemainder(dividingBy: 42) / 42) * -360
                    Circle()
                        .stroke(
                            tealGradient,
                            style: StrokeStyle(lineWidth: size * 0.018, lineCap: .round, dash: [size * 0.007, size * 0.093])
                        )
                        .frame(width: size * 0.53, height: size * 0.53)
                        .rotationEffect(.degrees(a2))
                        .opacity(0.55)
                }
            }

            Circle()
                .fill(tealGradient)
                .frame(width: size * 0.064, height: size * 0.064)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Toggle

/// The mockup's pill toggle — teal wash when on.
struct OttoToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                configuration.isOn.toggle()
            }
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? Theme.Colors.cyan.opacity(0.22) : Theme.Colors.panel2)
                    .overlay(
                        Capsule().strokeBorder(
                            configuration.isOn ? Theme.Colors.cyan.opacity(0.35) : Theme.Colors.border,
                            lineWidth: 1
                        )
                    )
                Circle()
                    .fill(configuration.isOn ? Theme.Colors.cyan : Theme.Colors.tertiaryText)
                    .frame(width: 13, height: 13)
                    .padding(.horizontal, 3)
            }
            .frame(width: 34, height: 20)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Flow layout

/// Minimal wrapping flow for suggestion chips (mockup .chips flex-wrap).
struct OttoFlowLayout: Layout {
    var spacing: CGFloat = 8
    var alignment: HorizontalAlignment = .center

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                totalWidth = max(totalWidth, rowWidth)
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalHeight += rowHeight
        totalWidth = max(totalWidth, rowWidth)
        return CGSize(width: proposal.width ?? totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var rows: [[(subview: LayoutSubviews.Element, size: CGSize)]] = [[]]
        var rowWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                rows.append([(subview, size)])
                rowWidth = size.width
            } else {
                rows[rows.count - 1].append((subview, size))
                rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
            }
        }

        var y = bounds.minY
        for row in rows {
            let rowHeight = row.map(\.size.height).max() ?? 0
            let rowWidth = row.reduce(0) { $0 + $1.size.width } + spacing * CGFloat(max(0, row.count - 1))
            var x: CGFloat
            switch alignment {
            case .leading:  x = bounds.minX
            case .trailing: x = bounds.maxX - rowWidth
            default:        x = bounds.minX + (bounds.width - rowWidth) / 2
            }
            for item in row {
                item.subview.place(
                    at: CGPoint(x: x, y: y + (rowHeight - item.size.height) / 2),
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + spacing
            }
            y += rowHeight + spacing
        }
    }
}

// MARK: - Model chip

/// Composer's quiet backend/model indicator (mockup .modelchip) — green dot
/// + "opus-4.7 · 200K" in mono. Reads the same UserDefaults keys as
/// Settings so it re-renders the moment the backend or model changes.
struct OttoModelChip: View {
    @AppStorage(AgentService.Claude.modelIdDefaultsKey) private var storedClaudeModelId: String = AgentService.Claude.defaultModelId
    @AppStorage(AgentService.Codex.modelIdDefaultsKey) private var storedCodexModelId: String = AgentService.Codex.defaultModelId
    @AppStorage(AgentBackend.defaultsKey) private var rawBackend: String = AgentBackend.claude.rawValue

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Theme.Colors.green)
                .frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                .tracking(0.5)
                .foregroundStyle(Theme.Colors.tertiaryText)
                .lineLimit(1)
        }
    }

    private var activeBackend: AgentBackend {
        AgentBackend(rawValue: rawBackend) ?? .claude
    }

    private var label: String {
        switch activeBackend {
        case .claude:
            var id = storedClaudeModelId.isEmpty ? AgentService.Claude.defaultModelId : storedClaudeModelId
            let isLong = id.hasSuffix("[1m]")
            if isLong { id = String(id.dropLast(4)).trimmingCharacters(in: .whitespaces) }
            let stripped = id.hasPrefix("claude-") ? String(id.dropFirst("claude-".count)) : id
            let parts = stripped.split(separator: "-", maxSplits: 1).map(String.init)
            let model: String
            if parts.count == 2 {
                model = "\(parts[0].lowercased())-\(parts[1].replacingOccurrences(of: "-", with: "."))"
            } else {
                model = stripped.lowercased()
            }
            return "\(model) · \(isLong ? "1M" : "200K")"
        case .codex:
            let id = storedCodexModelId.isEmpty ? AgentService.Codex.defaultModelId : storedCodexModelId
            return "\(id.lowercased()) · 200K"
        case .hermes:
            return "hermes"
        }
    }
}

// MARK: - Mini search field

/// Compact bordered search field for view bars (mockup .ssm).
struct OttoSearchMini: View {
    let placeholder: String
    @Binding var text: String
    var width: CGFloat? = 190

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.Colors.tertiaryText)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.Colors.text)
                .focused($focused)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .frame(width: width)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.Colors.panel))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .strokeBorder(focused ? Theme.Colors.borderStrong : Theme.Colors.border, lineWidth: 1)
        )
    }
}
