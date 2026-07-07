import SwiftUI
import UniformTypeIdentifiers

/// Unified chat interface. Claude can answer questions AND take actions via tools —
/// create / update / complete / delete / search across all Otto item types.
///
/// Live conversations (turn logs, streaming entries, in-flight runs) are
/// OWNED by `appState.chatRuns` — one controller per conversation, several of
/// which can run concurrently — not by this view. A working query keeps
/// running and keeps persisting even if this view is torn down (chat sheet
/// closed, session switched). This view only holds input state plus a local
/// render cache for browsing saved (never-run) sessions.
struct OttoChatView: View {
    @Environment(AppState.self) private var appState

    @State private var inputText: String = ""
    @FocusState private var inputFocused: Bool
    @State private var composerHovered: Bool = false

    // Local render cache for SAVED sessions. Conversations with a run
    // controller render straight from `appState.chatRuns` and need no cache.
    @State private var loadedEntries: [ChatUIEntry] = []
    @State private var loadedSessionId: UUID? = nil

    // Attachments staged for the next user message.
    @State private var pendingAttachments: [ChatAttachment] = []
    @State private var showFileImporter: Bool = false
    @State private var attachmentError: String?

    /// Detail popup opened by clicking an item-preview card. Held here (not
    /// inside `ItemPreviewCard`) because a `.sheet` attached to a row of the
    /// message list's LazyVStack fails to present — every other popup in the
    /// app hangs its sheet on the list/container view for the same reason.
    @State private var previewDetail: PreviewDetail?

    /// Tool-call groups the user has expanded via "See tool calls", keyed by
    /// the group's leading entry id. Default (absent) = collapsed.
    @State private var expandedToolGroups: Set<UUID> = []

    /// Run controller for the session on screen, when it has (or recently
    /// had) a live run this app-run. nil = a saved session rendered from the
    /// local cache, or a fresh blank chat.
    private var viewedController: ChatRunController? {
        appState.chatRuns.controller(for: appState.activeChatSessionId)
    }

    /// A run is actively streaming into the session currently on screen.
    private var isRunLiveHere: Bool {
        viewedController?.isRunning ?? false
    }

    /// A run is streaming into some OTHER session right now.
    private var otherRunningSessionId: UUID? {
        appState.chatRuns.runningSessionIds.first { $0 != appState.activeChatSessionId }
    }

    private var displayedEntries: [ChatUIEntry] {
        viewedController?.entries ?? loadedEntries
    }

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
            if displayedEntries.isEmpty {
                emptyState
            } else {
                messageList
            }

            OttoDivider()

