import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// One input parameter row inside a node card: label line + editor (or the
/// dimmed `$node-….port` reference box when the input is wired).
struct CreativeParamRow: View {
    let node: CreativeNode
    let param: CreativeParamSpec
    let incomingEdge: CreativeEdge?

    private var controller: CreativeCanvasController { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text(param.title)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textDim)
                if param.required {
                    Text("*")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.accentText)
                }
                if let detail = param.detail, !detail.isEmpty {
                    Image(systemName: "info.circle")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .help(detail)
                }
                Spacer(minLength: 4)

                if incomingEdge == nil, param.kind == .boolean, !param.isArrayInput {
                    boolToggle
                }
            }

            if let edge = incomingEdge {
                connectedReference(edge)
            } else if param.kind != .boolean || param.isArrayInput {
                editor
            }
        }
    }

    // MARK: - Connected state

    private func connectedReference(_ edge: CreativeEdge) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(sourceKind(of: edge).pinColor)
                .frame(width: 6, height: 6)
            Text(edge.referenceLabel)
                .font(Theme.Typography.monoCaption)
                .foregroundStyle(Theme.Colors.accentText.opacity(0.75))
                .lineLimit(1)
            Spacer(minLength: 4)
            Button {
                controller.disconnectParam(nodeId: node.id, param: param.key)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
            .buttonStyle(.plain)
            .help("Disconnect")
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(Theme.Colors.bgInput.opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .strokeBorder(Theme.Colors.accent.opacity(0.25), lineWidth: 1)
                )
        )
    }

    private func sourceKind(of edge: CreativeEdge) -> CreativePortKind {
        controller.portKind(for: CreativePortRef(nodeId: edge.fromNode, portKey: edge.fromPort, side: .output))
    }

    // MARK: - Editors

    @ViewBuilder
    private var editor: some View {
        if param.isArrayInput || param.kind == .object {
            CreativeJSONEditor(node: node, param: param)
        } else {
            switch param.kind {
            case .string:
                if param.multiline {
                    CreativeMultilineEditor(node: node, param: param)
                } else {
                    CreativeTextEditorField(node: node, param: param)
                }
            case .number:
                CreativeNumberEditor(node: node, param: param)
            case .enumeration:
                CreativeEnumEditor(node: node, param: param)
            case .image, .video, .audio, .file:
                CreativeMediaWell(node: node, param: param)
            case .boolean, .object, .any:
                CreativeTextEditorField(node: node, param: param)
            }
        }
    }

    private var boolToggle: some View {
        Toggle("", isOn: Binding(
            get: {
                node.params[param.key]?.boolValue ?? param.defaultValue?.boolValue ?? false
            },
            set: { controller.setParam(nodeId: node.id, key: param.key, value: .bool($0)) }
        ))
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(Theme.Colors.cyan)
    }
}

// MARK: - Field chrome shared by editors

private struct CreativeFieldBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(Theme.Colors.bgInput)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.sm)
                            .strokeBorder(Theme.Colors.borderSubtle, lineWidth: 1)
                    )
            )
    }
}

extension View {
    fileprivate func creativeField() -> some View {
        modifier(CreativeFieldBackground())
    }
}

// MARK: - String

struct CreativeTextEditorField: View {
    let node: CreativeNode
    let param: CreativeParamSpec

    private var controller: CreativeCanvasController { .shared }

    var body: some View {
        TextField(placeholder, text: Binding(
            get: { node.params[param.key]?.stringValue ?? "" },
            set: { newValue in
                controller.setParam(
                    nodeId: node.id,
                    key: param.key,
                    value: newValue.isEmpty ? nil : .string(newValue)
                )
            }
        ))
        .textFieldStyle(.plain)
        .font(Theme.Typography.callout)
        .foregroundStyle(Theme.Colors.text)
        .creativeField()
    }

    private var placeholder: String {
        if let d = param.defaultValue, !d.isNull { return d.displayString }
        return param.title
    }
}

struct CreativeMultilineEditor: View {
    let node: CreativeNode
    let param: CreativeParamSpec

