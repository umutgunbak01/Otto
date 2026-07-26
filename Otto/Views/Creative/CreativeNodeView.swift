import SwiftUI
import AppKit

/// A node on the Creative canvas: labeled, type-colored pin chips flank a
/// card that carries the header (icon · title · endpoint id), inline param
/// editors, the "Additional settings" expander, result previews, and the
/// `ID: node-…` footer — mirroring fal workflows' node structure in Otto's
/// design system.
struct CreativeNodeView: View {
    let node: CreativeNode

    @State private var hovering = false
    @State private var presentedMedia: CreativeMediaPreviewItem?

    private var controller: CreativeCanvasController { .shared }

    private var spec: CreativeNodeSpec? { controller.spec(for: node) }
    private var runState: CreativeRunState { controller.runStates[node.id] ?? .idle }
    private var isSelected: Bool { controller.selectedNodeIds.contains(node.id) }

    private var cardWidth: CGFloat { node.kind == .media ? 224 : 300 }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if node.kind == .model {
                inputPinColumn
                    .padding(.top, 44)
            }

            card
                .frame(width: cardWidth)

            outputPinColumn
                .padding(.top, 44)
        }
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.frame(in: .named(CreativeCanvasView.worldSpace)).size
        } action: { size in
            controller.nodeSizes[node.id] = size
        }
        .sheet(item: $presentedMedia) { item in
            CreativeMediaPreviewSheet(item: item)
        }
    }

    // MARK: - Pin columns

    private var inputParams: [CreativeParamSpec] {
        spec?.inputs ?? []
    }

    private var outputPorts: [CreativePortSpec] {
        if node.kind == .media {
            let kind = node.media?.kind.portKind ?? .file
            return [CreativePortSpec(key: "url", title: "url", kind: kind, isArray: false)]
        }
        return spec?.outputs ?? []
    }

    private var inputPinColumn: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(inputParams) { param in
                CreativePinChip(
                    ref: CreativePortRef(nodeId: node.id, portKey: param.key, side: .input),
                    label: param.key,
                    kind: param.kind,
                    isConnected: controller.workflow.edge(into: node.id, param: param.key) != nil,
                    emphasized: param.required
                )
            }
        }
    }

    private var outputPinColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(outputPorts) { port in
                CreativePinChip(
                    ref: CreativePortRef(nodeId: node.id, portKey: port.key, side: .output),
                    label: port.key,
                    kind: port.kind,
                    isConnected: !controller.workflow.edges.filter {
                        $0.fromNode == node.id && $0.fromPort == port.key
                    }.isEmpty,
                    emphasized: false
                )
            }
        }
    }

    // MARK: - Card

    /// Result payload flattened for display; nil when there is nothing to show.
    private var resultItems: CreativeResultItems? {
        guard let result = node.lastResult else { return nil }
        let items = CreativeResultItems(result: result, outputs: outputPorts, nodeTitle: node.title)
        return items.isEmpty ? nil : items
    }

    private var card: some View {
        VStack(spacing: 0) {
            header
            OttoDivider()

            if node.kind == .media {
                mediaBody
            } else if node.showPreview, let items = resultItems {
                // Preview layer — the card face becomes the result; the eye
                // button in the header flips back to the parameter editors.
                CreativeResultSection(items: items) { media in
                    presentedMedia = media
                }
            } else {
                modelBody
            }

            if let banner = failureBanner {
                banner
            }

            OttoDivider()
            footer
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.xl)
                .fill(Theme.Colors.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.xl)
                .strokeBorder(borderColor, lineWidth: borderWidth)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xl))
        // Flatten the card into one layer before blurring — without this the
        // shadow filter re-evaluates the whole subtree during zoom.
        .compositingGroup()
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .onHover { hovering = $0 }
        .onTapGesture {
            controller.select(node: node.id, additive: NSEvent.modifierFlags.contains(.shift))
        }
    }

    private var borderColor: Color {
        if case .failed = runState { return Theme.Colors.red.opacity(0.55) }
        if runState.isActive { return Theme.Colors.accent.opacity(0.6) }
        if isSelected { return Theme.Colors.accentText.opacity(0.8) }
        if hovering { return Theme.Colors.borderStrong }
        return Theme.Colors.border
    }

    private var borderWidth: CGFloat {
        isSelected || runState.isActive ? 1.2 : 1
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 9) {
            headerIcon

            VStack(alignment: .leading, spacing: 1) {
                Text(node.title)
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.Colors.text)
                    .lineLimit(1)
                if let subtitle = node.subtitle ?? node.media.map({ $0.kind.displayName }) {
                    // Middle truncation keeps the endpoint's variant tail
                    // (…/edit) readable when the id is long.
                    Text(subtitle)
                        .font(Theme.Typography.monoSmall)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 4)

            statusView

            if node.kind == .model, resultItems != nil {
                Button {
                    controller.updateNode(node.id) { $0.showPreview.toggle() }
                } label: {
                    Image(systemName: node.showPreview ? "eye.fill" : "eye")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(node.showPreview ? Theme.Colors.accentText : Theme.Colors.textDim)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(node.showPreview ? "Show parameters" : "Show result preview")
            }

            Menu {
                menuItems
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textDim)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 20)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .contextMenu { menuItems }
    }

    @ViewBuilder
    private var headerIcon: some View {
        if let thumb = node.thumbnailUrl, let url = URL(string: thumb) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    fallbackIcon
                }
            }
            .frame(width: 26, height: 26)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            fallbackIcon
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Theme.Colors.bgInput)
                )
        }
    }

    private var fallbackIcon: some View {
        Image(systemName: fallbackIconName)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.Colors.textDim)
    }

    private var fallbackIconName: String {
        if node.kind == .media { return node.media?.kind.iconName ?? "doc" }
        let category = (node.category ?? "").lowercased()
        if category.contains("video") { return "film" }
        if category.contains("image") { return "photo" }
        if category.contains("audio") || category.contains("speech") || category.contains("music") { return "waveform" }
        if category.contains("llm") || category.contains("text") { return "text.alignleft" }
        return "cpu"
    }

    @ViewBuilder
    private var menuItems: some View {
        if node.kind == .model {
            Button {
                controller.runNode(node.id)
            } label: {
                Label("Run node", systemImage: "play")
            }
            .disabled(runState.isActive)
        }
        if controller.selectedNodeIds.count > 1, controller.selectedNodeIds.contains(node.id) {
            Button {
                controller.runSelection()
            } label: {
                Label("Run selection (\(controller.selectedNodeIds.count))", systemImage: "play.square")
            }
        }
        Button {
            controller.duplicateNode(node.id)
        } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.id, forType: .string)
        } label: {
            Label("Copy node ID", systemImage: "doc.on.doc")
        }
        if node.kind == .media, let asset = node.media {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([CreativePaths.assetURL(for: asset)])
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            if let fal = asset.falURL {
                Button {
                    CreativeMediaSaver.copyURL(fal)
                } label: {
                    Label("Copy fal URL", systemImage: "link")
                }
            }
        }
        if node.lastResult != nil {
            Button {
                controller.clearResult(node.id)
            } label: {
                Label("Clear result", systemImage: "arrow.counterclockwise")
            }
        }
        if runState.isActive {
            Button {
                controller.cancelNode(node.id)
            } label: {
                Label("Cancel", systemImage: "stop.circle")
            }
        }
        Divider()
        Button(role: .destructive) {
            controller.deleteNode(node.id)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch runState {
        case .idle:
            EmptyView()
        case .uploading:
            statusChip(text: "Uploading", spinning: true, color: Theme.Colors.textDim)
        case .queued(let position):
            statusChip(
                text: position.map { "Queue #\($0)" } ?? "Queued",
                spinning: true,
                color: Theme.Colors.amber
            )
        case .running:
            statusChip(text: "Running", spinning: true, color: Theme.Colors.accentText)
        case .succeeded(let duration):
            HStack(spacing: 3) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Colors.green)
                if duration > 0.05 {
                    Text(Self.durationText(duration))
                        .font(Theme.Typography.monoSmall)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
            }
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Theme.Colors.red)
        case .skipped:
            Image(systemName: "forward.end")
                .font(.system(size: 9))
                .foregroundStyle(Theme.Colors.tertiaryText)
                .help("Skipped — upstream failed")
        }
    }

    private func statusChip(text: String, spinning: Bool, color: Color) -> some View {
        HStack(spacing: 4) {
            if spinning {
                ProgressView()
                    .controlSize(.mini)
            }
            Text(text)
                .font(Theme.Typography.monoSmall)
                .foregroundStyle(color)
        }
    }

    static func durationText(_ duration: Double) -> String {
        duration >= 60
            ? String(format: "%dm %02ds", Int(duration) / 60, Int(duration) % 60)
            : String(format: "%.1fs", duration)
    }

    // MARK: Drag

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(CreativeCanvasView.worldSpace))
            .onChanged { value in
                if !controller.selectedNodeIds.contains(node.id) {
                    controller.select(node: node.id)
                }
                // Selected nodes move together.
                let moving = controller.selectedNodeIds.contains(node.id)
                    ? controller.selectedNodeIds
                    : [node.id]
                for id in moving {
                    controller.nodeDragOffsets[id] = value.translation
                }
            }
            .onEnded { _ in
                let moving = controller.selectedNodeIds.contains(node.id)
                    ? controller.selectedNodeIds
                    : [node.id]
                controller.commitDrag(for: moving)
            }
    }

    // MARK: Model body

    @ViewBuilder
    private var modelBody: some View {
        if let spec {
            let featured = spec.inputs.filter { isVisible($0) }
            let hiddenCount = spec.inputs.count - featured.count

            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                ForEach(featured) { param in
                    CreativeParamRow(
                        node: node,
                        param: param,
                        incomingEdge: controller.workflow.edge(into: node.id, param: param.key)
                    )
                }
                if featured.isEmpty {
                    Text("No inputs")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
            }
            .padding(Theme.Spacing.md)

            if hiddenCount > 0 || node.showAllParams {
                OttoDivider()
                Button {
                    controller.updateNode(node.id) { $0.showAllParams.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Text("Additional settings")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.textDim)
                        if !node.showAllParams, hiddenCount > 0 {
                            Text("\(hiddenCount)")
                                .font(Theme.Typography.monoSmall)
                                .foregroundStyle(Theme.Colors.tertiaryText)
                        }
                        Spacer()
                        Image(systemName: node.showAllParams ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } else if let error = node.endpointId.flatMap({ controller.specErrors[$0] }) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text(error)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.red)
                    .lineLimit(3)
                Button("Retry") {
                    if let id = node.endpointId { controller.ensureSpec(id, force: true) }
                }
                .buttonStyle(GhostButtonStyle())
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.accentText)
            }
            .padding(Theme.Spacing.md)
        } else {
            HStack(spacing: Theme.Spacing.sm) {
                ProgressView().controlSize(.small)
                Text("Loading schema…")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
            .padding(Theme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func isVisible(_ param: CreativeParamSpec) -> Bool {
        if node.showAllParams { return true }
        if param.featured { return true }
        if node.params[param.key] != nil { return true }
        return controller.workflow.edge(into: node.id, param: param.key) != nil
    }

    // MARK: Media body

    @ViewBuilder
    private var mediaBody: some View {
        if let asset = node.media {
            let localURL = CreativePaths.assetURL(for: asset)
            VStack(spacing: 0) {
                switch asset.kind {
                case .image, .video:
                    CreativeThumbView(source: .local(localURL), kind: asset.kind, maxPixel: 512)
                        .frame(height: 118)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .overlay(alignment: .center) {
                            if asset.kind == .video {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 24))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .shadow(radius: 4)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            presentedMedia = CreativeMediaPreviewItem(
                                location: .local(localURL),
                                kind: asset.kind,
                                title: asset.fileName
                            )
                        }
                case .audio:
                    CreativeAudioPlayerRow(url: localURL)
                        .padding(Theme.Spacing.md)
                case .file:
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: "doc")
                            .foregroundStyle(Theme.Colors.tertiaryText)
                        Text(asset.fileName)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.textDim)
                            .lineLimit(1)
                    }
                    .padding(Theme.Spacing.md)
                }

                HStack(spacing: 6) {
                    Text(asset.kind.displayName.lowercased())
                        .font(Theme.Typography.monoSmall)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                    if let size = asset.byteSize {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                            .font(Theme.Typography.monoSmall)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }
                    Spacer()
                    if asset.falURL != nil {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark.icloud")
                                .font(.system(size: 8))
                            Text("uploaded")
                                .font(Theme.Typography.monoSmall)
                        }
                        .foregroundStyle(Theme.Colors.green.opacity(0.8))
                    } else {
                        Text("local")
                            .font(Theme.Typography.monoSmall)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, 7)
            }
        }
    }

    // MARK: Failure banner

    private var failureBanner: AnyView? {
        guard let message = runState.failureMessage else { return nil }
        return AnyView(
            HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Colors.red)
                    .padding(.top, 1)
                Text(message)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.red)
                    .lineLimit(4)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                if node.kind == .model {
                    Button("Retry") { controller.runNode(node.id) }
                        .buttonStyle(.plain)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.accentText)
                }
            }
            .padding(Theme.Spacing.md)
            .background(Theme.Colors.tintRed)
        )
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 5) {
            Text("ID:")
                .font(Theme.Typography.monoSmall)
                .foregroundStyle(Theme.Colors.tertiaryText)
            Text(node.id)
                .font(Theme.Typography.monoSmall)
                .foregroundStyle(Theme.Colors.textDim)
                .lineLimit(1)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.id, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 8))
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
            .buttonStyle(.plain)
            .help("Copy node ID")
            Spacer()
            if node.kind == .model, let duration = node.lastDuration {
                Text(Self.durationText(duration))
                    .font(Theme.Typography.monoSmall)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .gesture(dragGesture)
    }
}