            if let controller = viewedController, let error = controller.error {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.amber)
                    Text(error)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.secondaryText)
                    Spacer()
                    Button {
                        controller.error = nil
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
        .sheet(item: $previewDetail) { detail in
            previewDetailSheet(detail)
        }
        .onAppear {
            loadActiveSession()
            consumePendingPromptIfNeeded()
        }
        .onChange(of: appState.activeChatSessionId) { _, _ in
            // Always safe to switch — live runs stream into their own
            // controllers in appState.chatRuns regardless of what's on screen.
            loadActiveSession()
        }
        .onChange(of: appState.pendingChatPrompt) { _, _ in
            consumePendingPromptIfNeeded()
        }
    }

    // MARK: - Session loading

    /// Refresh the local render cache for the session AppState says is
    /// active. Sessions with a run controller need no load — they render
    /// straight from `appState.chatRuns`. nil = a fresh blank chat.
    private func loadActiveSession() {
        let target = appState.activeChatSessionId
        if viewedController != nil {
            // Live content comes from the controller; drop the stale cache so
            // it doesn't linger when the user later switches to a saved chat.
            loadedSessionId = target
            loadedEntries = []
            return
        }
        if target == loadedSessionId, !loadedEntries.isEmpty || target == nil { return }
        loadedSessionId = target
        if let id = target, let session = appState.chatSession(id) {
            loadedEntries = ChatRunController.rebuildEntries(from: session.turns, appState: appState)
        } else {
            loadedEntries = []
        }
        inputText = ""
        pendingAttachments = []
    }

    // MARK: - Empty State

    /// True iff neither agent backend has any usable auth — neither CLI
    /// login nor a pasted API key. We don't block use — the user can still
    /// type — but show a banner pointing at Settings so first-runs aren't
    /// a dead-end.
    private var noBackendSignedIn: Bool {
        ClaudeAuthService.shared.effectiveAuthMode() == .none
            && CodexAuthService.shared.effectiveAuthMode() == .none
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Spacer()

            BrandMark(size: 28)

            VStack(spacing: Theme.Spacing.sm) {
                Text("Ask or create")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(Theme.Colors.text)

                Text("Claude or Codex can answer, create, edit, and search across your Otto.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Colors.textDim)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            if noBackendSignedIn {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.amber)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No agent backend signed in")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.amber)
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
                .background(Theme.Colors.tintAmber)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .strokeBorder(Theme.Colors.amber.opacity(0.4), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            }

            VStack(spacing: Theme.Spacing.sm) {
                ForEach(suggestions, id: \.self) { suggestion in
                    OttoChip(text: suggestion.label) {
                        inputText = suggestion.prompt
                        sendMessage()
                    }
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// One empty-state suggestion chip: a short pill label, and the (possibly
    /// longer, more instructive) prompt that's actually sent when clicked.
    private struct Suggestion: Hashable {
        let label: String
        let prompt: String

        init(_ label: String, prompt: String? = nil) {
            self.label = label
            self.prompt = prompt ?? label
        }
    }

    private var suggestions: [Suggestion] {
        var out: [Suggestion] = []

        let nextTodo = appState.todos
            .filter { !$0.isCompleted }
            .compactMap { todo -> (Todo, Date)? in todo.dueDate.map { (todo, $0) } }
            .sorted { $0.1 < $1.1 }
            .first?.0
        if let todo = nextTodo {
            out.append(Suggestion("What's the status of '\(Self.truncate(todo.title))'?"))
        } else if let urgent = appState.todos.first(where: { !$0.isCompleted && $0.priority == .urgent }) {
            out.append(Suggestion("Summarize my urgent todo '\(Self.truncate(urgent.title))'"))
        }

        if let lastMeeting = appState.meetings.sorted(by: { $0.meetingDate > $1.meetingDate }).first {
            out.append(Suggestion("Summarize my last meeting: \(Self.truncate(lastMeeting.title))"))
        }

        if let recentNote = appState.notes.sorted(by: { $0.updatedAt > $1.updatedAt }).first {
            out.append(Suggestion("What's in my note '\(Self.truncate(recentNote.title))'?"))
        }

        if !appState.networkEntries.isEmpty || !appState.companies.isEmpty {
            out.append(Suggestion(
                "Update network & companies from the last 7 days",
                prompt: "Review my meetings, emails, and notes from the last 7 days and update my Network Hub entries, companies, events, and communities with any new information you find — people I met, role or company changes, deal amounts, event plans. List what you changed."
            ))
        }

        out.append(Suggestion("What's on my plate today?"))
        out.append(Suggestion("What are my high priority todos?"))

        return Array(out.prefix(5))
    }

    private static func truncate(_ s: String, max: Int = 40) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= max { return trimmed }
        return String(trimmed.prefix(max - 1)) + "…"
    }

    // MARK: - Message List

    /// Show the small "between steps" indicator only when the backend is
    /// genuinely idle — i.e. there's no in-flight tool step that's already
    /// pulsing on its own AND no streaming text/thinking bubble actively
    /// growing. Two activity signals at once would just be noise.
    private var idleIndicatorVisible: Bool {
        guard isRunLiveHere else { return false }
        guard let lastKind = displayedEntries.last?.kind else { return true }
        if lastKind.isInFlightToolStep { return false }
        if lastKind.isStreaming { return false }
        return true
    }

    /// One renderable row of the transcript: either a standalone entry, or a
    /// run of consecutive tool-step chips folded into a collapsible group so
    /// the transcript isn't wallpapered with raw tool calls.
    private enum DisplayItem: Identifiable {
        case single(ChatUIEntry)
        case toolGroup([ChatUIEntry])

        var id: UUID {
            switch self {
            case .single(let entry):     return entry.id
            case .toolGroup(let group):  return group.first?.id ?? UUID()
            }
        }
    }

    /// Fold consecutive `.toolStep` entries into `.toolGroup` items. Text
    /// bubbles, preview cards, and approval prompts stay standalone and
    /// naturally split groups between tool rounds.
    private var displayItems: [DisplayItem] {
        var out: [DisplayItem] = []
        var group: [ChatUIEntry] = []
        func flush() {
            guard !group.isEmpty else { return }
            out.append(.toolGroup(group))
            group = []
        }
        for entry in displayedEntries {
            if entry.kind.isToolStep {
                group.append(entry)
            } else {
                flush()
                out.append(.single(entry))
            }
        }
        flush()
        return out
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Theme.Spacing.md) {
                    ForEach(displayItems) { item in
                        displayItemView(item).id(item.id)
                    }

                    if idleIndicatorVisible {
                        IdleStepIndicator()
                            .id("loading")
                    }
                }
                .padding(.vertical, Theme.Spacing.md)
            }
            .onChange(of: displayedEntries.count) { _, _ in
                if let last = displayItems.last?.id {
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
    private func displayItemView(_ item: DisplayItem) -> some View {
        switch item {
        case .single(let entry):
            entryView(entry)
        case .toolGroup(let group):
            ToolCallGroup(
                entries: group,
                isExpanded: Binding(
                    get: { expandedToolGroups.contains(item.id) },
                    set: { expanded in
                        if expanded {
                            expandedToolGroups.insert(item.id)
                        } else {
                            expandedToolGroups.remove(item.id)
                        }
                    }
                )
            )
        }
    }

    @ViewBuilder
    private func entryView(_ entry: ChatUIEntry) -> some View {
        switch entry.kind {
        case .userText(let text, let attachments):
            MessageBubble(text: text, isUser: true, attachments: attachments)
        case .assistantText(let text):
            MessageBubble(text: text, isUser: false, attachments: [], onOttoLink: { url in
                openOttoItem(url)
            })
        case .assistantTextStreaming(let text):
            // Same bubble layout as `.assistantText`, plus a trailing
            // caret that pulses while deltas are landing.
            StreamingAssistantBubble(text: text)
        case .thinkingStream(let text):
            ThinkingBubble(text: text)
        case .toolStep(let callIcon, let callLabel, let resultLabel, let isError, let isInFlight):
            ToolStepRow(
                callIcon: callIcon,
                callLabel: callLabel,
                resultLabel: resultLabel,
                isError: isError,
                isInFlight: isInFlight
            )
        case .itemPreview(let type, let itemId):
            ItemPreviewCard(type: type, itemId: itemId) { detail in
                previewDetail = detail
            }
        case .approvalRequest(let approvalId, let toolName, let argsSummary, let resolved):
            ApprovalPromptView(
                toolName: toolName,
                argsSummary: argsSummary,
                resolved: resolved
            ) { decision, isAllow in
                viewedController?.resolveApproval(
                    approvalId: approvalId,
                    toolName: toolName,
                    decision: decision,
                    isAllow: isAllow
                )
            }
        }
    }

    /// Open the detail popup for an inline `otto://<type>/<id>` chip clicked
    /// inside assistant text. Unknown/deleted items are a silent no-op.
    private func openOttoItem(_ url: URL) {
        guard let parsed = OttoTools.parseItemURL(url),
              let detail = PreviewDetail.resolve(type: parsed.type, itemId: parsed.id, appState: appState)
        else { return }
        previewDetail = detail
    }

    /// Detail/edit popup for a clicked preview card. Types the shared
    /// search-result popup can render go through it; the rest open their
    /// dedicated editor sheet.
    @ViewBuilder
    private func previewDetailSheet(_ detail: PreviewDetail) -> some View {
        switch detail {
        case .result(let result):
            SearchResultDetailPopup(result: result, onClose: {
                previewDetail = nil
            })
            .environment(appState)
        case .network(let entry):
            NetworkEntryEditor(entry: entry, onClose: { previewDetail = nil })
                .environment(appState)
        case .company(let company):
            CompanyEditorSheet(company: company)
                .environment(appState)
        case .event(let event):
            EventEditorSheet(event: event)
                .environment(appState)
        case .community(let community):
            CommunityEditorSheet(community: community)
                .environment(appState)
        case .habit(let habit):
            // HabitDetailView is a self-contained card built for the habits
            // tab's overlay; give it a concrete frame when hosted in a sheet.
            HabitDetailView(habit: habit, onClose: { previewDetail = nil })
                .frame(width: 680, height: 620)
                .environment(appState)
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        VStack(spacing: Theme.Spacing.sm) {
            if !pendingAttachments.isEmpty {
                attachmentStrip
            }

            // A run is streaming into a session that's NOT on screen — say
            // so and offer a jump. Sending here is still allowed: runs are
            // per-conversation now.
            if let backgroundId = otherRunningSessionId {
                backgroundRunHint(sessionId: backgroundId)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                TextField("Ask or create — todos, notes, ideas, reminders…", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.Colors.text)
                    .lineLimit(1...6)
                    .focused($inputFocused)
                    .onKeyPress(.return, phases: .down) { press in
                        // Shift+Return inserts a newline (let the vertical
                        // TextField handle it); plain Return submits.
                        if press.modifiers.contains(.shift) {
                            return .ignored
                        }
                        if canSend { sendMessage() }
                        return .handled
                    }
                    .padding(.horizontal, 2)

                HStack(spacing: 10) {
                    ComposerGhostButton(icon: "plus", help: "Attach files (csv, xlsx, pdf, png, jpeg…)") {
                        showFileImporter = true
                    }

                    ComposerGhostButton(icon: "mic", help: "Voice mode — talk to Otto") {
                        appState.showVoiceOverlay = true
                    }

                    if !displayedEntries.isEmpty {
                        ComposerGhostButton(icon: "square.and.pencil", help: "New conversation") {
                            newConversation()
                        }
                    }

                    Spacer(minLength: 0)

                    Button {
                        if isRunLiveHere {
                            viewedController?.stop(appState: appState)
                        } else {
                            sendMessage()
                        }
                    } label: {
                        Image(systemName: isRunLiveHere ? "stop.fill" : "arrow.up")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.Colors.onAccent)
                            .frame(width: 28, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Radius.md)
                                    .fill(
                                        isRunLiveHere || canSend
                                            ? Theme.Colors.accent
                                            : Theme.Colors.accent.opacity(0.35)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    // Enabled while the on-screen session is running (to act
                    // as Stop) or when there's something to send.
                    .disabled(!isRunLiveHere && !canSend)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help(isRunLiveHere ? "Stop" : "Send")
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.xl)
                    .fill(Theme.Colors.bgInput)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.xl)
                    .strokeBorder(
                        (composerHovered || inputFocused) ? Theme.Colors.accent : Theme.Colors.borderStrong,
                        lineWidth: 1
                    )
            )
            .animation(.easeInOut(duration: 0.15), value: composerHovered || inputFocused)
            .onHover { composerHovered = $0 }
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

    /// Runs are per-conversation, so sending is only blocked while THIS
    /// session is streaming — other sessions can work in parallel.
    private var canSend: Bool {
        guard !isRunLiveHere else { return false }
        if !pendingAttachments.isEmpty { return true }
        return !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Compact banner shown when a run is streaming into another session.
    private func backgroundRunHint(sessionId: UUID) -> some View {
        let count = appState.chatRuns.runningSessionIds.filter { $0 != appState.activeChatSessionId }.count
        let title = appState.chatSession(sessionId)?.title ?? "another chat"
        let label = count > 1
            ? "Otto is working in \(count) other chats"
            : "Otto is still working in “\(title)”"
        return HStack(spacing: Theme.Spacing.sm) {
            ProgressView()
                .controlSize(.small)
            Text(label)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.secondaryText)
                .lineLimit(1)
            Spacer()
            Button {
                appState.activeChatSessionId = sessionId
            } label: {
                Text("View")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .background(Theme.Colors.secondaryBackground.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
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
        guard !isRunLiveHere else { return }
        inputText = prompt
        sendMessage()
    }

    /// Hand the prompt to this conversation's run controller (created on
    /// first send) — it owns the turn log, streams events, and persists the
    /// session from the very first turn, so the query survives this view
    /// being torn down mid-run. Other conversations' runs are unaffected.
    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = pendingAttachments
        guard !text.isEmpty || !attachments.isEmpty else { return }
        let controller = appState.chatRuns.openController(
            for: appState.activeChatSessionId,
            appState: appState
        )
        guard !controller.isRunning else { return }

        inputText = ""
        pendingAttachments = []
        controller.send(text: text, attachments: attachments, appState: appState)
    }

    /// Navigation only — a run that's still streaming keeps going in its own
    /// session (reachable via the history sidebar) and stays persisted.
    private func newConversation() {
        appState.activeChatSessionId = nil
        loadedSessionId = nil
        loadedEntries = []
        inputText = ""
    }
}

// MARK: - Message Bubble

private struct MessageBubble: View {
    let text: String
    let isUser: Bool
    let attachments: [ChatAttachment]
    /// Click handler for inline `otto://` item chips in assistant text.
    var onOttoLink: ((URL) -> Void)? = nil

    @State private var isHovering = false
    @State private var justCopied = false

    var body: some View {
        HStack(alignment: .top, spacing: isUser ? 0 : Theme.Spacing.md) {
            if isUser {
                // Push the bubble right; the min length approximates the
                // mockup's ~78% max width for the user message.
                Spacer(minLength: 90)
            } else {
                BrandMark(size: 18)
                    .padding(.top, 2)
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: Theme.Spacing.xs) {
                if !attachments.isEmpty {
                    VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                        ForEach(attachments) { a in
                            AttachmentChip(attachment: a, onRemove: nil)
                        }
                    }
                }

                if !text.isEmpty {
                    // One NSTextView per bubble so the whole message is a single,
                    // natively-selectable text region (SwiftUI's .textSelection made
                    // every markdown block its own selection island and dropped
                    // drags inside the scroll view). User messages stay plain;
                    // assistant messages render Claude's markdown so ### and **
                    // don't show as literal characters.
                    if isUser {
                        SelectableMessageText(attributed: ChatMessageRenderer.plain(text))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Radius.xl)
                                    .fill(Theme.Colors.userBubble)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.Radius.xl)
                                    .strokeBorder(Theme.Colors.border, lineWidth: 1)
                            )
                    } else {
                        // Assistant messages have no bubble — just the mark and text.
                        SelectableMessageText(
                            attributed: ChatMessageRenderer.markdown(text),
                            onOttoLink: onOttoLink
                        )
                    }

                    copyButton
                }
            }
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)

            if !isUser { Spacer(minLength: 40) }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .onHover { isHovering = $0 }
    }

    // Icon-only copy control under the bubble; kept in the layout at zero
    // opacity when idle so revealing it on hover never shifts the transcript.
    private var copyButton: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            justCopied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { justCopied = false }
        } label: {
            Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(justCopied ? Theme.Colors.accent : Theme.Colors.tertiaryText)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy message")
        .opacity(isHovering || justCopied ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: isHovering)
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
                    .font(Theme.Typography.monoSmall)
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
                .fill(Theme.Colors.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .strokeBorder(Theme.Colors.border, lineWidth: 1)
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

// MARK: - Composer Ghost Button
//
// 26pt icon-only button for the composer's bottom row (mockup .cbtn):
// tertiary tint that brightens to full text color on hover, subtle
// hover tint background, no border.

private struct ComposerGhostButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hover ? Theme.Colors.text : Theme.Colors.tertiaryText)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .fill(hover ? Theme.Colors.hoverTint : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

// MARK: - Idle Step Indicator
//
// Three small dots that bounce in sequence. Shown only between Claude's
// events — once a tool step starts pulsing or text starts streaming, this
// disappears so we never have two activity signals at once.

private struct IdleStepIndicator: View {
    @State private var animating = false
    @State private var word: String = IdleStepIndicator.words.randomElement() ?? "thinking"

    /// Rotating status verbs shown while the agent works — picked at random
    /// so long waits feel alive instead of stuck on three dots.
    static let words: [String] = [
        "thinking", "tinkering", "calculating", "pondering", "scheming",
        "rummaging", "cross-referencing", "connecting dots", "digging",
        "sifting", "brewing", "noodling", "mulling", "crunching",
        "sleuthing", "wrangling", "assembling", "untangling",
        "triangulating", "deliberating", "cogitating", "ruminating",
        "synthesizing", "consulting the archives", "shuffling papers",
        "warming up neurons", "herding tokens", "polishing the answer",
        "double-checking", "plotting"
    ]

    private let cycle = Timer.publish(every: 1.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
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
            }
            Text("\(word)…")
                .font(Theme.Typography.caption.italic())
                .foregroundStyle(Theme.Colors.tertiaryText)
                .id(word)  // remount per word so the transition animates
                .transition(.opacity)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, 6)
        .onAppear { animating = true }
        .onReceive(cycle) { _ in
            var next = Self.words.randomElement() ?? word
            while next == word && Self.words.count > 1 {
                next = Self.words.randomElement() ?? word
            }
            withAnimation(.easeInOut(duration: 0.25)) { word = next }
        }
    }
}

// MARK: - Streaming Assistant Bubble
//
// Same shape as `MessageBubble` for the non-user side, but with a pulsing
// caret pinned to the trailing edge of the live text. Once the canonical
// `.text(...)` event arrives, this entry is replaced by a static
// `.assistantText`, so the caret disappears the moment streaming ends.

private struct StreamingAssistantBubble: View {
    let text: String
    @State private var caretOn = true

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            BrandMark(size: 18)
                .padding(.top, 2)
            (Text(text)
                + Text(caretOn ? "▍" : "  ")
                    .foregroundStyle(Theme.Colors.accent))
                .font(.system(size: 13.5))
                .lineSpacing(3)
                .foregroundStyle(Theme.Colors.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 40)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                caretOn.toggle()
            }
        }
    }
}