    @State private var draft = ""
    @State private var loadedFor: String?
    @State private var commitTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    private var controller: CreativeCanvasController { .shared }

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $draft)
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Colors.text)
                .scrollContentBackground(.hidden)
                .focused($focused)
                .frame(minHeight: 54, maxHeight: 110)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            if draft.isEmpty {
                Text(param.detail ?? param.title)
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .lineLimit(2)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(Theme.Colors.bgInput)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .strokeBorder(Theme.Colors.borderSubtle, lineWidth: 1)
                )
        )
        // Let the editor scroll its own overflow instead of panning the canvas.
        .onHover { hovering in
            controller.scrollPassthroughDepth += hovering ? 1 : -1
            if controller.scrollPassthroughDepth < 0 { controller.scrollPassthroughDepth = 0 }
        }
        .onAppear { syncDraft() }
        .onChange(of: node.params[param.key]) { _, _ in syncDraft() }
        .onChange(of: draft) { _, _ in
            // Debounced commit: mutating the workflow struct invalidates
            // every canvas view, so prompt keystrokes stay local and land in
            // the model shortly after typing pauses.
            commitTask?.cancel()
            commitTask = Task {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                commitDraft()
            }
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { commitNow() }
        }
        .onDisappear { commitNow() }
    }

    private func commitNow() {
        commitTask?.cancel()
        commitTask = nil
        commitDraft()
    }

    private func commitDraft() {
        let current = node.params[param.key]?.stringValue ?? ""
        guard draft != current else { return }
        controller.setParam(
            nodeId: node.id,
            key: param.key,
            value: draft.isEmpty ? nil : .string(draft)
        )
    }

    private func syncDraft() {
        let value = node.params[param.key]?.stringValue ?? ""
        if loadedFor != node.id || draft != value {
            // Only overwrite the draft when the model changed underneath us
            // (e.g. workflow switch), not on our own echo.
            if loadedFor != node.id || value != draft {
                draft = value
            }
            loadedFor = node.id
        }
    }
}

// MARK: - Number

struct CreativeNumberEditor: View {
    let node: CreativeNode
    let param: CreativeParamSpec

    @State private var text = ""
    @State private var loadedFor: String?

    private var controller: CreativeCanvasController { .shared }

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            if let minimum = param.minimum, let maximum = param.maximum, maximum > minimum {
                Slider(
                    value: Binding(
                        get: { currentValue ?? param.defaultValue?.doubleValue ?? minimum },
                        set: { newValue in
                            let v = param.isInteger ? newValue.rounded() : (newValue * 100).rounded() / 100
                            controller.setParam(nodeId: node.id, key: param.key, value: .number(v))
                            text = format(v)
                        }
                    ),
                    in: minimum...maximum
                )
                .controlSize(.mini)
                .tint(Theme.Colors.cyanDim)
            }

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(Theme.Typography.monoCaption)
                .foregroundStyle(Theme.Colors.text)
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
                .creativeField()
                .onSubmit { commitText() }
                .onChange(of: text) { _, _ in commitText() }
        }
        .onAppear { syncText() }
        .onChange(of: node.params[param.key]) { _, _ in syncText() }
    }

    private var currentValue: Double? {
        node.params[param.key]?.doubleValue
    }

    private var placeholder: String {
        if let d = param.defaultValue?.doubleValue { return format(d) }
        return "—"
    }

    private func format(_ v: Double) -> String {
        if param.isInteger || v.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(v))
        }
        return String(v)
    }

    private func commitText() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            controller.setParam(nodeId: node.id, key: param.key, value: nil)
            return
        }
        guard let value = Double(trimmed) else { return }
        controller.setParam(
            nodeId: node.id,
            key: param.key,
            value: .number(param.isInteger ? value.rounded() : value)
        )
    }

    private func syncText() {
        let modelText = currentValue.map(format) ?? ""
        if loadedFor != node.id || (Double(text) != currentValue && modelText != text) {
            text = modelText
            loadedFor = node.id
        }
    }
}

// MARK: - Enum

struct CreativeEnumEditor: View {
    let node: CreativeNode
    let param: CreativeParamSpec

    private var controller: CreativeCanvasController { .shared }

