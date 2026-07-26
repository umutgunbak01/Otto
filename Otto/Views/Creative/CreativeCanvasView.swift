import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The infinite canvas: a dotted world you pan (scroll / drag empty space)
/// and zoom (pinch / ⌘-scroll / toolbar), holding node cards connected by
/// typed bezier wires. World-space content lives inside one coordinate space
/// (`worldSpace`) scaled+offset as a whole; pin anchors are measured in that
/// space so edges stay glued to their dots at any zoom.
struct CreativeCanvasView: View {
    static let worldSpace = "creativeWorld"

    private var controller: CreativeCanvasController { .shared }

    @State private var eventMonitor: Any?
    @State private var hostWindow: NSWindow?
    @State private var canvasFrameInWindow: CGRect = .zero
    @State private var isDropTargeted = false

    /// Empty-canvas drags either sweep a marquee (default) or pan (⌥ held).
    private enum CanvasDragMode {
        case marquee
        case pan
    }
    @State private var dragMode: CanvasDragMode?
    @State private var panAtDragStart: CGSize?
    @State private var marqueeStart: CGPoint?
    @State private var marqueeCurrent: CGPoint?
    @State private var marqueeBaseline: Set<String> = []

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Dotted backdrop — marquee-select / ⌥-pan / click-to-deselect.
            CreativeGridBackground(pan: controller.pan, zoom: controller.zoom)
                .contentShape(Rectangle())
                .gesture(canvasDragGesture)
                .contextMenu {
                    Button {
                        controller.showLibrary = true
                    } label: {
                        Label("Add node…", systemImage: "plus")
                    }
                    Button {
                        controller.autoArrange()
                    } label: {
                        Label("Auto-arrange", systemImage: "rectangle.3.group")
                    }
                    Button {
                        controller.fitToContent()
                    } label: {
                        Label("Fit to content", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    Button {
                        controller.setZoom(1)
                    } label: {
                        Label("Zoom to 100%", systemImage: "1.magnifyingglass")
                    }
                }

            // Pin the world's LAYOUT size to the canvas: edge views carry
            // real frames spanning their endpoints (offset moves them but
            // doesn't remove them from layout), so a graph spread over
            // thousands of points would otherwise inflate this view's
            // reported size past the window — SwiftUI centers oversized
            // children, overflowing the canvas over the sidebar and top bar.
            // Children still render beyond these bounds; the outer .clipped()
            // trims them at the canvas edge.
            world
                .frame(
                    width: max(controller.canvasSize.width, 1),
                    height: max(controller.canvasSize.height, 1),
                    alignment: .topLeading
                )
                .scaleEffect(controller.zoom, anchor: .topLeading)
                .offset(controller.pan)

            if let rect = marqueeRect, rect.width > 3 || rect.height > 3 {
                Rectangle()
                    .fill(Theme.Colors.accent.opacity(0.07))
                    .overlay(
                        Rectangle()
                            .strokeBorder(Theme.Colors.accent.opacity(0.55), lineWidth: 1)
                    )
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .allowsHitTesting(false)
            }

            if isDropTargeted {
                dropHint
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.bgPage)
        .clipped()
        .background(CreativeWindowReader { window in hostWindow = window })
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { frame in
            canvasFrameInWindow = frame
            controller.canvasSize = frame.size
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers, location in
            handleDrop(providers, at: location)
        }
        .onAppear {
            // Hover-out isn't guaranteed when hovered views are removed, so
            // re-arm scroll handling whenever the canvas (re)appears.
            controller.scrollPassthroughDepth = 0
            installEventMonitor()
        }
        .onDisappear {
            removeEventMonitor()
            controller.flush()
        }
    }

    // MARK: - World

    private var world: some View {
        ZStack(alignment: .topLeading) {
            // Wires under cards.
            ForEach(controller.workflow.edges) { edge in
                CreativeEdgeView(edge: edge)
            }

            ForEach(controller.workflow.nodes) { node in
                CreativeNodeView(node: node)
                    .offset(effectiveOffset(for: node))
            }

            if let drag = controller.connectDrag,
               let from = controller.portAnchors[drag.origin] {
                CreativeTempEdgeView(from: from, to: drag.point, color: drag.originKind.pinColor)
            }
        }
        .coordinateSpace(.named(Self.worldSpace))
    }

    private func effectiveOffset(for node: CreativeNode) -> CGSize {
        let drag = controller.nodeDragOffsets[node.id] ?? .zero
        return CGSize(width: node.position.x + drag.width, height: node.position.y + drag.height)
    }

    // MARK: - Canvas drag (marquee select by default, ⌥ pans, click clears)

    private var marqueeRect: CGRect? {
        guard dragMode == .marquee, let start = marqueeStart, let current = marqueeCurrent
        else { return nil }
        return CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
    }

    private var canvasDragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragMode == nil {
                    if NSEvent.modifierFlags.contains(.option) {
                        dragMode = .pan
                        panAtDragStart = controller.pan
                    } else {
                        dragMode = .marquee
                        marqueeStart = value.startLocation
                        marqueeBaseline = NSEvent.modifierFlags.contains(.shift)
                            ? controller.selectedNodeIds
                            : []
                    }
                }
                switch dragMode {
                case .pan:
                    guard let start = panAtDragStart else { return }
                    controller.pan = CGSize(
                        width: start.width + value.translation.width,
                        height: start.height + value.translation.height
                    )
                case .marquee:
                    marqueeCurrent = value.location
                    if let rect = marqueeRect, rect.width > 3 || rect.height > 3 {
                        controller.marqueeSelect(
                            worldRect: worldRect(fromCanvas: rect),
                            baseline: marqueeBaseline
                        )
                    }
                case nil:
                    break
                }
            }
            .onEnded { value in
                let mode = dragMode
                dragMode = nil
                panAtDragStart = nil
                marqueeStart = nil
                marqueeCurrent = nil

                let moved = hypot(value.translation.width, value.translation.height)
                if moved < 3 {
                    // A plain click — deselect and dismiss the library.
                    controller.clearSelection()
                    controller.showLibrary = false
                } else if mode == .pan {
                    controller.viewportChanged()
                }
            }
    }

    private func worldRect(fromCanvas rect: CGRect) -> CGRect {
        let origin = controller.worldPoint(fromCanvas: rect.origin)
        return CGRect(
            origin: origin,
            size: CGSize(width: rect.width / controller.zoom, height: rect.height / controller.zoom)
        )
    }

    // MARK: - Drop

    private func handleDrop(_ providers: [NSItemProvider], at location: CGPoint) -> Bool {
        let worldPoint = controller.worldPoint(fromCanvas: location)
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { urls.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            Task { @MainActor in
                await controller.addMediaNodes(fileURLs: urls, at: worldPoint)
            }
        }
        return true
    }

    private var dropHint: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.xl)
            .strokeBorder(Theme.Colors.accent.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [8, 5]))
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.xl)
                    .fill(Theme.Colors.accent.opacity(0.05))
            )
            .overlay(
                VStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 22, weight: .light))
                    Text("Drop media to add it to the canvas")
                        .font(Theme.Typography.callout)
                }
                .foregroundStyle(Theme.Colors.accentText)
            )
            .padding(Theme.Spacing.xl)
            .allowsHitTesting(false)
    }

    // MARK: - Scroll / magnify / key events
    //
    // SwiftUI has no scroll-wheel gesture, so a local NSEvent monitor handles
    // trackpad panning, pinch zoom and canvas keyboard shortcuts — active
    // only while this view is on screen, scoped to our window + bounds
    // (mirrors the Cmd-Z monitor precedent in MainView).

    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify, .keyDown]) { event in
            handle(event)
        }
    }

    private func removeEventMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    /// Event location in canvas-local (top-left origin) coordinates, or nil
    /// when the event belongs to another window / lands outside the canvas.
    private func canvasLocation(of event: NSEvent) -> CGPoint? {
        guard let window = event.window, window === hostWindow,
              let contentView = window.contentView else { return nil }
        let inWindow = event.locationInWindow
        // AppKit windows are bottom-left origin; SwiftUI .global is top-left.
        let flipped = CGPoint(x: inWindow.x, y: contentView.frame.height - inWindow.y)
        guard canvasFrameInWindow.contains(flipped) else { return nil }
        return CGPoint(x: flipped.x - canvasFrameInWindow.minX, y: flipped.y - canvasFrameInWindow.minY)
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .scrollWheel:
            guard let location = canvasLocation(of: event) else { return event }
            let precise = event.hasPreciseScrollingDeltas
            let dx = precise ? event.scrollingDeltaX : event.scrollingDeltaX * 10
            let dy = precise ? event.scrollingDeltaY : event.scrollingDeltaY * 10
            if event.modifierFlags.contains(.command) {
                // ⌘-scroll zooms around the cursor.
                let factor = pow(1.0035, dy)
                controller.setZoom(controller.zoom * factor, around: location)
                return nil
            }
            // Hovering a scrollable editor? Let it consume the scroll.
            if controller.scrollPassthroughDepth > 0 { return event }
            controller.pan = CGSize(
                width: controller.pan.width + dx,
                height: controller.pan.height + dy
            )
            controller.viewportChanged()
            return nil

        case .magnify:
            guard let location = canvasLocation(of: event) else { return event }
            controller.setZoom(controller.zoom * (1 + event.magnification), around: location)
            return nil

        case .keyDown:
            guard let window = event.window, window === hostWindow else { return event }
            // Never steal keys from text editing.
            if let responder = window.firstResponder,
               responder is NSTextView || responder is NSText {
                return event
            }
            switch event.keyCode {
            case 51, 117:   // delete / forward delete
                if !controller.selectedNodeIds.isEmpty || !controller.selectedEdgeIds.isEmpty {
                    controller.deleteSelection()
                    return nil
                }
                return event
            case 53:        // escape
                if controller.connectDrag != nil {
                    controller.connectDrag = nil
                    return nil
                }
                if controller.showLibrary {
                    controller.showLibrary = false
                    return nil
                }
                return event
            case 36:        // return — ⌘↩ runs the selection (or everything)
                if event.modifierFlags.contains(.command) {
                    if !controller.selectedNodeIds.isEmpty {
                        controller.runSelection()
                    } else {
                        controller.runAll()
                    }
                    return nil
                }
                return event
            default:
                if event.modifierFlags.contains(.command) {
                    switch event.charactersIgnoringModifiers {
                    case "=", "+":
                        controller.zoomStep(1)
                        return nil
                    case "-":
                        controller.zoomStep(-1)
                        return nil
                    case "0":
                        controller.setZoom(1)
                        return nil
                    case "a":
                        controller.selectAllNodes()
                        return nil
                    default:
                        break
                    }
                }
                return event
            }

        default:
            return event
        }
    }
}