// MARK: - Thinking Bubble
//
// Dim, italic block that grows as `.thinkingDelta` events arrive. Visually
// distinct from the final answer so the user can tell at a glance that
// this is the model's reasoning, not its conclusion. Stays in the
// transcript after the turn ends (no auto-collapse for v1 — easier to
// trust the agent when its reasoning is visible).

private struct ThinkingBubble: View {
    let text: String
    @State private var pulse = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: "brain")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Colors.tertiaryText)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Thinking")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.Colors.textDim)
                    .opacity(pulse ? 0.45 : 1.0)
                    .animation(
                        .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                        value: pulse
                    )
                Text(text)
                    .font(.system(size: 12).italic())
                    .foregroundStyle(Theme.Colors.textDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.xs)
        .onAppear { pulse = true }
    }
}

// MARK: - Tool Call Group
//
// Consecutive tool-step chips fold into one collapsed disclosure row so the
// transcript reads as a conversation, not a tool log. Collapsed, the row
// shows "N tool calls" — or, while a call is running, its live label with a
// pulsing icon so activity stays visible. "See tool calls" expands the full
// ToolStepRow list.

private struct ToolCallGroup: View {
    let entries: [ChatUIEntry]
    @Binding var isExpanded: Bool

    @State private var pulse: Bool = false