    var body: some View {
        Menu {
            ForEach(param.enumValues ?? [], id: \.self) { option in
                Button {
                    controller.setParam(nodeId: node.id, key: param.key, value: .string(option))
                } label: {
                    if option == selection {
                        Label(option, systemImage: "checkmark")
                    } else {
                        Text(option)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(selection ?? "Select…")
                    .font(Theme.Typography.callout)
                    .foregroundStyle(selection == nil ? Theme.Colors.tertiaryText : Theme.Colors.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
            .creativeField()
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    private var selection: String? {
        node.params[param.key]?.stringValue ?? param.defaultValue?.stringValue
    }
}

// MARK: - Media well

/// URL field + drop target for image/video/audio/file inputs. Dropping a
/// local file spawns a media node wired into this param (uploads are lazy,
/// at run time). Pasting a URL sets the param directly.
struct CreativeMediaWell: View {
    let node: CreativeNode
    let param: CreativeParamSpec

    @State private var dropTargeted = false

    private var controller: CreativeCanvasController { .shared }

    private var value: String {
        node.params[param.key]?.stringValue ?? ""
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            if !value.isEmpty, value.hasPrefix("http") {
                CreativeThumbView(source: .remote(value), kind: mediaKind, maxPixel: 128)
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                Image(systemName: mediaKind.iconName)
                    .font(.system(size: 12, weight: .light))
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Theme.Colors.bgInput)
                    )
            }

            TextField("Paste URL or drop a file", text: Binding(
                get: { value },
                set: { newValue in
                    controller.setParam(
                        nodeId: node.id,
                        key: param.key,
                        value: newValue.isEmpty ? nil : .string(newValue)
                    )
                }
            ))
            .textFieldStyle(.plain)
            .font(Theme.Typography.monoCaption)
            .foregroundStyle(Theme.Colors.text)

            Button {
                pickFile()
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Colors.textDim)
            }
            .buttonStyle(.plain)
            .help("Choose a file")
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(Theme.Colors.bgInput.opacity(dropTargeted ? 1 : 0.7))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .strokeBorder(
                            dropTargeted ? Theme.Colors.accent : Theme.Colors.borderSubtle,
                            style: StrokeStyle(lineWidth: 1, dash: value.isEmpty ? [4, 3] : [])
                        )
                )
        )
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
    }

    private var mediaKind: CreativeMediaKind {
        switch param.kind {
        case .image: return .image
        case .video: return .video
        case .audio: return .audio
        default: return .file
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, url.isFileURL else { return }
            Task { @MainActor in
                await controller.attachMedia(fileURL: url, toNode: node.id, param: param.key)
            }
        }
        return true
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        switch mediaKind {
        case .image: panel.allowedContentTypes = [.image]
        case .video: panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        case .audio: panel.allowedContentTypes = [.audio]
        case .file: break
        }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                await controller.attachMedia(fileURL: url, toNode: node.id, param: param.key)
            }
        }
    }
}

// MARK: - JSON fallback editor (arrays / structured params like loras)

struct CreativeJSONEditor: View {
    let node: CreativeNode
    let param: CreativeParamSpec

    @State private var draft = ""
    @State private var isValid = true
    @State private var loadedFor: String?

    private var controller: CreativeCanvasController { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            TextEditor(text: $draft)
                .font(Theme.Typography.monoCaption)
                .foregroundStyle(Theme.Colors.text)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 40, maxHeight: 84)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .fill(Theme.Colors.bgInput)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                                .strokeBorder(
                                    isValid ? Theme.Colors.borderSubtle : Theme.Colors.red.opacity(0.6),
                                    lineWidth: 1
                                )
                        )
                )
                .onHover { hovering in
                    controller.scrollPassthroughDepth += hovering ? 1 : -1
                    if controller.scrollPassthroughDepth < 0 { controller.scrollPassthroughDepth = 0 }
                }
            if !isValid {
                Text("Invalid JSON")
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.red)
            }
        }
        .onAppear { syncDraft() }
        .onChange(of: draft) { _, newValue in
            commit(newValue)
        }
    }

    private func syncDraft() {
        guard loadedFor != node.id else { return }
        loadedFor = node.id
        if let value = node.params[param.key],
           let data = try? JSONEncoder().encode(value),
           let s = String(data: data, encoding: .utf8) {
            draft = s
        } else {
            draft = ""
        }
    }

    private func commit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            isValid = true
            controller.setParam(nodeId: node.id, key: param.key, value: nil)
            return
        }
        guard let data = trimmed.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        else {
            isValid = false
            return
        }
        isValid = true
        controller.setParam(nodeId: node.id, key: param.key, value: value)
    }
}
