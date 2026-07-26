import Foundation
import SwiftUI
import Observation

/// State + execution engine for the Creative canvas. A singleton (rather than
/// per-view @State) so in-flight generations keep running while the user
/// browses other tabs.
///
/// Everything UI-facing is @MainActor; network work hops to the
/// `FalWorkflowAPI` / `CreativeStore` actors.
@MainActor
@Observable
final class CreativeCanvasController {
    static let shared = CreativeCanvasController()

    // MARK: - Documents

    var workflows: [CreativeWorkflow] = []
    var workflow = CreativeWorkflow()
    var bootstrapped = false

    // MARK: - Schemas

    /// Parsed specs per endpoint id. Nil entry = not loaded yet; node views
    /// render a loading shimmer until it lands.
    var specs: [String: CreativeNodeSpec] = [:]
    /// Endpoints whose schema fetch failed (retryable from the node card).
    var specErrors: [String: String] = [:]

    // MARK: - Viewport (screen-space pan, world-space content)

    var pan: CGSize = .zero
    var zoom: CGFloat = 1.0
    var canvasSize: CGSize = .zero

    static let minZoom: CGFloat = 0.2
    static let maxZoom: CGFloat = 2.5

    // MARK: - Selection & interaction

    var selectedNodeIds: Set<String> = []
    var selectedEdgeIds: Set<UUID> = []
    /// Live drag translation per node (world units) — committed to the model
    /// on drag end so autosave isn't hammered at 60fps.
    var nodeDragOffsets: [String: CGSize] = [:]
    /// Pin-dot centers in world coordinates, reported by the pin views.
    var portAnchors: [CreativePortRef: CGPoint] = [:]
    /// Measured node card sizes (world units) for fit-to-view.
    var nodeSizes: [String: CGSize] = [:]

    struct ConnectDrag {
        var origin: CreativePortRef
        var originKind: CreativePortKind
        var point: CGPoint              // world coords
        var candidate: CreativePortRef?
        /// Pins that make sense as a destination (type + direction + cycle
        /// checked once at drag start) — these highlight while everything
        /// else dims, and only they can be dropped on.
        var eligible: Set<CreativePortRef> = []
    }
    var connectDrag: ConnectDrag?

    /// When >0, scroll events pass through to hovered scrollable content
    /// (prompt editors, result text) instead of panning the canvas.
    var scrollPassthroughDepth = 0

    var showLibrary = false

    // MARK: - Run state

    var runStates: [String: CreativeRunState] = [:]
    private var activeTickets: [String: FalWorkflowAPI.SubmitTicket] = [:]
    private var graphTasks: [UUID: Task<Void, Never>] = [:]

    var isRunningGraph: Bool { !graphTasks.isEmpty }

    var anyNodeActive: Bool {
        isRunningGraph || runStates.values.contains { $0.isActive }
    }

    // MARK: - Feedback

    var toast: String?
    private var toastTask: Task<Void, Never>?

    private var saveTask: Task<Void, Never>?

    private init() {}