    /// Label of the most recent still-running call, if any.
    private var inFlightLabel: String? {
        for entry in entries.reversed() {
            if case .toolStep(_, let call, _, _, true) = entry.kind { return call }
        }
        return nil
    }

    private var hasError: Bool {
        entries.contains { entry in
            if case .toolStep(_, _, _, true, _) = entry.kind { return true }
            return false
        }
    }

    private var headerLabel: String {
        if !isExpanded, let live = inFlightLabel { return live }
        let n = entries.count
        return n == 1 ? "1 tool call" : "\(n) tool calls"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Image(systemName: hasError ? "exclamationmark.triangle" : "wrench.and.screwdriver")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(hasError ? Theme.Colors.amber : Theme.Colors.tertiaryText)
                        .opacity(inFlightLabel != nil ? (pulse ? 0.35 : 1.0) : 1.0)
                        .animation(
                            inFlightLabel != nil
                                ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true)
                                : .default,
                            value: pulse
                        )
                    Text(headerLabel)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .lineLimit(1)
                    if !isExpanded && inFlightLabel == nil {
                        Text("See tool calls")
                            .font(Theme.Typography.monoSmall)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Hide tool calls" : "See tool calls")
            .padding(.horizontal, Theme.Spacing.lg)

            if isExpanded {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    ForEach(entries) { entry in
                        if case .toolStep(let icon, let call, let result, let isError, let inFlight) = entry.kind {
                            ToolStepRow(
                                callIcon: icon,
                                callLabel: call,
                                resultLabel: result,
                                isError: isError,
                                isInFlight: inFlight
                            )
                        }
                    }
                }
            }
        }
        .onAppear { pulse = inFlightLabel != nil }
        .onChange(of: inFlightLabel != nil) { _, running in
            pulse = running
        }
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

    /// Icon tint: green checkmark once done, amber on error, dim while
    /// the call is still in flight.
    private var iconTint: Color {
        if isError { return Theme.Colors.amber }
        return isInFlight ? Theme.Colors.textDim : Theme.Colors.green
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: callIcon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(iconTint)
                        .opacity(isInFlight ? (pulse ? 0.35 : 1.0) : 1.0)
                        .animation(
                            isInFlight
                                ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true)
                                : .default,
                            value: pulse
                        )
                    Text(callLabel)
                        .font(Theme.Typography.monoCaption)
                        .foregroundStyle(isError ? Theme.Colors.amber : Theme.Colors.textDim)
                }

                if let resultLabel, !resultLabel.isEmpty {
                    HStack(spacing: 0) {
                        // Indent so the arrow lines up roughly under the call text.
                        Text("→ ")
                            .font(Theme.Typography.monoSmall)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                        Text(resultLabel)
                            .font(Theme.Typography.monoSmall)
                            .foregroundStyle(isError ? Theme.Colors.amber : Theme.Colors.tertiaryText)
                            .lineLimit(2)
                    }
                    .padding(.leading, 17)  // align under callLabel (icon width + spacing)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .strokeBorder(
                        isError ? Theme.Colors.amber.opacity(0.4) : Theme.Colors.border,
                        lineWidth: 1
                    )
            )

            Spacer(minLength: 0)
        }
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
// Clicking reports a `PreviewDetail` up to `OttoChatView`, which presents the
// matching detail/edit popup from its own `.sheet` — the card can't own the
// sheet itself because sheets attached inside LazyVStack rows don't present.