// MARK: - Pin chip

/// Labeled pin: `[■] name` for inputs, `name [■]` for outputs — the colored
/// square is the wire anchor and drag handle, placed on the routing side.
struct CreativePinChip: View {
    let ref: CreativePortRef
    let label: String
    let kind: CreativePortKind
    let isConnected: Bool
    let emphasized: Bool

    private var controller: CreativeCanvasController { .shared }

    private var isCandidate: Bool {
        controller.connectDrag?.candidate == ref
    }

    private var isDragOrigin: Bool {
        controller.connectDrag?.origin == ref
    }

    /// A wire drag is in flight and this pin is a sensible destination.
    private var isEligibleTarget: Bool {
        controller.connectDrag?.eligible.contains(ref) == true
    }

    /// A wire drag is in flight and this pin is neither its source nor a
    /// sensible destination — fade it out of consideration.
    private var isDimmed: Bool {
        controller.connectDrag != nil && !isEligibleTarget && !isDragOrigin
    }

    var body: some View {
        HStack(spacing: 6) {
            if ref.side == .input {
                square
                labelText
            } else {
                labelText
                square
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Theme.Colors.bg1.opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(borderColor, lineWidth: isCandidate ? 1.3 : 1)
                )
        )
        .opacity(isDimmed ? 0.3 : 1)
        .contentShape(Rectangle())
        .gesture(connectGesture)
        .animation(.easeOut(duration: 0.15), value: isDimmed)
        // Deliberately no .help here — a graph can carry hundreds of pins,
        // and each tooltip registers an AppKit tracking area.
    }