    // MARK: - Bootstrap

    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        await CreativeStore.shared.ensureDirectories()
        let loaded = await CreativeStore.shared.loadWorkflows()
        workflows = loaded
        if let first = loaded.first {
            workflow = first
        } else {
            workflow = CreativeWorkflow(name: "Untitled")
            workflows = [workflow]
            await CreativeStore.shared.save(workflow)
        }
        restoreViewport()
        await preloadSpecs(for: workflow)
    }

    private func preloadSpecs(for workflow: CreativeWorkflow) async {
        let endpointIds = Set(workflow.nodes.compactMap(\.endpointId))
        for endpointId in endpointIds {
            ensureSpec(endpointId)
        }
    }

    /// Loads (or reloads) an endpoint's spec in the background.
    func ensureSpec(_ endpointId: String, force: Bool = false) {
        if !force, specs[endpointId] != nil { return }
        Task {
            do {
                let spec = try await FalWorkflowAPI.shared.nodeSpec(for: endpointId, forceRefresh: force)
                specs[endpointId] = spec
                specErrors[endpointId] = nil
            } catch {
                specErrors[endpointId] = error.localizedDescription
            }
        }
    }

    func spec(for node: CreativeNode) -> CreativeNodeSpec? {
        guard let endpointId = node.endpointId else { return nil }
        return specs[endpointId]
    }

    // MARK: - Workflow management

    func newWorkflow() {
        flushViewportIntoWorkflow()
        scheduleSave(immediate: true)
        let fresh = CreativeWorkflow(name: untitledName())
        workflow = fresh
        workflows.insert(fresh, at: 0)
        selectedNodeIds = []
        selectedEdgeIds = []
        pan = .zero
        zoom = 1
        scheduleSave(immediate: true)
    }

    private func untitledName() -> String {
        let existing = Set(workflows.map(\.name))
        if !existing.contains("Untitled") { return "Untitled" }
        var i = 2
        while existing.contains("Untitled \(i)") { i += 1 }
        return "Untitled \(i)"
    }

    func switchTo(workflowId: UUID) {
        guard workflowId != workflow.id else { return }
        guard !anyNodeActive else {
            showToast("Wait for the current run to finish (or press Stop) before switching.")
            return
        }
        flushViewportIntoWorkflow()
        scheduleSave(immediate: true)
        syncWorkflowIntoList()
        guard let next = workflows.first(where: { $0.id == workflowId }) else { return }
        workflow = next
        selectedNodeIds = []
        selectedEdgeIds = []
        runStates = [:]
        portAnchors = [:]
        nodeSizes = [:]
        restoreViewport()
        Task { await preloadSpecs(for: next) }
    }

    func renameWorkflow(to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        workflow.name = trimmed
        touchAndSave()
    }

    func duplicateWorkflow() {
        flushViewportIntoWorkflow()
        var copy = workflow
        copy.id = UUID()
        copy.name = workflow.name + " copy"
        copy.createdAt = Date()
        copy.updatedAt = Date()
        workflows.insert(copy, at: 0)
        Task { await CreativeStore.shared.save(copy) }
        showToast("Duplicated “\(workflow.name)”")
    }

    func deleteCurrentWorkflow() {
        guard !anyNodeActive else {
            showToast("Stop the current run before deleting.")
            return
        }
        let doomed = workflow.id
        workflows.removeAll { $0.id == doomed }
        Task { await CreativeStore.shared.deleteWorkflow(id: doomed) }
        if let next = workflows.first {
            workflow = next
            restoreViewport()
        } else {
            workflow = CreativeWorkflow(name: "Untitled")
            workflows = [workflow]
            pan = .zero
            zoom = 1
            scheduleSave(immediate: true)
        }
        selectedNodeIds = []
        selectedEdgeIds = []
        runStates = [:]
    }

    // MARK: - Saving

    private func syncWorkflowIntoList() {
        if let idx = workflows.firstIndex(where: { $0.id == workflow.id }) {
            workflows[idx] = workflow
        }
    }

    func touchAndSave() {
        workflow.updatedAt = Date()
        scheduleSave()
    }

    /// Debounced autosave — canvas edits arrive in bursts. The snapshot (and
    /// the `workflows`-array sync, which invalidates the toolbar menu) happen
    /// when the debounce FIRES, not per mutation — keystrokes in a prompt
    /// editor shouldn't copy the document or touch the list every frame.
    func scheduleSave(immediate: Bool = false) {
        saveTask?.cancel()
        if immediate {
            syncWorkflowIntoList()
            let snapshot = workflow
            Task { await CreativeStore.shared.save(snapshot) }
            return
        }
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let self else { return }
            self.syncWorkflowIntoList()
            let snapshot = self.workflow
            await CreativeStore.shared.save(snapshot)
        }
    }

    /// Called when the tab disappears — capture viewport + force a write.
    func flush() {
        flushViewportIntoWorkflow()
        scheduleSave(immediate: true)
    }

    private func flushViewportIntoWorkflow() {
        workflow.canvasOffset = CGPoint(x: pan.width, y: pan.height)
        workflow.canvasZoom = zoom
    }

    private func restoreViewport() {
        pan = CGSize(width: workflow.canvasOffset.x, height: workflow.canvasOffset.y)
        zoom = workflow.canvasZoom.isFinite && workflow.canvasZoom > 0
            ? min(max(workflow.canvasZoom, Self.minZoom), Self.maxZoom)
            : 1
    }

    // MARK: - Coordinate transforms

    func worldPoint(fromCanvas point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - pan.width) / zoom, y: (point.y - pan.height) / zoom)
    }

    func canvasPoint(fromWorld point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * zoom + pan.width, y: point.y * zoom + pan.height)
    }

    /// World point at the visible canvas center — default node placement.
    var visibleWorldCenter: CGPoint {
        worldPoint(fromCanvas: CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2))
    }

    func setZoom(_ newZoom: CGFloat, around canvasAnchor: CGPoint? = nil) {
        let clamped = min(max(newZoom, Self.minZoom), Self.maxZoom)
        let anchor = canvasAnchor ?? CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let world = worldPoint(fromCanvas: anchor)
        zoom = clamped
        pan = CGSize(
            width: anchor.x - world.x * clamped,
            height: anchor.y - world.y * clamped
        )
        touchAndSaveViewportOnly()
    }

    func zoomStep(_ direction: Int) {
        setZoom(zoom * (direction > 0 ? 1.25 : 0.8))
    }

    func fitToContent() {
        guard !workflow.nodes.isEmpty, canvasSize.width > 0 else { return }
        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for node in workflow.nodes {
            let size = nodeSizes[node.id] ?? CGSize(width: 480, height: 320)
            minX = min(minX, node.position.x - 120)   // pin chips flank the card
            minY = min(minY, node.position.y)
            maxX = max(maxX, node.position.x + size.width + 120)
            maxY = max(maxY, node.position.y + size.height)
        }
        let bounds = CGRect(x: minX, y: minY, width: max(maxX - minX, 1), height: max(maxY - minY, 1))
        let fitZoom = min(
            min(canvasSize.width / bounds.width, canvasSize.height / bounds.height) * 0.9,
            1.25
        )
        let clamped = min(max(fitZoom, Self.minZoom), Self.maxZoom)
        withAnimation(.easeInOut(duration: 0.25)) {
            zoom = clamped
            pan = CGSize(
                width: canvasSize.width / 2 - bounds.midX * clamped,
                height: canvasSize.height / 2 - bounds.midY * clamped
            )
        }
        touchAndSaveViewportOnly()
    }

    private func touchAndSaveViewportOnly() {
        flushViewportIntoWorkflow()
        scheduleSave()
    }

    /// Debounced viewport persistence for continuous pan/zoom input.
    func viewportChanged() {
        touchAndSaveViewportOnly()
    }

    // MARK: - Node operations

    @discardableResult
    func addModelNode(_ summary: CreativeModelSummary, at worldPosition: CGPoint? = nil) -> CreativeNode {
        let position = worldPosition ?? placementPoint()
        let node = CreativeNode(
            kind: .model,
            endpointId: summary.id,
            // Disambiguated so sibling endpoints ("Nano Banana 2" vs its
            // /edit variant) don't look identical on the canvas.
            title: summary.disambiguatedTitle,
            subtitle: summary.id,
            thumbnailUrl: summary.thumbnailUrl,
            category: summary.category,
            position: position
        )
        workflow.nodes.append(node)
        ensureSpec(summary.id)
        selectedNodeIds = [node.id]
        touchAndSave()
        return node
    }

    /// Imports dropped/picked files as media nodes. Returns created nodes.
    @discardableResult
    func addMediaNodes(fileURLs: [URL], at worldPosition: CGPoint? = nil) async -> [CreativeNode] {
        var created: [CreativeNode] = []
        var cursor = worldPosition ?? placementPoint()
        for url in fileURLs {
            do {
                let asset = try await CreativeStore.shared.importAsset(from: url)
                let node = CreativeNode(
                    kind: .media,
                    title: asset.fileName,
                    position: cursor,
                    media: asset
                )
                workflow.nodes.append(node)
                created.append(node)
                cursor = CGPoint(x: cursor.x + 40, y: cursor.y + 40)
            } catch {
                showToast("Couldn't import \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !created.isEmpty {
            selectedNodeIds = Set(created.map(\.id))
            touchAndSave()
        }
        return created
    }

    /// Dropping a file straight onto a param well: import it, spawn a media
    /// node just left of the target, and wire it up — assets stay visible,
    /// uploads stay cached in one place.
    func attachMedia(fileURL: URL, toNode nodeId: String, param: String) async {
        guard let target = workflow.node(nodeId) else { return }
        let spawnAt = CGPoint(x: target.position.x - 300, y: target.position.y)
        let created = await addMediaNodes(fileURLs: [fileURL], at: spawnAt)
        guard let mediaNode = created.first else { return }
        connect(
            from: CreativePortRef(nodeId: mediaNode.id, portKey: "url", side: .output),
            to: CreativePortRef(nodeId: nodeId, portKey: param, side: .input)
        )
    }

    /// Cascade placement so stacked inserts don't fully overlap.
    private func placementPoint() -> CGPoint {
        let base = visibleWorldCenter
        let offset = CGFloat(workflow.nodes.count % 6) * 32
        return CGPoint(x: base.x - 240 + offset, y: base.y - 180 + offset)
    }

    func updateNode(_ id: String, _ mutate: (inout CreativeNode) -> Void) {
        guard let idx = workflow.nodes.firstIndex(where: { $0.id == id }) else { return }
        mutate(&workflow.nodes[idx])
        touchAndSave()
    }

    func setParam(nodeId: String, key: String, value: JSONValue?) {
        updateNode(nodeId) { node in
            if let value {
                node.params[key] = value
            } else {
                node.params.removeValue(forKey: key)
            }
        }
    }

    func commitDrag(for nodeIds: Set<String>) {
        for id in nodeIds {
            guard let offset = nodeDragOffsets[id],
                  let idx = workflow.nodes.firstIndex(where: { $0.id == id }) else { continue }
            workflow.nodes[idx].position.x += offset.width
            workflow.nodes[idx].position.y += offset.height
        }
        nodeDragOffsets = [:]
        touchAndSave()
    }

    func duplicateNode(_ id: String) {
        guard let source = workflow.node(id) else { return }
        var copy = source
        copy.id = CreativeNode.makeId()
        copy.position = CGPoint(x: source.position.x + 48, y: source.position.y + 48)
        copy.lastResult = nil
        copy.lastRunAt = nil
        copy.lastDuration = nil
        workflow.nodes.append(copy)
        selectedNodeIds = [copy.id]
        touchAndSave()
    }

    func deleteNode(_ id: String) {
        deleteNodes([id])
    }

    func deleteNodes(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        for id in ids where (runStates[id]?.isActive ?? false) {
            cancelNode(id)
        }
        // Orphaned asset files are cleaned up with their node.
        for node in workflow.nodes where ids.contains(node.id) {
            if let asset = node.media {
                Task { await CreativeStore.shared.deleteAsset(asset) }
            }
        }
        workflow.nodes.removeAll { ids.contains($0.id) }
        workflow.edges.removeAll { ids.contains($0.fromNode) || ids.contains($0.toNode) }
        selectedNodeIds.subtract(ids)
        for id in ids {
            runStates[id] = nil
            nodeSizes[id] = nil
        }
        portAnchors = portAnchors.filter { !ids.contains($0.key.nodeId) }
        touchAndSave()
    }

    func deleteSelection() {
        if !selectedEdgeIds.isEmpty {
            workflow.edges.removeAll { selectedEdgeIds.contains($0.id) }
            selectedEdgeIds = []
            touchAndSave()
        }
        if !selectedNodeIds.isEmpty {
            deleteNodes(selectedNodeIds)
        }
    }

    func select(node id: String, additive: Bool = false) {
        selectedEdgeIds = []
        if additive {
            if selectedNodeIds.contains(id) {
                selectedNodeIds.remove(id)
            } else {
                selectedNodeIds.insert(id)
            }
        } else {
            selectedNodeIds = [id]
        }
    }

    func select(edge id: UUID) {
        selectedNodeIds = []
        selectedEdgeIds = [id]
    }

    func clearSelection() {
        selectedNodeIds = []
        selectedEdgeIds = []
    }

    func selectAllNodes() {
        selectedEdgeIds = []
        selectedNodeIds = Set(workflow.nodes.map(\.id))
    }

    /// Live marquee selection: nodes whose frame intersects the swept world
    /// rect, unioned with `baseline` (the pre-drag selection when ⇧ is held).
    func marqueeSelect(worldRect: CGRect, baseline: Set<String>) {
        var hit: Set<String> = []
        for node in workflow.nodes {
            let size = nodeSizes[node.id] ?? CGSize(width: 300, height: 200)
            let drag = nodeDragOffsets[node.id] ?? .zero
            let frame = CGRect(
                x: node.position.x + drag.width,
                y: node.position.y + drag.height,
                width: size.width,
                height: size.height
            )
            if worldRect.intersects(frame) {
                hit.insert(node.id)
            }
        }
        selectedEdgeIds = []
        selectedNodeIds = baseline.union(hit)
    }

    // MARK: - Edges

    func portKind(for ref: CreativePortRef) -> CreativePortKind {
        guard let node = workflow.node(ref.nodeId) else { return .any }
        if node.kind == .media {
            return node.media?.kind.portKind ?? .file
        }
        guard let spec = spec(for: node) else { return .any }
        switch ref.side {
        case .input: return spec.input(ref.portKey)?.kind ?? .any
        case .output: return spec.output(ref.portKey)?.kind ?? .any
        }
    }

    func connect(from a: CreativePortRef, to b: CreativePortRef) {
        if let error = connectValidated(from: a, to: b) {
            showToast(error)
        }
    }

    /// Programmatic connect: returns a human-readable reason on failure, nil
    /// on success. Shared by the drag gesture (toast) and agent tools.
    @discardableResult
    func connectValidated(from a: CreativePortRef, to b: CreativePortRef) -> String? {
        // Normalize direction: exactly one output → one input.
        let output: CreativePortRef
        let input: CreativePortRef
        switch (a.side, b.side) {
        case (.output, .input): output = a; input = b
        case (.input, .output): output = b; input = a
        default:
            return "Connect an output to an input."
        }
        guard output.nodeId != input.nodeId else {
            return "A node can't feed itself."
        }
        guard !workflow.wouldCycle(from: output.nodeId, to: input.nodeId) else {
            return "That connection would create a loop."
        }
        let outKind = portKind(for: output)
        let inKind = portKind(for: input)
        guard inKind.accepts(outKind) else {
            return "\(outKind.rawValue) output doesn't fit a \(inKind.rawValue) input."
        }
        // Inputs take a single edge — a new wire replaces the old one.
        workflow.edges.removeAll { $0.toNode == input.nodeId && $0.toParam == input.portKey }
        workflow.edges.append(CreativeEdge(
            fromNode: output.nodeId,
            fromPort: output.portKey,
            toNode: input.nodeId,
            toParam: input.portKey
        ))
        touchAndSave()
        return nil
    }

    /// Positions the given nodes on a depth-based grid — used by agent edits
    /// that don't specify coordinates. Column = topological depth, row =
    /// next free slot in that column (existing nodes keep their spots).
    func autoLayout(nodeIds: Set<String>) {
        guard !nodeIds.isEmpty else { return }

        var depths: [String: Int] = [:]
        func depth(of id: String, _ visiting: inout Set<String>) -> Int {
            if let cached = depths[id] { return cached }
            guard visiting.insert(id).inserted else { return 0 }   // cycle guard
            defer { visiting.remove(id) }
            let ups = workflow.upstreamIds(of: id)
            let d = ups.isEmpty ? 0 : (ups.map { depth(of: $0, &visiting) }.max() ?? 0) + 1
            depths[id] = d
            return d
        }
        var visiting: Set<String> = []
        for node in workflow.nodes { _ = depth(of: node.id, &visiting) }

        // Stack new nodes below whatever already occupies each column.
        var rows: [Int: Int] = [:]
        for node in workflow.nodes where !nodeIds.contains(node.id) {
            rows[depths[node.id] ?? 0, default: 0] += 1
        }
        let columnWidth: CGFloat = 560   // card + flanking pin chips
        let rowHeight: CGFloat = 470
        for idx in workflow.nodes.indices where nodeIds.contains(workflow.nodes[idx].id) {
            let column = depths[workflow.nodes[idx].id] ?? 0
            let row = rows[column, default: 0]
            rows[column] = row + 1
            workflow.nodes[idx].position = CGPoint(
                x: 80 + CGFloat(column) * columnWidth,
                y: 80 + CGFloat(row) * rowHeight
            )
        }
        touchAndSave()
    }

    /// Tidies the whole graph: columns by topological depth (sized to the
    /// widest measured card per column), rows ordered by the barycenter of
    /// each node's upstream neighbors (fewer wire crossings) and stacked
    /// using real measured heights. Animated, then fit to view.
    func autoArrange() {
        guard workflow.nodes.count > 1 else {
            fitToContent()
            return
        }

        // Topological depth (longest path from a root).
        var depths: [String: Int] = [:]
        func depth(of id: String, _ visiting: inout Set<String>) -> Int {
            if let cached = depths[id] { return cached }
            guard visiting.insert(id).inserted else { return 0 }   // cycle guard
            defer { visiting.remove(id) }
            let ups = workflow.upstreamIds(of: id)
            let d = ups.isEmpty ? 0 : (ups.map { depth(of: $0, &visiting) }.max() ?? 0) + 1
            depths[id] = d
            return d
        }
        var visiting: Set<String> = []
        for node in workflow.nodes { _ = depth(of: node.id, &visiting) }

        func size(of id: String) -> CGSize {
            nodeSizes[id] ?? CGSize(width: 540, height: 420)
        }

        let maxColumn = depths.values.max() ?? 0
        var columns: [[String]] = Array(repeating: [], count: maxColumn + 1)
        for node in workflow.nodes {
            columns[depths[node.id] ?? 0].append(node.id)
        }

        // Order each column by the average row index of its upstream nodes
        // in the previous columns (barycenter heuristic — keeps chains
        // roughly horizontal). Roots keep their current vertical order.
        var rowIndex: [String: Int] = [:]
        for (columnIdx, column) in columns.enumerated() {
            var ordered = column
            if columnIdx == 0 {
                let currentY = Dictionary(uniqueKeysWithValues: workflow.nodes.map { ($0.id, $0.position.y) })
                ordered.sort { (currentY[$0] ?? 0) < (currentY[$1] ?? 0) }
            } else {
                func barycenter(_ id: String) -> Double {
                    let ups = workflow.upstreamIds(of: id).compactMap { rowIndex[$0] }
                    guard !ups.isEmpty else { return .greatestFiniteMagnitude }
                    return Double(ups.reduce(0, +)) / Double(ups.count)
                }
                ordered.sort { barycenter($0) < barycenter($1) }
            }
            columns[columnIdx] = ordered
            for (row, id) in ordered.enumerated() {
                rowIndex[id] = row
            }
        }

        // Column x positions from measured widths; rows stack from measured
        // heights, each column vertically centered against the tallest.
        let columnGap: CGFloat = 140    // room for the wire bends
        let rowGap: CGFloat = 64
        let origin = CGPoint(x: 80, y: 80)

        let columnHeights: [CGFloat] = columns.map { column in
            let heights = column.map { size(of: $0).height }
            return heights.reduce(0, +) + CGFloat(max(column.count - 1, 0)) * rowGap
        }
        let tallest = columnHeights.max() ?? 0

        var positions: [String: CGPoint] = [:]
        var x = origin.x
        for (columnIdx, column) in columns.enumerated() {
            let width = column.map { size(of: $0).width }.max() ?? 540
            var y = origin.y + (tallest - columnHeights[columnIdx]) / 2
            for id in column {
                positions[id] = CGPoint(x: x, y: y)
                y += size(of: id).height + rowGap
            }
            x += width + columnGap
        }

        withAnimation(.easeInOut(duration: 0.3)) {
            for idx in workflow.nodes.indices {
                if let p = positions[workflow.nodes[idx].id] {
                    workflow.nodes[idx].position = p
                }
            }
        }
        touchAndSave()

        // Let the animated positions land, then bring everything into view.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 320_000_000)
            fitToContent()
        }
    }

    func disconnect(edgeId: UUID) {
        workflow.edges.removeAll { $0.id == edgeId }
        selectedEdgeIds.remove(edgeId)
        touchAndSave()
    }

    func disconnectParam(nodeId: String, param: String) {
        workflow.edges.removeAll { $0.toNode == nodeId && $0.toParam == param }
        touchAndSave()
    }

    /// Starts a wire drag from a pin: precomputes the sensible-destination
    /// set once (the graph can't change mid-drag) so per-frame updates and
    /// pin highlighting are set lookups.
    func beginConnectDrag(from origin: CreativePortRef, kind: CreativePortKind, at point: CGPoint) {
        var eligible: Set<CreativePortRef> = []
        for ref in portAnchors.keys {
            guard ref.side != origin.side, ref.nodeId != origin.nodeId else { continue }
            let (outRef, inRef) = origin.side == .output ? (origin, ref) : (ref, origin)
            guard portKind(for: inRef).sensiblyAccepts(portKind(for: outRef)) else { continue }
            guard !workflow.wouldCycle(from: outRef.nodeId, to: inRef.nodeId) else { continue }
            eligible.insert(ref)
        }
        connectDrag = ConnectDrag(
            origin: origin,
            originKind: kind,
            point: point,
            candidate: nil,
            eligible: eligible
        )
    }

    /// Candidate pin for the in-flight connect drag, within grab distance —
    /// only sensible destinations qualify.
    func updateConnectCandidate() {
        guard var drag = connectDrag else { return }
        let grabRadius: CGFloat = 24 / max(zoom, 0.4)
        var best: (ref: CreativePortRef, distance: CGFloat)?
        for ref in drag.eligible {
            guard let anchor = portAnchors[ref] else { continue }
            let d = hypot(anchor.x - drag.point.x, anchor.y - drag.point.y)
            guard d <= grabRadius else { continue }
            if best == nil || d < best!.distance {
                best = (ref, d)
            }
        }
        drag.candidate = best?.ref
        connectDrag = drag
    }

    func finishConnectDrag() {
        defer { connectDrag = nil }
        guard let drag = connectDrag, let candidate = drag.candidate else { return }
        connect(from: drag.origin, to: candidate)
    }

    // MARK: - Toast

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }
}