/// What a preview-card click opens: the shared search-result popup for most
/// types, or a dedicated editor sheet for the ones it can't render.
private enum PreviewDetail: Identifiable {
    case result(UniversalSearchResult)
    case network(NetworkEntry)
    case company(Company)
    case event(Event)
    case community(Community)
    case habit(Habit)

    var id: UUID {
        switch self {
        case .result(let r):    return r.id
        case .network(let n):   return n.id
        case .company(let c):   return c.id
        case .event(let e):     return e.id
        case .community(let c): return c.id
        case .habit(let h):     return h.id
        }
    }

    /// Look up the referenced item in AppState and wrap it in the right
    /// presentation. nil when the item no longer exists. Shared by the
    /// standalone preview cards and inline `otto://` text chips.
    @MainActor
    static func resolve(type: ContentType, itemId: UUID, appState: AppState) -> PreviewDetail? {
        switch type {
        case .todo:       return appState.todos.first(where: { $0.id == itemId }).map { .result(.from($0)) }
        case .note:       return appState.notes.first(where: { $0.id == itemId }).map { .result(.from($0)) }
        case .idea:       return appState.ideas.first(where: { $0.id == itemId }).map { .result(.from($0)) }
        case .reminder:   return appState.reminders.first(where: { $0.id == itemId }).map { .result(.from($0)) }
        case .bookmark:   return appState.bookmarks.first(where: { $0.id == itemId }).map { .result(.from($0)) }
        case .meeting:    return appState.meetings.first(where: { $0.id == itemId }).map { .result(.from($0)) }
        case .email:      return appState.emails.first(where: { $0.id == itemId }).map { .result(.from($0)) }
        case .connection: return appState.connections.first(where: { $0.id == itemId }).map { .result(.from($0)) }
        case .file:       return appState.files.first(where: { $0.id == itemId }).map { .result(.from($0)) }
        case .xPost:      return appState.xPosts.first(where: { $0.id == itemId }).map { .result(.from($0)) }
        case .xFollower:  return appState.xFollowers.first(where: { $0.id == itemId }).map { .result(.from($0)) }
        case .xDm:        return appState.xDirectMessages.first(where: { $0.id == itemId }).map { .result(.from($0)) }
        case .networkHub: return appState.networkEntries.first(where: { $0.id == itemId }).map { .network($0) }
        case .company:    return appState.companies.first(where: { $0.id == itemId }).map { .company($0) }
        case .event:      return appState.events.first(where: { $0.id == itemId }).map { .event($0) }
        case .community:  return appState.communities.first(where: { $0.id == itemId }).map { .community($0) }
        case .habit:      return appState.habits.first(where: { $0.id == itemId }).map { .habit($0) }
        }
    }
}

