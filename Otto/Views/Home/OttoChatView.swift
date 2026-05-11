import SwiftUI
import UniformTypeIdentifiers

/// Unified chat interface. Claude can answer questions AND take actions via tools —
/// create / update / complete / delete / search across all Otto item types.
struct OttoChatView: View {
    @Environment(AppState.self) private var appState

    @State private var turns: [ChatTurn] = []
    @State private var inputText: String = ""
    @State private var isLoading: Bool = false
    @State private var error: String?
    @FocusState private var inputFocused: Bool

    // UI-level event log — each entry is rendered as a bubble or a tool chip in order.
    @State private var uiEntries: [UIEntry] = []

    // Chat session this view is currently displaying. nil = a fresh
    // conversation that hasn't been written yet (created on first send).
    @State private var sessionId: UUID? = nil

    // Attachments staged for the next user message.
    @State private var pendingAttachments: [ChatAttachment] = []
    @State private var showFileImporter: Bool = false
    @State private var attachmentError: String?

    /// File types accepted by the chat's file picker. Covers the requested
    /// csv/xlsx/pdf/png/jpeg plus a few common text/data formats.
    private static let allowedAttachmentTypes: [UTType] = {
        var types: [UTType] = [
            .commaSeparatedText,          // csv
            .pdf,
            .png,
            .jpeg,
            .heic,
            .plainText,
            .json
        ]
        if let xlsx = UTType(filenameExtension: "xlsx") { types.append(xlsx) }
        if let xls = UTType(filenameExtension: "xls") { types.append(xls) }
        if let md = UTType(filenameExtension: "md") { types.append(md) }
        if let tsv = UTType(filenameExtension: "tsv") { types.append(tsv) }
        return types
    }()

    var body: some View {
        @Bindable var appState = appState
        return VStack(spacing: 0) {
            if uiEntries.isEmpty {
                emptyState
            } else {
                messageList
            }

            OttoDivider()

            if let error {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.amber)
                    Text(error)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.secondaryText)
                    Spacer()
                    Button {
                        self.error = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.sm)
                .background(Theme.Colors.amber.opacity(0.08))
            }