// MARK: - Graph execution

extension CreativeCanvasController {

    enum RunError: LocalizedError {
        case missingSpec
        case missingRequired(String)
        case upstreamUnavailable(String)
        case mediaMissing

        var errorDescription: String? {
            switch self {
            case .missingSpec:
                return "Model schema isn't loaded yet."
            case .missingRequired(let key):
                return "Missing required input “\(key)”."
            case .upstreamUnavailable(let what):
                return "No value available from \(what)."
            case .mediaMissing:
                return "Media file is missing on disk."
            }
        }
    }

    private func launchGraph(subset: Set<String>) {
        let token = UUID()
        let task = Task { [weak self] in
            await self?.executeGraph(subset: subset)
            self?.graphTasks[token] = nil
        }
        graphTasks[token] = task
    }

    /// Runs the whole graph in dependency order; independent branches run in
    /// parallel (capped). Failures skip their downstream nodes but leave
    /// other branches running.
    func runAll() {
        guard !anyNodeActive else { return }
        guard !workflow.nodes.isEmpty else { return }
        guard FalAIService.shared.hasAPIKey() else {
            showToast("Add your fal.ai API key in Settings first.")
            return
        }
        launchGraph(subset: Set(workflow.nodes.map(\.id)))
    }

    /// Runs a set of nodes as a sub-workflow. Upstream dependencies that
    /// already have output are reused; missing ones (e.g. an un-run node
    /// wired into the selection) are pulled into the run automatically so
    /// inputs are ready. Disconnected nodes in the set run in parallel, and
    /// separate sub-runs can overlap as long as their chains don't.
    func runNodes(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        guard FalAIService.shared.hasAPIKey() else {
            showToast("Add your fal.ai API key in Settings first.")
            return
        }
        let needed = runClosure(for: ids)
        if needed.contains(where: { runStates[$0]?.isActive == true }) {
            showToast("Part of this chain is already running.")
            return
        }
        launchGraph(subset: needed)
    }