    private var borderColor: Color {
        if isCandidate { return kind.pinColor }
        if isEligibleTarget { return kind.pinColor.opacity(0.55) }
        if isDragOrigin { return Theme.Colors.borderStrong }
        return Theme.Colors.border
    }

    private var labelText: some View {
        Text(label)
            .font(Theme.Typography.monoSmall)
            .foregroundStyle(
                isEligibleTarget || emphasized ? Theme.Colors.text : Theme.Colors.textDim
            )
            .lineLimit(1)
    }

    private var square: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(kind.pinColor.opacity(
                isConnected || isCandidate || isDragOrigin || isEligibleTarget ? 1 : 0.75
            ))
            .frame(width: 9, height: 9)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(
                        .white.opacity(isConnected || isEligibleTarget ? 0.5 : 0),
                        lineWidth: 1
                    )
            )
            .scaleEffect(isCandidate ? 1.35 : (isEligibleTarget ? 1.15 : 1))
            .animation(.easeOut(duration: 0.12), value: isCandidate)
            .animation(.easeOut(duration: 0.15), value: isEligibleTarget)
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(CreativeCanvasView.worldSpace))
            } action: { frame in
                controller.portAnchors[ref] = CGPoint(x: frame.midX, y: frame.midY)
            }
    }

    private var connectGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(CreativeCanvasView.worldSpace))
            .onChanged { value in
                if controller.connectDrag == nil {
                    controller.beginConnectDrag(from: ref, kind: kind, at: value.location)
                } else {
                    controller.connectDrag?.point = value.location
                }
                controller.updateConnectCandidate()
            }
            .onEnded { _ in
                controller.finishConnectDrag()
            }
    }
}