// MARK: - Grid backdrop

/// The dot grid, drawn in screen space from the current pan/zoom so it stays
/// crisp and cheap at any scale.
struct CreativeGridBackground: View {
    let pan: CGSize
    let zoom: CGFloat

    /// One dot on a transparent 26pt tile; `ImagePaint` tiles it on the GPU.
    /// The old `Canvas` implementation stroked ~10k ellipses on the CPU every
    /// pan/zoom frame — the single biggest source of canvas lag.
    private static let tileEdge: CGFloat = 26
    private static let dotTile: Image = {
        let edge = CreativeGridBackground.tileEdge
        let nsImage = NSImage(size: NSSize(width: edge, height: edge), flipped: true) { _ in
            NSColor.white.withAlphaComponent(0.055).setFill()
            NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 2, height: 2)).fill()
            return true
        }
        return Image(nsImage: nsImage)
    }()

    /// Dot spacing at the current zoom, doubled while too dense to read.
    private var spacing: CGFloat {
        var s = Self.tileEdge * zoom
        while s < 14 { s *= 2 }
        return s
    }

    var body: some View {
        GeometryReader { geo in
            let s = spacing
            let offsetX = pan.width.truncatingRemainder(dividingBy: s)
            let offsetY = pan.height.truncatingRemainder(dividingBy: s)

            Rectangle()
                .fill(ImagePaint(image: Self.dotTile, scale: s / Self.tileEdge))
                .frame(
                    width: geo.size.width + s * 2,
                    height: geo.size.height + s * 2
                )
                .offset(x: offsetX - s, y: offsetY - s)
        }
        .clipped()
        .background(Theme.Colors.bgPage)
    }
}