    /// The nodes that must execute for `ids` to have fresh inputs: the set
    /// itself plus, transitively, upstream nodes that don't have output yet.
    private func runClosure(for ids: Set<String>) -> Set<String> {
        var needed: Set<String> = []
        var stack = Array(ids)
        while let current = stack.popLast() {
            guard needed.insert(current).inserted else { continue }
            for edge in workflow.edges(into: current) {
                guard let source = workflow.node(edge.fromNode) else { continue }
                if !hasOutput(source) {
                    stack.append(edge.fromNode)
                }
            }
        }
        return needed
    }

    /// Agent entry point: runs `ids` (plus missing upstream) and suspends
    /// until the whole sub-graph settles. Returns the executed set, or a
    /// reason it couldn't start.
    func runNodesAndWait(_ ids: Set<String>) async -> (ran: Set<String>, error: String?) {
        guard !ids.isEmpty else { return ([], "No nodes to run.") }
        guard FalAIService.shared.hasAPIKey() else {
            return ([], "No fal.ai API key is set — the user can add one in Settings.")
        }
        let needed = runClosure(for: ids)
        if needed.contains(where: { runStates[$0]?.isActive == true }) {
            return ([], "Part of this chain is already running — wait for it to finish.")
        }
        let token = UUID()
        let task = Task { await executeGraph(subset: needed) }
        graphTasks[token] = task
        await task.value
        graphTasks[token] = nil
        return (needed, nil)
    }