// MARK: - Result rendering

/// Flattens a run result into displayable pieces using the output port specs.
struct CreativeResultItems {
    var medias: [CreativeMediaPreviewItem] = []
    var texts: [(key: String, value: String)] = []
    var primitives: [(key: String, value: String)] = []

    var isEmpty: Bool { medias.isEmpty && texts.isEmpty && primitives.isEmpty }

    init(result: JSONValue, outputs: [CreativePortSpec], nodeTitle: String) {
        guard let object = result.objectValue else {
            if let s = result.stringValue { texts.append(("output", s)) }
            return
        }
        // Fall back to inferring ports from the payload when the spec hasn't
        // loaded — results should render regardless.
        let ports: [CreativePortSpec] = !outputs.isEmpty ? outputs : object.keys.sorted().map {
            CreativePortSpec(key: $0, title: $0, kind: .any, isArray: false)
        }

        for port in ports {
            guard let raw = object[port.key] else { continue }
            let normalized = CreativeCanvasController.normalizedPortValue(raw)

            func appendMedia(_ urlString: String, kind: CreativePortKind) {
                let mediaKind: CreativeMediaKind
                switch kind {
                case .image: mediaKind = .image
                case .video: mediaKind = .video
                case .audio: mediaKind = .audio
                default: mediaKind = Self.guessKind(from: urlString)
                }
                medias.append(CreativeMediaPreviewItem(
                    location: .remote(urlString),
                    kind: mediaKind,
                    title: "\(nodeTitle) · \(port.key)"
                ))
            }

            switch normalized {
            case .string(let s):
                if port.kind.isMedia {
                    appendMedia(s, kind: port.kind)
                } else if s.hasPrefix("https://") && Self.looksLikeMediaURL(s) {
                    appendMedia(s, kind: .any)
                } else if s.count > 60 || s.contains("\n") || port.key == "output" || port.key == "text" {
                    texts.append((port.key, s))
                } else if !s.isEmpty {
                    primitives.append((port.key, s))
                }
            case .array(let items):
                for item in items {
                    if let s = item.stringValue {
                        if port.kind.isMedia || Self.looksLikeMediaURL(s) {
                            appendMedia(s, kind: port.kind)
                        }
                    }
                }
            case .number, .bool:
                primitives.append((port.key, normalized.displayString))
            default:
                break
            }
        }
    }