// MARK: - Edges

/// Cubic wire between two world points, expressed in a local frame so hit
/// testing works wherever the nodes sit (including negative world coords).
struct CreativeEdgePathShape: Shape {
    var from: CGPoint
    var to: CGPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: from)
        let dx = max(48, abs(to.x - from.x) * 0.45)
        path.addCurve(
            to: to,
            control1: CGPoint(x: from.x + dx, y: from.y),
            control2: CGPoint(x: to.x - dx, y: to.y)
        )
        return path
    }
}

struct CreativeEdgeView: View {
    let edge: CreativeEdge

    private var controller: CreativeCanvasController { .shared }

    var body: some View {
        let fromRef = CreativePortRef(nodeId: edge.fromNode, portKey: edge.fromPort, side: .output)
        let toRef = CreativePortRef(nodeId: edge.toNode, portKey: edge.toParam, side: .input)

        if let from = controller.portAnchors[fromRef],
           let to = controller.portAnchors[toRef] {
            let pad: CGFloat = 90
            let origin = CGPoint(x: min(from.x, to.x) - pad, y: min(from.y, to.y) - pad)
            let size = CGSize(
                width: abs(to.x - from.x) + pad * 2,
                height: abs(to.y - from.y) + pad * 2
            )
            let localFrom = CGPoint(x: from.x - origin.x, y: from.y - origin.y)
            let localTo = CGPoint(x: to.x - origin.x, y: to.y - origin.y)

            let isSelected = controller.selectedEdgeIds.contains(edge.id)
            let color = isSelected
                ? Theme.Colors.accentText
                : controller.portKind(for: fromRef).pinColor.opacity(0.8)

            let shape = CreativeEdgePathShape(from: localFrom, to: localTo)
            shape
                .stroke(color, style: StrokeStyle(lineWidth: isSelected ? 2.6 : 2, lineCap: .round))
                .frame(width: size.width, height: size.height)
                .contentShape(shape.stroke(style: StrokeStyle(lineWidth: 12)))
                .onTapGesture {
                    controller.select(edge: edge.id)
                }
                .contextMenu {
                    Button(role: .destructive) {
                        controller.disconnect(edgeId: edge.id)
                    } label: {
                        Label("Delete connection", systemImage: "scissors")
                    }
                }
                .offset(x: origin.x, y: origin.y)
        }
    }
}

/// The wire being dragged from a pin, before it lands.
struct CreativeTempEdgeView: View {
    let from: CGPoint
    let to: CGPoint
    let color: Color

    var body: some View {
        let pad: CGFloat = 90
        let origin = CGPoint(x: min(from.x, to.x) - pad, y: min(from.y, to.y) - pad)
        let size = CGSize(width: abs(to.x - from.x) + pad * 2, height: abs(to.y - from.y) + pad * 2)
        let localFrom = CGPoint(x: from.x - origin.x, y: from.y - origin.y)
        let localTo = CGPoint(x: to.x - origin.x, y: to.y - origin.y)

        CreativeEdgePathShape(from: localFrom, to: localTo)
            .stroke(color.opacity(0.9), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 4]))
            .frame(width: size.width, height: size.height)
            .offset(x: origin.x, y: origin.y)
            .allowsHitTesting(false)
    }
}

// MARK: - Window reader

/// Reports the hosting NSWindow so the event monitor can scope itself to it
/// (sheet windows and other app windows must keep their own scroll behavior).
private struct CreativeWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onWindow(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(nsView.window) }
    }
}