    /// Runs one node (its missing upstream comes along automatically).
    func runNode(_ id: String) {
        runNodes([id])
    }

    /// Runs the current multi-selection as a sub-workflow.
    func runSelection() {
        runNodes(selectedNodeIds)
    }

    func stop() {
        for task in graphTasks.values {
            task.cancel()
        }
        graphTasks = [:]
        for (nodeId, ticket) in activeTickets {
            runStates[nodeId] = .idle
            Task { await FalWorkflowAPI.shared.cancel(ticket) }
        }
        activeTickets = [:]
        for (id, state) in runStates where state.isActive {
            runStates[id] = .idle
        }
    }

    func cancelNode(_ id: String) {
        if let ticket = activeTickets[id] {
            Task { await FalWorkflowAPI.shared.cancel(ticket) }
            activeTickets[id] = nil
        }
        runStates[id] = .idle
    }

    func clearResult(_ id: String) {
        updateNode(id) { node in
            node.lastResult = nil
            node.lastRunAt = nil
            node.lastDuration = nil
            node.showPreview = false
        }
        runStates[id] = .idle
    }

    private func hasOutput(_ node: CreativeNode) -> Bool {
        switch node.kind {
        case .media: return node.media?.falURL != nil
        case .model: return node.lastResult != nil
        }
    }