private struct ItemPreviewCard: View {
    @Environment(AppState.self) private var appState
    let type: ContentType
    let itemId: UUID
    let onOpen: (PreviewDetail) -> Void

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
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.Colors.text)
                            .lineLimit(1)
                    } else {
                        Text("Item not found")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }
                    HStack(spacing: Theme.Spacing.xs) {
                        Text(type.displayName.lowercased())
                            .font(Theme.Typography.monoSmall)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                        if let snippet = lookupSnippet(), !snippet.isEmpty {
                            Text("·")
                                .font(Theme.Typography.monoSmall)
                                .foregroundStyle(Theme.Colors.tertiaryText)
                            Text(snippet)
                                .font(Theme.Typography.monoSmall)
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
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .fill(Theme.Colors.panel)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.md)
                            .strokeBorder(Theme.Colors.border, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Theme.Spacing.lg)
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
        case .networkHub: return appState.networkEntries.first(where: { $0.id == itemId }).map { $0.name.isEmpty ? $0.company : $0.name }
        case .company:    return appState.companies.first(where: { $0.id == itemId })?.name
        case .event:      return appState.events.first(where: { $0.id == itemId })?.name
        case .community:  return appState.communities.first(where: { $0.id == itemId })?.name
        case .file:       return appState.files.first(where: { $0.id == itemId })?.name
        case .habit:      return appState.habits.first(where: { $0.id == itemId })?.title
        case .xPost:      return appState.xPosts.first(where: { $0.id == itemId }).map { "@\($0.authorUsername)" }
        case .xFollower:  return appState.xFollowers.first(where: { $0.id == itemId })?.displayName
        case .xDm:        return appState.xDirectMessages.first(where: { $0.id == itemId }).map { $0.senderDisplayName.isEmpty ? "@\($0.senderUsername)" : $0.senderDisplayName }
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
            case .networkHub:
                return appState.networkEntries.first(where: { $0.id == itemId }).map { entry in
                    [entry.title, entry.company].filter { !$0.isEmpty }.joined(separator: " · ")
                }
            case .company:    return appState.companies.first(where: { $0.id == itemId })?.location
            case .event:      return appState.events.first(where: { $0.id == itemId })?.location
            case .community:  return appState.communities.first(where: { $0.id == itemId })?.location
            case .file:
                return appState.files.first(where: { $0.id == itemId }).map {
                    "\($0.fileType.displayName) • \($0.formattedSize)"
                }
            case .habit:      return appState.habits.first(where: { $0.id == itemId })?.notes
            case .xPost:      return appState.xPosts.first(where: { $0.id == itemId })?.text
            case .xFollower:  return appState.xFollowers.first(where: { $0.id == itemId }).map { "@\($0.username)" }
            case .xDm:        return appState.xDirectMessages.first(where: { $0.id == itemId })?.text
            case .reminder:   return nil
            }
        }()
        guard let raw else { return nil }
        let oneLine = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if oneLine.count <= 80 { return oneLine }
        return String(oneLine.prefix(80)) + "…"
    }

    /// Resolve the referenced item and hand the matching `PreviewDetail` up
    /// to the chat view, which presents the detail/edit popup as a sheet —
    /// stays on the Home tab for every type.
    private func openDetail() {
        if let detail = PreviewDetail.resolve(type: type, itemId: itemId, appState: appState) {
            onOpen(detail)
        }
    }
}