    private static func looksLikeMediaURL(_ s: String) -> Bool {
        guard let url = URL(string: s) else { return false }
        let ext = url.pathExtension.lowercased()
        return !ext.isEmpty && CreativeMediaKind.from(fileExtension: ext) != .file
    }

    private static func guessKind(from urlString: String) -> CreativeMediaKind {
        let ext = URL(string: urlString)?.pathExtension ?? ""
        let kind = CreativeMediaKind.from(fileExtension: ext)
        return kind
    }
}

struct CreativeResultSection: View {
    let items: CreativeResultItems
    let onOpen: (CreativeMediaPreviewItem) -> Void

    private var controller: CreativeCanvasController { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            if !items.medias.isEmpty {
                mediaGrid
            }
            ForEach(items.texts, id: \.key) { text in
                textBlock(text.key, text.value)
            }
            if !items.primitives.isEmpty {
                primitiveRow
            }
        }
        .padding(Theme.Spacing.md)
    }

    private var mediaGrid: some View {
        let columns = items.medias.count == 1
            ? [GridItem(.flexible())]
            : [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(items.medias) { media in
                mediaCell(media)
            }
        }
    }

    @ViewBuilder
    private func mediaCell(_ media: CreativeMediaPreviewItem) -> some View {
        if media.kind == .audio {
            if let url = media.playbackURL {
                HStack(spacing: 6) {
                    CreativeAudioPlayerRow(url: url)
                    saveButton(media)
                }
            }
        } else {
            CreativeThumbView(
                source: .remote(media.urlString),
                kind: media.kind,
                maxPixel: 512
            )
            .frame(height: items.medias.count == 1 ? 236 : 118)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .strokeBorder(Theme.Colors.borderSubtle, lineWidth: 1)
            )
            .overlay(alignment: .center) {
                if media.kind == .video {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.85))
                        .shadow(radius: 4)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 4) {
                    saveButton(media)
                    Button {
                        CreativeMediaSaver.copyURL(media.urlString)
                    } label: {
                        overlayIcon("link")
                    }
                    .buttonStyle(.plain)
                    .help("Copy URL")
                }
                .padding(5)
            }
            .contentShape(Rectangle())
            .onTapGesture { onOpen(media) }
        }
    }

    private func saveButton(_ media: CreativeMediaPreviewItem) -> some View {
        Button {
            CreativeMediaSaver.save(item: media)
        } label: {
            overlayIcon("arrow.down.to.line")
        }
        .buttonStyle(.plain)
        .help("Save original")
    }

    private func overlayIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white.opacity(0.9))
            .frame(width: 20, height: 20)
            .background(Circle().fill(.black.opacity(0.55)))
    }

    private func textBlock(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(key)
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                    controller.showToast("Copied")
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 8))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
                .buttonStyle(.plain)
            }
            ScrollView(.vertical) {
                Text(value)
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Colors.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 110)
            .onHover { hovering in
                controller.scrollPassthroughDepth += hovering ? 1 : -1
                if controller.scrollPassthroughDepth < 0 { controller.scrollPassthroughDepth = 0 }
            }
        }
        .padding(Theme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(Theme.Colors.bgInput.opacity(0.7))
        )
    }

    private var primitiveRow: some View {
        HStack(spacing: 6) {
            ForEach(items.primitives.prefix(4), id: \.key) { item in
                HStack(spacing: 4) {
                    Text(item.key)
                        .font(Theme.Typography.monoSmall)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                    Text(item.value)
                        .font(Theme.Typography.monoSmall)
                        .foregroundStyle(Theme.Colors.textDim)
                        .lineLimit(1)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Theme.Colors.bgInput.opacity(0.6))
                )
            }
        }
    }
}