    /// Kahn's-algorithm scheduler over `subset`, capped parallelism. Runs on
    /// the main actor; the per-node work awaits network calls off-actor.
    private func executeGraph(subset: Set<String>) async {
        let maxConcurrent = 4

        // Dependencies restricted to the subset.
        var deps: [String: Set<String>] = [:]
        var dependents: [String: Set<String>] = [:]
        for id in subset {
            deps[id] = workflow.upstreamIds(of: id).intersection(subset)
        }
        for edge in workflow.edges where subset.contains(edge.fromNode) && subset.contains(edge.toNode) {
            dependents[edge.fromNode, default: []].insert(edge.toNode)
        }

        var pending = subset
        var launched: Set<String> = []
        var failed: Set<String> = []

        for id in subset {
            runStates[id] = .queued(position: nil)
        }

        await withTaskGroup(of: (String, Bool).self) { group in
            var active = 0

            func launchReady() {
                for id in pending.sorted() where !launched.contains(id) && active < maxConcurrent {
                    guard deps[id]?.isEmpty == true else { continue }
                    launched.insert(id)
                    active += 1
                    group.addTask { @MainActor [weak self] in
                        guard let self else { return (id, false) }
                        let ok = await self.executeNode(id)
                        return (id, ok)
                    }
                }
            }

            launchReady()
            while active > 0 {
                guard let (finished, ok) = await group.next() else { break }
                active -= 1
                pending.remove(finished)

                if Task.isCancelled {
                    continue   // drain remaining children; stop() resets states
                }

                if ok {
                    for dependent in dependents[finished] ?? [] {
                        deps[dependent]?.remove(finished)
                    }
                } else {
                    failed.insert(finished)
                    // Transitively skip everything downstream of the failure.
                    var frontier = Array(dependents[finished] ?? [])
                    while let skipId = frontier.popLast() {
                        guard pending.contains(skipId), !launched.contains(skipId) else { continue }
                        pending.remove(skipId)
                        runStates[skipId] = .skipped(reason: "Upstream failed")
                        frontier.append(contentsOf: dependents[skipId] ?? [])
                    }
                }
                launchReady()
            }
        }

        // Anything left queued (unreachable due to skips/cycles) goes idle.
        for id in pending where runStates[id]?.isActive == true {
            if case .queued = runStates[id] ?? .idle {
                runStates[id] = .idle
            }
        }
    }