            inputBar
        }
        .overlay {
            if appState.showVoiceOverlay {
                VoiceOverlayView(isPresented: $appState.showVoiceOverlay)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: appState.showVoiceOverlay)
        .onAppear {
            loadActiveSession()
            consumePendingPromptIfNeeded()
        }
        .onChange(of: appState.activeChatSessionId) { _, _ in
            // Don't tear down a chat that is still streaming a tool-using
            // assistant turn — wait for it to finish, then load.
            guard !isLoading else { return }
            loadActiveSession()
        }
        .onChange(of: appState.pendingChatPrompt) { _, _ in
            consumePendingPromptIfNeeded()
        }
    }

    // MARK: - Session loading

    /// Sync local `turns` + `uiEntries` to the session AppState says is active.
    /// nil = a fresh blank chat.
    private func loadActiveSession() {
        let target = appState.activeChatSessionId
        if target == sessionId, !turns.isEmpty || target == nil { return }
        sessionId = target
        if let id = target, let session = appState.chatSession(id) {
            turns = session.turns
            uiEntries = Self.rebuildUIEntries(from: session.turns, appState: appState)
        } else {
            turns = []
            uiEntries = []
        }
        inputText = ""
        pendingAttachments = []
        error = nil
    }

    /// Reconstruct the UI event log from a saved session's turns. Tool-result
    /// blocks are merged into their preceding tool-use step with the same id
    /// so the UI shows the call line + result line, just like the live stream.
    @MainActor
    private static func rebuildUIEntries(from turns: [ChatTurn], appState: AppState) -> [UIEntry] {
        var out: [UIEntry] = []
        // Map tool_use id → index in `out` so we can rewrite the step in place
        // when its result comes through.
        var toolIndex: [String: Int] = [:]

        for turn in turns {
            switch turn.role {
            case "user":
                let text = turn.blocks.compactMap { block -> String? in
                    if case let .text(s) = block { return s } else { return nil }
                }.joined(separator: "\n")
                out.append(UIEntry(kind: .userText(text: text, attachments: turn.attachments)))
            case "assistant":
                for block in turn.blocks {
                    switch block {
                    case .text(let s):
                        let trimmed = s.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty {
                            out.append(UIEntry(kind: .assistantText(s)))
                        }
                    case .toolUse(let id, let name, let input):
                        if name == OttoTools.Name.attach_item_preview.rawValue,
                           let preview = previewFromInput(input) {
                            out.append(UIEntry(kind: .itemPreview(type: preview.type, itemId: preview.id)))
                        } else {
                            let label = OttoToolLabels.describe(name: name, input: input, appState: appState)
                            let callLabel: String
                            if let arg = label.arg, !arg.isEmpty {
                                callLabel = "\(label.verb) \(arg)"
                            } else {
                                callLabel = label.verb
                            }
                            let entry = UIEntry(
                                toolUseId: id,
                                kind: .toolStep(
                                    callIcon: "wrench.and.screwdriver",
                                    callLabel: callLabel,
                                    resultLabel: nil,
                                    isError: false,
                                    isInFlight: false  // saved sessions never animate
                                )
                            )
                            toolIndex[id] = out.count
                            out.append(entry)
                        }
                    case .toolResult(let toolUseId, let content, let isError):
                        if let idx = toolIndex[toolUseId],
                           idx < out.count,
                           case .toolStep(_, let callLabel, _, _, _) = out[idx].kind {
                            let icon = isError ? "exclamationmark.triangle" : "checkmark.circle"
                            let resultText = formatResultLine(content)
                            out[idx] = UIEntry(
                                toolUseId: toolUseId,
                                kind: .toolStep(
                                    callIcon: icon,
                                    callLabel: callLabel,
                                    resultLabel: resultText,
                                    isError: isError,
                                    isInFlight: false
                                )
                            )
                        }
                    }
                }
            default:
                break
            }
        }
        return out
    }

    private static func previewFromInput(_ input: JSONValue) -> (type: ContentType, id: UUID)? {
        guard case let .object(dict) = input,
              case let .string(typeStr) = dict["type"] ?? .null,
              let type = ContentType(rawValue: typeStr),
              case let .string(idStr) = dict["id"] ?? .null,
              let id = UUID(uuidString: idStr)
        else { return nil }
        return (type, id)
    }

    // MARK: - Empty State

    /// True iff neither of the supported agent backends has credentials on
    /// disk. We don't block use — the user can still type — but show a
    /// banner pointing at Settings so first-runs aren't a dead-end.
    private var noBackendSignedIn: Bool {
        !ClaudeAuthService.shared.isSignedIn() && !CodexAuthService.shared.isSignedIn()
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Spacer()

            Image(systemName: "brain")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(Theme.Colors.accent.opacity(0.6))

            VStack(spacing: Theme.Spacing.sm) {
                Text("Ask or create")
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.Colors.text)

                Text("Claude or Codex can answer, create, edit, and search across your Otto.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            if noBackendSignedIn {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No agent backend signed in")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.orange)
                        Text("Run `claude` (Claude Code) or `codex login` in Terminal, then pick a backend in Settings → Agent.")
                            .font(Theme.Typography.small)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.sm)
                .frame(maxWidth: 380)
                .background(Color.orange.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .stroke(Color.orange.opacity(0.4), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            }

            VStack(spacing: Theme.Spacing.sm) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        inputText = suggestion
                        sendMessage()
                    } label: {
                        Text(suggestion)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.secondaryText)
                            .padding(.horizontal, Theme.Spacing.md)
                            .padding(.vertical, Theme.Spacing.sm)
                            .background(Theme.Colors.secondaryBackground)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var suggestions: [String] {
        var out: [String] = []

        let nextTodo = appState.todos
            .filter { !$0.isCompleted }
            .compactMap { todo -> (Todo, Date)? in todo.dueDate.map { (todo, $0) } }
            .sorted { $0.1 < $1.1 }
            .first?.0
        if let todo = nextTodo {
            out.append("What's the status of '\(Self.truncate(todo.title))'?")
        } else if let urgent = appState.todos.first(where: { !$0.isCompleted && $0.priority == .urgent }) {
            out.append("Summarize my urgent todo '\(Self.truncate(urgent.title))'")
        }

        if let lastMeeting = appState.meetings.sorted(by: { $0.meetingDate > $1.meetingDate }).first {
            out.append("Summarize my last meeting: \(Self.truncate(lastMeeting.title))")
        }

        if let recentNote = appState.notes.sorted(by: { $0.updatedAt > $1.updatedAt }).first {
            out.append("What's in my note '\(Self.truncate(recentNote.title))'?")
        }

        out.append("What's on my plate today?")
        out.append("What are my high priority todos?")

        return Array(out.prefix(4))
    }

    private static func truncate(_ s: String, max: Int = 40) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= max { return trimmed }
        return String(trimmed.prefix(max - 1)) + "…"
    }

    // MARK: - Message List

    /// Show the small "between steps" indicator only when Claude is genuinely
    /// idle — i.e. there's no in-flight tool step that's already pulsing on
    /// its own. Two activity signals at once would just be noise.
    private var idleIndicatorVisible: Bool {
        guard isLoading else { return false }
        return !(uiEntries.last?.kind.isInFlightToolStep ?? false)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Theme.Spacing.md) {
                    ForEach(uiEntries) { entry in
                        entryView(entry).id(entry.id)
                    }

                    if idleIndicatorVisible {
                        IdleStepIndicator()
                            .id("loading")
                    }
                }
                .padding(.vertical, Theme.Spacing.md)
            }
            .onChange(of: uiEntries.count) { _, _ in
                if let last = uiEntries.last?.id {
                    withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            .onChange(of: idleIndicatorVisible) { _, visible in
                if visible {
                    withAnimation { proxy.scrollTo("loading", anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private func entryView(_ entry: UIEntry) -> some View {
        switch entry.kind {
        case .userText(let text, let attachments):
            MessageBubble(text: text, isUser: true, attachments: attachments)
        case .assistantText(let text):
            MessageBubble(text: text, isUser: false, attachments: [])
        case .toolStep(let callIcon, let callLabel, let resultLabel, let isError, let isInFlight):
            ToolStepRow(
                callIcon: callIcon,
                callLabel: callLabel,
                resultLabel: resultLabel,
                isError: isError,
                isInFlight: isInFlight
            )
        case .itemPreview(let type, let itemId):
            ItemPreviewCard(type: type, itemId: itemId)
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        VStack(spacing: Theme.Spacing.sm) {
            if !pendingAttachments.isEmpty {
                attachmentStrip
            }

            HStack(alignment: .bottom, spacing: Theme.Spacing.sm) {
                if !uiEntries.isEmpty {
                    Button {
                        newConversation()
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.Colors.tertiaryText)
                            .frame(width: 32, height: 32)
                            .background(Theme.Colors.secondaryBackground)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    }
                    .buttonStyle(.plain)
                    .help("New conversation")
                }

                HStack(alignment: .bottom, spacing: Theme.Spacing.sm) {
                    Button {
                        showFileImporter = true
                    } label: {
                        Image(systemName: "paperclip")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Theme.Colors.secondaryText)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help("Attach files (csv, xlsx, pdf, png, jpeg…)")

                    TextField("Ask or create — todos, notes, ideas, reminders…", text: $inputText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(Theme.Typography.body)
                        .lineLimit(1...6)
                        .focused($inputFocused)
                        .onSubmit {
                            if canSend { sendMessage() }
                        }

                    Button {
                        appState.showVoiceOverlay = true
                    } label: {
                        Image(systemName: "mic.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(Theme.Colors.aiAccent)
                    }
                    .buttonStyle(.plain)
                    .help("Voice mode — talk to Otto")

                    Button {
                        sendMessage()
                    } label: {
                        Image(systemName: isLoading ? "stop.circle.fill" : "arrow.up.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(canSend ? Theme.Colors.accent : Theme.Colors.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: .command)
                }
                .padding(.horizontal, Theme.Spacing.sm)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Theme.Colors.secondaryBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .strokeBorder(Theme.Colors.border.opacity(0.4), lineWidth: 0.5)
                        )
                )
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: Self.allowedAttachmentTypes,
            allowsMultipleSelection: true
        ) { result in
            handleFileImport(result)
        }
        .alert("Attachment error", isPresented: Binding(
            get: { attachmentError != nil },
            set: { if !$0 { attachmentError = nil } }
        )) {
            Button("OK", role: .cancel) { attachmentError = nil }
        } message: {
            Text(attachmentError ?? "")
        }
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(pendingAttachments) { attachment in
                    AttachmentChip(attachment: attachment) {
                        pendingAttachments.removeAll { $0.id == attachment.id }
                    }
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private var canSend: Bool {
        guard !isLoading else { return false }
        if !pendingAttachments.isEmpty { return true }
        return !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - File Import

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let err):
            attachmentError = err.localizedDescription
        case .success(let urls):
            // 20 MB per file safety cap — base64 bloats by ~33% and the API
            // plus our context window won't love anything bigger.
            let maxBytes = 20 * 1024 * 1024
            for url in urls {
                let didStart = url.startAccessingSecurityScopedResource()
                defer { if didStart { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    if data.count > maxBytes {
                        attachmentError = "\(url.lastPathComponent) is \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)) — 20 MB max per file."
                        continue
                    }
                    let mediaType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                        ?? "application/octet-stream"
                    pendingAttachments.append(
                        ChatAttachment(filename: url.lastPathComponent, mediaType: mediaType, data: data)
                    )
                } catch {
                    attachmentError = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Actions

    /// If the dock queued a prompt before the chat opened, drop it into the
    /// input field and send it immediately.
    private func consumePendingPromptIfNeeded() {
        guard let prompt = appState.pendingChatPrompt, !prompt.isEmpty else { return }
        appState.pendingChatPrompt = nil
        guard !isLoading else { return }
        inputText = prompt
        sendMessage()
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = pendingAttachments
        guard (!text.isEmpty || !attachments.isEmpty), !isLoading else { return }

        // If the user only attached files without typing, send a default prompt
        // so Claude has something to respond to.
        let baseText = text.isEmpty ? "(see attached files)" : text

        // Show the user's bubble immediately. The turn that Claude actually
        // sees may be augmented with a context note (intent routing) inside
        // the Task below — we reconcile that before calling Claude.
        turns.append(ChatTurn(role: "user", blocks: [.text(baseText)], attachments: attachments))
        uiEntries.append(UIEntry(kind: .userText(text: text, attachments: attachments)))

        inputText = ""
        pendingAttachments = []
        isLoading = true
        error = nil

        let state = appState
        let detectedIntent = IntentRouter.detect(userInput: text)
        let capturedTurns = turns

        Task {
            // Deterministic intent side-effect (may be async, e.g. screen capture).
            // Runs before Claude so the URL is open / screenshot is saved by the
            // time the model reads its context note.
            var turnsForClaude = capturedTurns
            if let intent = detectedIntent {
                await IntentRouter.apply(intent, appState: state)
                if var lastTurn = turnsForClaude.popLast() {
                    let annotated = baseText + "\n" + IntentRouter.contextNote(for: intent)
                    lastTurn = ChatTurn(
                        role: lastTurn.role,
                        blocks: [.text(annotated)],
                        attachments: lastTurn.attachments,
                        timestamp: lastTurn.timestamp
                    )
                    turnsForClaude.append(lastTurn)
                }
            }

            let executor = await MainActor.run { OttoToolExecutor(appState: state) }
            let systemPrompt = state.claude.buildSystemPrompt(from: state)

            do {
                let updated = try await state.claude.chatWithTools(
                    turns: turnsForClaude,
                    systemPrompt: systemPrompt,
                    tools: OttoTools.all,
                    executor: executor,
                    onEvent: { event in
                        handleEvent(event)
                    }
                )
                await MainActor.run {
                    self.turns = updated
                    self.isLoading = false
                }
                // Persist the rich session (turns + tool calls) and the
                // legacy flattened askHistory in parallel so old code paths
                // that read askHistory continue to work.
                await persistSession(turns: updated)
                let flattened = flattenForHistory(updated)
                await state.addToAskHistory(messages: flattened)
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    self.isLoading = false
                    Sounds.play(.error)
                }
            }
        }
    }

    @MainActor
    private func handleEvent(_ event: ChatEvent) {
        switch event {
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            uiEntries.append(UIEntry(kind: .assistantText(text)))
        case .toolCall(let id, let name, let input):
            // attach_item_preview renders as a card directly — no chip.
            if name == OttoTools.Name.attach_item_preview.rawValue,
               let preview = parseItemPreview(from: input) {
                uiEntries.append(UIEntry(kind: .itemPreview(type: preview.type, itemId: preview.id)))
                return
            }
            let label = OttoToolLabels.describe(name: name, input: input, appState: appState)
            uiEntries.append(UIEntry(
                toolUseId: id,
                kind: .toolStep(
                    callIcon: "wrench.and.screwdriver",
                    callLabel: composedCallLabel(label),
                    resultLabel: nil,
                    isError: false,
                    isInFlight: true
                )
            ))
        case .toolResult(let id, let name, let summary, let isError):
            // attach_item_preview already rendered a card on the toolCall event; the
            // result event is a no-op so we don't show a redundant checkmark chip.
            if name == OttoTools.Name.attach_item_preview.rawValue { return }

            // Settle the matching in-flight step in place: keep the call line,
            // swap the icon, fill in the result line, drop the pulse.
            let idx = uiEntries.lastIndex(where: { entry in
                guard let uid = entry.toolUseId, entry.kind.isInFlightToolStep else { return false }
                return uid == id
            }) ?? uiEntries.lastIndex(where: { $0.kind.isInFlightToolStep })

            let icon = isError ? "exclamationmark.triangle" : "checkmark.circle"
            let resultText = Self.formatResultLine(summary)

            if let idx,
               case .toolStep(_, let callLabel, _, _, _) = uiEntries[idx].kind {
                uiEntries[idx] = UIEntry(
                    toolUseId: uiEntries[idx].toolUseId,
                    kind: .toolStep(
                        callIcon: icon,
                        callLabel: callLabel,
                        resultLabel: resultText,
                        isError: isError,
                        isInFlight: false
                    )
                )
            } else {
                // Fallback: result arrived without a matching call (shouldn't
                // happen, but keep something visible rather than dropping it).
                uiEntries.append(UIEntry(
                    toolUseId: id,
                    kind: .toolStep(
                        callIcon: icon,
                        callLabel: prettyToolName(name),
                        resultLabel: resultText,
                        isError: isError,
                        isInFlight: false
                    )
                ))
            }
        }
    }

    private func composedCallLabel(_ label: OttoToolLabels.Label) -> String {
        if let arg = label.arg, !arg.isEmpty {
            return "\(label.verb) \(arg)"
        }
        return "\(label.verb)…"
    }

    private static func formatResultLine(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 100 { return trimmed }
        return String(trimmed.prefix(99)) + "…"
    }

    private func parseItemPreview(from input: [String: Any]) -> (type: ContentType, id: UUID)? {
        guard let typeStr = input["type"] as? String,
              let type = ContentType(rawValue: typeStr),
              let idStr = input["id"] as? String,
              let id = UUID(uuidString: idStr)
        else { return nil }
        return (type, id)
    }

    private func newConversation() {
        turns = []
        uiEntries = []
        inputText = ""
        error = nil
        sessionId = nil
        appState.activeChatSessionId = nil
    }

    /// Upsert the active chat session in AppState. Creates a session id on
    /// the first save so subsequent turns update in place.
    @MainActor
    private func persistSession(turns: [ChatTurn]) async {
        guard !turns.isEmpty else { return }
        let id = sessionId ?? UUID()
        let existing = appState.chatSession(id)
        let session = ChatSession(
            id: id,
            title: existing?.title,
            turns: turns,
            createdAt: existing?.createdAt ?? Date(),
            updatedAt: Date()
        )
        sessionId = id
        appState.activeChatSessionId = id
        await appState.upsertChatSession(session)
    }

    // MARK: - Helpers

    private func prettyToolName(_ raw: String) -> String {
        switch raw {
        case "create_todo": return "Creating todo"
        case "create_note": return "Creating note"
        case "create_idea": return "Creating idea"
        case "create_reminder": return "Creating reminder"
        case "create_bookmark": return "Saving bookmark"
        case "update_todo": return "Updating todo"
        case "update_note": return "Updating note"
        case "update_idea": return "Updating idea"
        case "complete_todo": return "Completing todo"
        case "uncomplete_todo": return "Reopening todo"
        case "complete_reminder": return "Completing reminder"
        case "delete_item": return "Deleting item"
        case "search_items": return "Searching"
        case "get_item": return "Fetching details"
        case "attach_item_preview": return "Attaching preview"
        case "open_url": return "Opening website"
        case "create_habit": return "Creating habit"
        case "log_habit_entry": return "Logging habit entry"
        case "complete_habit": return "Completing habit"
        case "list_habits": return "Listing habits"
        default: return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Convert a full tool-calling turn log into plain [ChatMessage] for askHistory persistence.
    private func flattenForHistory(_ turns: [ChatTurn]) -> [ChatMessage] {
        var out: [ChatMessage] = []
        for turn in turns {
            var pieces: [String] = []
            if !turn.attachments.isEmpty {
                let names = turn.attachments.map { "📎 \($0.filename)" }.joined(separator: ", ")
                pieces.append(names)
            }
            for block in turn.blocks {
                switch block {
                case .text(let s):
                    if !s.trimmingCharacters(in: .whitespaces).isEmpty { pieces.append(s) }
                case .toolUse(_, let name, let input):
                    let line = OttoToolLabels.oneLine(name: name, input: input, appState: appState)
                    pieces.append("[\(line.lowercased())]")
                case .toolResult:
                    break  // results already implied by the assistant text that follows
                }
            }
            let combined = pieces.joined(separator: "\n\n")
            if !combined.isEmpty {
                out.append(ChatMessage(role: turn.role, content: combined, timestamp: turn.timestamp))
            }
        }
        return out
    }
}

// MARK: - UI Entry Model

private struct UIEntry: Identifiable {
    let id = UUID()
    /// Anthropic tool_use id, when this entry represents a tool step.
    /// Used to match a `.toolResult` back to its originating call.
    var toolUseId: String?
    var kind: Kind

    enum Kind {
        case userText(text: String, attachments: [ChatAttachment])
        case assistantText(String)
        /// A single Claude tool step: the call line ("Searching for 'recipe'")
        /// and an optional result line ("→ Found 3 results"). While the call
        /// is in flight the icon pulses and `resultLabel` is nil.
        case toolStep(callIcon: String, callLabel: String, resultLabel: String?, isError: Bool, isInFlight: Bool)
        case itemPreview(type: ContentType, itemId: UUID)

        var isUser: Bool { if case .userText = self { return true }; return false }
        var isToolStep: Bool { if case .toolStep = self { return true }; return false }
        var isInFlightToolStep: Bool {
            if case .toolStep(_, _, _, _, let inFlight) = self { return inFlight }
            return false
        }
    }
}

// MARK: - Message Bubble

private struct MessageBubble: View {
    let text: String
    let isUser: Bool
    let attachments: [ChatAttachment]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if isUser { Spacer(minLength: 60) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: Theme.Spacing.xs) {
                if !attachments.isEmpty {
                    VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                        ForEach(attachments) { a in
                            AttachmentChip(attachment: a, onRemove: nil)
                        }
                    }
                }

                if !text.isEmpty {
                    // User messages stay plain; assistant messages render Claude's markdown
                    // (headers, bold, lists, etc.) via MarkdownContent so ### and ** don't
                    // show as literal characters.
                    Group {
                        if isUser {
                            Text(text)
                                .font(Theme.Typography.body)
                                .textSelection(.enabled)
                        } else {
                            MarkdownContent(text)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.sm)
                    .background(isUser ? Theme.Colors.accent.opacity(0.12) : Theme.Colors.secondaryBackground)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                }
            }
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)

            if !isUser { Spacer(minLength: 60) }
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }
}

// MARK: - Attachment Chip
//
// Shown in the staging strip above the input field and inside user message
// bubbles. In the staging strip `onRemove` is wired; in message bubbles it's
// nil so the chip becomes read-only.

private struct AttachmentChip: View {
    let attachment: ChatAttachment
    let onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: iconName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.Colors.accent)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 0) {
                Text(attachment.filename)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.text)
                    .lineLimit(1)
                Text(attachment.formattedSize)
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .padding(4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(Theme.Colors.secondaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .strokeBorder(Theme.Colors.border.opacity(0.4), lineWidth: 0.5)
                )
        )
    }

    private var iconName: String {
        switch attachment.kind {
        case .image:  return "photo"
        case .pdf:    return "doc.richtext"
        case .text:
            let ext = (attachment.filename as NSString).pathExtension.lowercased()
            return ext == "csv" || ext == "tsv" ? "tablecells" : "doc.text"
        case .binary:
            let ext = (attachment.filename as NSString).pathExtension.lowercased()
            return (ext == "xlsx" || ext == "xls") ? "tablecells.fill" : "doc"
        }
    }
}

// MARK: - Idle Step Indicator
//
// Three small dots that bounce in sequence. Shown only between Claude's
// events — once a tool step starts pulsing or text starts streaming, this
// disappears so we never have two activity signals at once.

private struct IdleStepIndicator: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Theme.Colors.accent.opacity(0.8))
                    .frame(width: 5, height: 5)
                    .opacity(animating ? 1.0 : 0.25)
                    .animation(
                        .easeInOut(duration: 0.55)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.18),
                        value: animating
                    )
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, 6)
        .onAppear { animating = true }
    }
}

// MARK: - Tool Step Row
//
// Two-line "what Claude is doing" indicator:
//   • call line  — Searching for "recipe"
//   • result line — → Found 3 results   (only after the tool returns)
//
// While the call is in flight, the leading icon pulses to signal activity;
// once the result lands we swap to a checkmark (or amber triangle on error)
// and reveal the second line.

private struct ToolStepRow: View {
    let callIcon: String
    let callLabel: String
    let resultLabel: String?
    let isError: Bool
    let isInFlight: Bool

    @State private var pulse: Bool = false

    private var tint: Color {
        isError ? Theme.Colors.amber : Theme.Colors.accent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: callIcon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isError ? Theme.Colors.amber : tint.opacity(0.85))
                    .opacity(isInFlight ? (pulse ? 0.35 : 1.0) : 1.0)
                    .animation(
                        isInFlight
                            ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true)
                            : .default,
                        value: pulse
                    )
                Text(callLabel)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(isError ? Theme.Colors.amber : Theme.Colors.text)
                Spacer(minLength: 0)
            }

            if let resultLabel, !resultLabel.isEmpty {
                HStack(spacing: 0) {
                    // Indent so the arrow lines up roughly under the call text.
                    Text("→ ")
                        .font(Theme.Typography.small)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                    Text(resultLabel)
                        .font(Theme.Typography.small)
                        .foregroundStyle(isError ? Theme.Colors.amber : Theme.Colors.secondaryText)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 19)  // align under callLabel (icon width + spacing)
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(tint.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .strokeBorder((isError ? Theme.Colors.amber : Theme.Colors.border).opacity(0.3), lineWidth: 0.5)
                )
        )
        .padding(.horizontal, Theme.Spacing.lg)
        .onAppear {
            if isInFlight { pulse = true }
        }
        .onChange(of: isInFlight) { _, nowInFlight in
            pulse = nowInFlight
        }
    }
}

// MARK: - Item Preview Card
//
// Clickable card embedded in the chat scroll when Claude calls `attach_item_preview`.
// Tapping routes the user to the item's category tab and triggers the existing
// `locateItemId` flow which selects + scrolls to the row in its list view.

private struct ItemPreviewCard: View {
    @Environment(AppState.self) private var appState
    let type: ContentType
    let itemId: UUID
    @State private var presentedResult: UniversalSearchResult?

    var body: some View {
        Button(action: openDetail) {
            HStack(spacing: Theme.Spacing.md) {
                // Colored icon badge.
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .fill(type.color.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: type.iconName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(type.color)
                }

                VStack(alignment: .leading, spacing: 2) {
                    if let title = lookupTitle() {
                        Text(title)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Colors.text)
                            .lineLimit(1)
                    } else {
                        Text("Item not found")
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }
                    HStack(spacing: Theme.Spacing.xs) {
                        Text(type.displayName)
                            .font(Theme.Typography.small)
                            .foregroundStyle(type.color)
                        if let snippet = lookupSnippet(), !snippet.isEmpty {
                            Text("·")
                                .font(Theme.Typography.small)
                                .foregroundStyle(Theme.Colors.tertiaryText)
                            Text(snippet)
                                .font(Theme.Typography.small)
                                .foregroundStyle(Theme.Colors.tertiaryText)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
            .padding(Theme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.lg)
                    .fill(Theme.Colors.secondaryBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.lg)
                            .strokeBorder(type.color.opacity(0.25), lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Theme.Spacing.lg)
        .sheet(item: $presentedResult) { result in
            SearchResultDetailPopup(result: result, onClose: {
                presentedResult = nil
            })
            .environment(appState)
        }
    }

    private func lookupTitle() -> String? {
        switch type {
        case .todo:       return appState.todos.first(where: { $0.id == itemId })?.title
        case .note:       return appState.notes.first(where: { $0.id == itemId })?.title
        case .idea:       return appState.ideas.first(where: { $0.id == itemId })?.title
        case .reminder:   return appState.reminders.first(where: { $0.id == itemId })?.title
        case .bookmark:   return appState.bookmarks.first(where: { $0.id == itemId })?.title
        case .meeting:    return appState.meetings.first(where: { $0.id == itemId })?.title
        case .email:      return appState.emails.first(where: { $0.id == itemId })?.subject
        case .connection: return appState.connections.first(where: { $0.id == itemId })?.fullName
        case .habit:      return appState.habits.first(where: { $0.id == itemId })?.title
        case .file, .xPost, .xFollower, .xDm: return nil
        }
    }

    private func lookupSnippet() -> String? {
        let raw: String? = {
            switch type {
            case .todo:       return appState.todos.first(where: { $0.id == itemId })?.description
            case .note:       return appState.notes.first(where: { $0.id == itemId })?.content
            case .idea:       return appState.ideas.first(where: { $0.id == itemId })?.content
            case .bookmark:   return appState.bookmarks.first(where: { $0.id == itemId })?.url
            case .meeting:    return appState.meetings.first(where: { $0.id == itemId })?.overview
            case .email:      return appState.emails.first(where: { $0.id == itemId })?.snippet
            case .connection: return appState.connections.first(where: { $0.id == itemId })?.headline
            case .habit:      return appState.habits.first(where: { $0.id == itemId })?.notes
            case .reminder, .file, .xPost, .xFollower, .xDm: return nil
            }
        }()
        guard let raw else { return nil }
        let oneLine = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if oneLine.count <= 80 { return oneLine }
        return String(oneLine.prefix(80)) + "…"
    }

    /// Build a UniversalSearchResult for the referenced item and present the shared
    /// detail/edit popup as a sheet — stays on the Home tab.
    private func openDetail() {
        switch type {
        case .todo:
            if let t = appState.todos.first(where: { $0.id == itemId }) {
                presentedResult = .from(t)
            }
        case .note:
            if let n = appState.notes.first(where: { $0.id == itemId }) {
                presentedResult = .from(n)
            }
        case .idea:
            if let i = appState.ideas.first(where: { $0.id == itemId }) {
                presentedResult = .from(i)
            }
        case .reminder:
            if let r = appState.reminders.first(where: { $0.id == itemId }) {
                presentedResult = .from(r)
            }
        case .bookmark:
            if let b = appState.bookmarks.first(where: { $0.id == itemId }) {
                presentedResult = .from(b)
            }
        case .meeting:
            if let m = appState.meetings.first(where: { $0.id == itemId }) {
                presentedResult = .from(m)
            }
        case .email:
            if let e = appState.emails.first(where: { $0.id == itemId }) {
                presentedResult = .from(e)
            }
        case .connection:
            if let c = appState.connections.first(where: { $0.id == itemId }) {
                presentedResult = .from(c)
            }
        case .habit:
            // Habit chips currently jump straight to the Habits tab rather
            // than opening the shared search-result popup.
            appState.selectedTab = .habit
        case .file, .xPost, .xFollower, .xDm:
            break  // not referenceable from chat; schema doesn't include these types
        }
    }
}