    /// Executes one node end-to-end. Returns success.
    private func executeNode(_ id: String) async -> Bool {
        guard let node = workflow.node(id) else { return false }
        do {
            switch node.kind {
            case .media:
                try await ensureMediaUploaded(id)
                return true
            case .model:
                try await executeModelNode(id)
                return true
            }
        } catch is CancellationError {
            if let ticket = activeTickets[id] {
                await FalWorkflowAPI.shared.cancel(ticket)
            }
            activeTickets[id] = nil
            runStates[id] = .idle
            return false
        } catch {
            activeTickets[id] = nil
            runStates[id] = .failed(message: error.localizedDescription)
            return false
        }
    }

    private func ensureMediaUploaded(_ id: String) async throws {
        guard let node = workflow.node(id), let asset = node.media else {
            throw RunError.mediaMissing
        }
        if asset.falURL != nil {
            runStates[id] = .succeeded(duration: 0)
            return
        }
        let fileURL = CreativePaths.assetURL(for: asset)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw RunError.mediaMissing
        }
        runStates[id] = .uploading
        let started = Date()
        let remote = try await FalWorkflowAPI.shared.upload(fileURL: fileURL)
        try Task.checkCancellation()
        updateNode(id) { $0.media?.falURL = remote }
        runStates[id] = .succeeded(duration: Date().timeIntervalSince(started))
    }

    private func executeModelNode(_ id: String) async throws {
        guard let node = workflow.node(id), let endpointId = node.endpointId else {
            throw RunError.missingSpec
        }
        // Ensure the spec is available (it drives validation + coercion).
        var spec = specs[endpointId]
        if spec == nil {
            spec = try await FalWorkflowAPI.shared.nodeSpec(for: endpointId)
            specs[endpointId] = spec
        }
        guard let spec else { throw RunError.missingSpec }

        let inputs = try resolveInputs(for: node, spec: spec)

        runStates[id] = .queued(position: nil)
        let started = Date()
        let ticket = try await FalWorkflowAPI.shared.submit(endpointId: endpointId, input: inputs)
        activeTickets[id] = ticket

        // Poll until completed. Queue positions surface live in the header.
        var interval: UInt64 = 900_000_000
        while true {
            try Task.checkCancellation()
            let status = try await FalWorkflowAPI.shared.status(of: ticket)
            switch status {
            case .inQueue(let position):
                runStates[id] = .queued(position: position)
            case .inProgress:
                runStates[id] = .running
            case .completed:
                let result = try await FalWorkflowAPI.shared.result(of: ticket)
                activeTickets[id] = nil
                let duration = Date().timeIntervalSince(started)
                updateNode(id) { n in
                    n.lastResult = result
                    n.lastRunAt = Date()
                    n.lastDuration = duration
                    // Fresh output flips the card to its preview face — the
                    // eye button in the header toggles back to parameters.
                    n.showPreview = true
                }
                runStates[id] = .succeeded(duration: duration)
                return
            }
            try await Task.sleep(nanoseconds: interval)
            if Date().timeIntervalSince(started) > 60 {
                interval = 2_000_000_000
            }
        }
    }

    // MARK: Input resolution

    /// Manual params + connected upstream values, coerced to each param's
    /// expected shape, validated for required coverage.
    private func resolveInputs(for node: CreativeNode, spec: CreativeNodeSpec) throws -> [String: JSONValue] {
        var inputs: [String: JSONValue] = [:]

        for (key, value) in node.params {
            if case .string(let s) = value, s.isEmpty { continue }   // cleared fields
            if value.isNull { continue }
            inputs[key] = value
        }

        for edge in workflow.edges(into: node.id) {
            guard let source = workflow.node(edge.fromNode) else { continue }
            guard let raw = portValue(of: source, portKey: edge.fromPort) else {
                throw RunError.upstreamUnavailable(edge.referenceLabel)
            }
            inputs[edge.toParam] = coerce(raw, for: spec.input(edge.toParam))
        }

        for param in spec.inputs where param.required {
            let present: Bool
            if let v = inputs[param.key] {
                if case .string(let s) = v { present = !s.isEmpty } else { present = !v.isNull }
            } else {
                present = false
            }
            guard present else { throw RunError.missingRequired(param.key) }
        }
        return inputs
    }

    /// Extracts the value an output port carries. Media objects normalize to
    /// their URL string; arrays normalize element-wise.
    func portValue(of node: CreativeNode, portKey: String) -> JSONValue? {
        if node.kind == .media {
            return node.media?.falURL.map { .string($0) }
        }
        guard let object = node.lastResult?.objectValue, let raw = object[portKey] else { return nil }
        return Self.normalizedPortValue(raw)
    }

    nonisolated static func normalizedPortValue(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let o):
            if let url = o["url"]?.stringValue { return .string(url) }
            return value
        case .array(let items):
            return .array(items.map { normalizedPortValue($0) })
        default:
            return value
        }
    }

    /// Best-effort shape adaptation between connected ports; anything truly
    /// incompatible is left for the server to reject with a real message.
    private func coerce(_ value: JSONValue, for param: CreativeParamSpec?) -> JSONValue {
        guard let param else { return value }
        var v = value

        if param.isArrayInput {
            if v.arrayValue == nil { v = .array([v]) }
            return v
        }
        // Scalar target fed by an array (e.g. images → image_url): take first.
        if let array = v.arrayValue {
            v = array.first ?? .null
        }

        switch param.kind {
        case .number:
            if let d = v.doubleValue { return .number(param.isInteger ? d.rounded() : d) }
        case .string, .enumeration, .image, .video, .audio, .file:
            switch v {
            case .string: return v
            case .number, .bool: return .string(v.displayString)
            case .object(let o):
                if let url = o["url"]?.stringValue { return .string(url) }
            default: break
            }
        case .boolean:
            if let b = v.boolValue { return .bool(b) }
            if let s = v.stringValue { return .bool((s as NSString).boolValue) }
        case .object, .any:
            return v
        }
        return v
    }
}
