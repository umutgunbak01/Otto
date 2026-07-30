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

    // @-mention tagging state. Typing "@" in the composer opens an
    // autocomplete over taggable items; accepted picks live in
    // `pendingTags` until send, when their `@Title` tokens are expanded to
    // `[Title](otto://<type>/<id>)` links (the same syntax the agent uses).
    @State private var mentionActive: Bool = false
    @State private var mentionResults: [MentionItem] = []
    @State private var mentionSelection: Int = 0
    /// UTF-16 location of an "@" the user Escape-dismissed — the panel stays
    /// hidden for that token until the "@" is edited away.
    @State private var mentionEscapedAt: Int? = nil
    /// Items tagged via the picker, awaiting token expansion at send time.
    @State private var pendingTags: [MentionItem] = []

    /// Detail popup opened by clicking an item-preview card. Held here (not
    /// inside `ItemPreviewCard`) because a `.sheet` attached to a row of the
    /// message list's LazyVStack fails to present — every other popup in the
    /// app hangs its sheet on the list/container view for the same reason.
    @State private var previewDetail: PreviewDetail?

    /// Full-size preview for a clicked attachment chip (staged in the
    /// composer or inside a sent message). Same hoisting rationale as
    /// `previewDetail`.
    @State private var previewAttachment: ChatAttachment?

    /// Tool-call groups the user has expanded via "See tool calls", keyed by
    /// the group's leading entry id. Default (absent) = collapsed.
    @State private var expandedToolGroups: Set<UUID> = []

    /// Saved-prompts picker popover (bookmark button in the composer row).
    @State private var showSavedPromptsPopover = false

    /// Non-nil opens the saved-prompt editor pre-filled with the composer's
    /// current text ("Save current input as prompt…").
    @State private var promptEditorDraft: PromptDraft?
    private struct PromptDraft: Identifiable {
        let id = UUID()
        let text: String
    }

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
        // Extensions without first-class UTType constants. Markdown gets both
        // spellings — depending on installed apps, .md can resolve to a
        // declared type (net.daringfireball.markdown) or a dynamic one, and
        // listing the exact per-extension type keeps the picker permissive
        // either way.
        for ext in ["xlsx", "xls", "md", "markdown", "tsv", "yaml", "yml", "log"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types
    }()

    var body: some View {
        VStack(spacing: 0) {
            if displayedEntries.isEmpty {
                emptyState
            } else {
                messageList
            }

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
        // NOTE: the voice panel is hosted by MainView's ZStack (it floats over
        // the whole window while this chat streams the mirrored conversation).
        // Mounting a second VoiceOverlayView here would run the voice session's
        // start()/stop() lifecycle twice.
        .sheet(item: $previewDetail) { detail in
            previewDetailSheet(detail)
        }
        .sheet(item: $previewAttachment) { attachment in
            AttachmentPreviewPopup(attachment: attachment, onClose: { previewAttachment = nil })
                .frame(width: 760, height: 560)
        }
        .sheet(item: $promptEditorDraft) { draft in
            SavedPromptEditorSheet(existing: nil, draftPrompt: draft.text)
        }
        .onAppear {
            loadActiveSession()
            consumePendingPromptIfNeeded()
            consumeComposerInsertIfNeeded()
        }
        .onChange(of: appState.activeChatSessionId) { _, _ in
            // Always safe to switch — live runs stream into their own
            // controllers in appState.chatRuns regardless of what's on screen.
            loadActiveSession()
        }
        .onChange(of: appState.pendingChatPrompt) { _, _ in
            consumePendingPromptIfNeeded()
        }
        .onChange(of: appState.pendingComposerInsert) { _, _ in
            consumeComposerInsertIfNeeded()
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
        pendingTags = []
        mentionActive = false
        mentionResults = []
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
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                OttoOrb(size: 72)
                    .padding(.bottom, 28)

                // Eyebrow greeting (mockup .eyebrow).
                HStack(spacing: 10) {
                    Text("✦")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Colors.cyan.opacity(0.75))
                    Text(Self.greeting.uppercased())
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .tracking(2.6)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
                .padding(.bottom, 16)

                // Serif display headline (mockup h1.big — "Ask *or create*").
                (Text("Ask ")
                    + Text("or create").italic().foregroundStyle(Color(red: 0.812, green: 0.933, blue: 0.898))
                )
                .font(Theme.Typography.displayXL)
                .foregroundStyle(Theme.Colors.text)

                Text("\(backendDisplayName) can answer, create, edit, and search across your Otto.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.Colors.textDim)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 420)
                    .padding(.top, 15)

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
                    .padding(.top, 20)
                }

                OttoFlowLayout(spacing: 8, alignment: .center) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        OttoSuggestionChip(systemImage: suggestion.icon, label: suggestion.label) {
                            inputText = suggestion.prompt
                            sendMessage()
                        }
                    }
                }
                .frame(maxWidth: 660)
                .padding(.top, 32)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.Spacing.xxl)
            .padding(.top, 60)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Time-of-day greeting for the hero eyebrow.
    private static var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let name: String = {
            #if os(macOS)
            if let first = NSFullUserName().split(separator: " ").first, !first.isEmpty {
                return String(first)
            }
            #endif
            return "there"
        }()
        switch hour {
        case 5..<12:  return "Good morning, \(name)"
        case 12..<18: return "Good afternoon, \(name)"
        default:      return "Good evening, \(name)"
        }
    }

    /// Subtitle name for the active backend.
    private var backendDisplayName: String {
        switch AgentBackend.current {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        case .hermes: return "Hermes"
        }
    }

    /// One empty-state suggestion chip: a short pill label, an SF Symbol,
    /// and the (possibly longer, more instructive) prompt that's actually
    /// sent when clicked.
    private struct Suggestion: Hashable {
        let label: String
        let prompt: String
        let icon: String

        init(_ label: String, prompt: String? = nil, icon: String = "sparkles") {
            self.label = label
            self.prompt = prompt ?? label
            self.icon = icon
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
            out.append(Suggestion("What's the status of '\(Self.truncate(todo.title))'?", icon: "checkmark.square"))
        } else if let urgent = appState.todos.first(where: { !$0.isCompleted && $0.priority == .urgent }) {
            out.append(Suggestion("Summarize my urgent todo '\(Self.truncate(urgent.title))'", icon: "flag"))
        }

        if let lastMeeting = appState.meetings.sorted(by: { $0.meetingDate > $1.meetingDate }).first {
            out.append(Suggestion("Summarize my last meeting: \(Self.truncate(lastMeeting.title))", icon: "person.2"))
        }

        if let recentNote = appState.activeNotes.sorted(by: { $0.updatedAt > $1.updatedAt }).first {
            out.append(Suggestion("What's in my note '\(Self.truncate(recentNote.title))'?", icon: "doc.text"))
        }

        if !appState.networkEntries.isEmpty || !appState.companies.isEmpty {
            out.append(Suggestion(
                "Update network & companies from the last 7 days",
                prompt: "Review my meetings, emails, and notes from the last 7 days and update my Network Hub entries, companies, events, and communities with any new information you find — people I met, role or company changes, deal amounts, event plans. List what you changed.",
                icon: "arrow.clockwise"
            ))
        }

        out.append(Suggestion("What's on my plate today?", icon: "sun.max"))
        out.append(Suggestion("What are my high priority todos?", icon: "flag"))

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
                .padding(.vertical, Theme.Spacing.lg)
                .frame(maxWidth: 780)
                .frame(maxWidth: .infinity)
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
            MessageBubble(text: text, isUser: true, attachments: attachments, onOttoLink: { url in
                openOttoItem(url)
            }, onPreviewAttachment: { attachment in
                previewAttachment = attachment
            })
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
            // Media files (genmedia outputs, attached images/video/audio)
            // render their actual content inline — thumbnail or player —
            // instead of the generic click-through card.
            if type == .file,
               let file = appState.files.first(where: { $0.id == itemId }),
               ChatMediaCard.supports(file.fileType) {
                ChatMediaCard(file: file) {
                    previewDetail = .filePreview(file)
                }
            } else {
                ItemPreviewCard(type: type, itemId: itemId) { detail in
                    previewDetail = detail
                }
            }
        case .visualization(let spec):
            VisualizationCard(spec: spec, onOpenItem: openOttoItem)
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
        case .turnStats(let stats, let toolCalls):
            turnStatsRow(stats, toolCalls: toolCalls)
        case .notice(let text):
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 10, weight: .semibold))
                Text(text)
                    .font(Theme.Typography.caption)
            }
            .foregroundStyle(Theme.Colors.textDim)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, Theme.Spacing.sm)
        }
    }

    /// Subtle telemetry caption under an assistant turn: duration, tool
    /// count, and tokens/cost where the backend reports them.
    private func turnStatsRow(_ stats: TurnStats, toolCalls: Int) -> some View {
        var parts: [String] = [stats.caption]
        if toolCalls > 0 {
            parts.insert("\(toolCalls) tool\(toolCalls == 1 ? "" : "s")", at: 1)
        }
        return Text(parts.joined(separator: " · ").uppercased())
            .font(.system(size: 8.5, weight: .regular, design: .monospaced))
            .tracking(1.0)
            .foregroundStyle(Theme.Colors.tertiaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, Theme.Spacing.sm)
            .padding(.top, -4)
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
            }, onLocate: {
                previewDetail = nil
                appState.locate(type: result.contentType, id: result.id)
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
        case .filePreview(let file):
            // Same full-size preview the Files tab opens — image lightbox,
            // video/audio players, PDF, tables. Needs a concrete frame when
            // hosted in a sheet.
            FilePreviewPopup(file: file, onClose: { previewDetail = nil })
                .frame(width: 760, height: 560)
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
                    // Pin the field to the composer's width and re-measure
                    // height from it — without these, AppKit keeps wrapping
                    // against the width the field had at first layout, so
                    // after the chat column narrows (history sidebar opens)
                    // typed text runs past the border instead of wrapping.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .focused($inputFocused)
                    .onKeyPress(.return, phases: .down) { press in
                        // Shift+Return inserts a newline; plain Return submits.
                        // The line break has to be typed into the field editor
                        // by hand — an .ignored Shift+Return falls through to
                        // NSTextField, which commits and select-alls the text.
                        if press.modifiers.contains(.shift) {
                            if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                                editor.insertText("\n", replacementRange: editor.selectedRange())
                                return .handled
                            }
                            return .ignored
                        }
                        // While the @-mention panel is open, Return tags the
                        // highlighted item instead of sending.
                        if mentionPanelVisible {
                            if mentionResults.indices.contains(mentionSelection) {
                                acceptMention(mentionResults[mentionSelection])
                            }
                            return .handled
                        }
                        if canSend { sendMessage() }
                        return .handled
                    }
                    .onKeyPress(.upArrow, phases: .down) { _ in
                        guard mentionPanelVisible else { return .ignored }
                        mentionSelection = (mentionSelection - 1 + mentionResults.count) % mentionResults.count
                        return .handled
                    }
                    .onKeyPress(.downArrow, phases: .down) { _ in
                        guard mentionPanelVisible else { return .ignored }
                        mentionSelection = (mentionSelection + 1) % mentionResults.count
                        return .handled
                    }
                    .onKeyPress(.tab, phases: .down) { _ in
                        guard mentionPanelVisible else { return .ignored }
                        if mentionResults.indices.contains(mentionSelection) {
                            acceptMention(mentionResults[mentionSelection])
                        }
                        return .handled
                    }
                    .onKeyPress(.escape, phases: .down) { _ in
                        guard mentionPanelVisible else { return .ignored }
                        if let token = activeMentionToken() {
                            mentionEscapedAt = NSRange(token.atRange, in: inputText).location
                        }
                        mentionActive = false
                        mentionResults = []
                        return .handled
                    }
                    .onChange(of: inputText) { _, _ in
                        refreshMentionState()
                    }
                    .onChange(of: inputFocused) { _, focused in
                        if !focused {
                            mentionActive = false
                            mentionResults = []
                        }
                    }
                    .padding(.horizontal, 2)

                HStack(spacing: 10) {
                    ComposerGhostButton(icon: "plus", help: "Attach files (md, csv, xlsx, pdf, png, jpeg…)") {
                        showFileImporter = true
                    }

                    ComposerGhostButton(icon: "mic", help: "Voice mode — talk to Otto") {
                        appState.showVoiceOverlay = true
                    }

                    ComposerGhostButton(icon: "at", help: "Tag an item — reference a person, meeting, note…") {
                        insertMentionTrigger()
                    }

                    ComposerGhostButton(icon: "bookmark", help: "Saved prompts — insert one, or save what you've typed") {
                        showSavedPromptsPopover = true
                    }
                    .popover(isPresented: $showSavedPromptsPopover, arrowEdge: .top) {
                        SavedPromptPicker(
                            hasCurrentInput: !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                            onInsert: { prompt in
                                showSavedPromptsPopover = false
                                insertSavedPrompt(prompt)
                            },
                            onSaveCurrent: {
                                showSavedPromptsPopover = false
                                promptEditorDraft = PromptDraft(text: inputText)
                            },
                            onManage: {
                                showSavedPromptsPopover = false
                                appState.selectedTab = .automation
                            }
                        )
                    }

                    if !displayedEntries.isEmpty {
                        ComposerGhostButton(icon: "square.and.pencil", help: "New conversation") {
                            newConversation()
                        }
                    }

                    Spacer(minLength: 0)

                    OttoModelChip()
                        .padding(.trailing, 4)

                    Button {
                        if isRunLiveHere {
                            viewedController?.stop(appState: appState)
                        } else {
                            sendMessage()
                        }
                    } label: {
                        Image(systemName: isRunLiveHere ? "stop.fill" : "arrow.up")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Theme.Colors.onAccent)
                            .frame(width: 30, height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: 9)
                                    .fill(
                                        LinearGradient(
                                            colors: [Theme.Colors.accentGradTop, Theme.Colors.accentGradBottom],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                                    .opacity(isRunLiveHere || canSend ? 1 : 0.35)
                            )
                            .shadow(
                                color: Theme.Colors.accentGradBottom.opacity(isRunLiveHere || canSend ? 0.26 : 0),
                                radius: 8, y: 3
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
            .padding(.top, 13)
            .padding(.bottom, 11)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.045), Color.white.opacity(0.018)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        (composerHovered || inputFocused) ? Color.white.opacity(0.14) : Theme.Colors.border,
                        lineWidth: 1
                    )
            )
            .overlay(alignment: .top) {
                // Teal edge highlight along the top border (mockup
                // .composer::before) — brightens on focus.
                LinearGradient(
                    colors: [.clear, Theme.Colors.cyan.opacity(0.45), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 1)
                .padding(.horizontal, 56)
                .opacity(inputFocused ? 1 : 0.35)
            }
            .shadow(color: Color.black.opacity(0.4), radius: 26, y: 14)
            .frame(maxWidth: 720)
            .animation(.easeInOut(duration: 0.2), value: composerHovered || inputFocused)
            .onHover { composerHovered = $0 }
        }
        .frame(maxWidth: .infinity)
        // The @-mention panel FLOATS above the composer (overlapping the
        // transcript) instead of joining the layout — inline it would push
        // the composer down and hide what the user is typing. The overlay
        // is anchored so its bottom edge sits just above the input bar.
        .overlay(alignment: .top) {
            if mentionPanelVisible {
                MentionSuggestionList(
                    results: mentionResults,
                    selectedIndex: $mentionSelection
                ) { item in
                    acceptMention(item)
                }
                .alignmentGuide(.top) { $0[.bottom] + Theme.Spacing.sm }
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, Theme.Spacing.sm)
        .padding(.bottom, 22)
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
                    AttachmentChip(
                        attachment: attachment,
                        onRemove: {
                            pendingAttachments.removeAll { $0.id == attachment.id }
                        },
                        onTap: { previewAttachment = attachment }
                    )
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

    // MARK: - @-Mention Tagging

    private var mentionPanelVisible: Bool {
        mentionActive && !mentionResults.isEmpty
    }

    /// The `@token` the caret currently sits in, if any. `atRange` covers
    /// the "@" through the caret; `query` is the text after the "@". Spaces
    /// are allowed inside the query (names have them); newlines end it.
    private struct MentionToken {
        let atRange: Range<String.Index>
        let query: String
    }

    /// Find the active mention token around the caret. The caret comes from
    /// the focused field editor; if it's unavailable (programmatic text
    /// change) the end of the text is used. The "@" must start the text or
    /// follow whitespace, so emails ("umut@fal.ai") never trigger the panel.
    private func activeMentionToken() -> MentionToken? {
        let text = inputText
        guard !text.isEmpty else { return nil }

        var caretIdx = text.endIndex
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.string == text {
            let location = min(editor.selectedRange().location, (text as NSString).length)
            if let prefix = Range(NSRange(location: 0, length: location), in: text) {
                caretIdx = prefix.upperBound
            }
        }

        var scan = caretIdx
        while scan > text.startIndex {
            let prev = text.index(before: scan)
            let ch = text[prev]
            if ch == "@" {
                guard prev == text.startIndex || text[text.index(before: prev)].isWhitespace else {
                    return nil
                }
                let query = String(text[scan..<caretIdx])
                guard !query.contains(where: \.isNewline), query.count <= 40 else { return nil }
                return MentionToken(atRange: prev..<caretIdx, query: query)
            }
            if ch.isNewline { return nil }
            scan = prev
        }
        return nil
    }

    /// Recompute the panel's contents for the token under the caret. Runs on
    /// every text change — the search is a local title scan, fast enough to
    /// skip debouncing.
    private func refreshMentionState() {
        guard inputFocused, let token = activeMentionToken() else {
            mentionActive = false
            mentionResults = []
            mentionEscapedAt = nil
            return
        }

        let atLocation = NSRange(token.atRange, in: inputText).location
        if let escaped = mentionEscapedAt {
            if escaped == atLocation {
                mentionActive = false
                mentionResults = []
                return
            }
            mentionEscapedAt = nil
        }

        // Caret sitting right after an already-accepted tag ("@Title ") —
        // don't pop the panel back open over a completed token.
        let trimmed = token.query.trimmingCharacters(in: .whitespaces)
        if pendingTags.contains(where: { $0.title == trimmed }) {
            mentionActive = false
            mentionResults = []
            return
        }

        mentionResults = MentionSearch.items(matching: token.query, appState: appState)
        mentionSelection = 0
        mentionActive = true
    }

    /// Replace the active `@token` with the picked item's `@Title` token and
    /// remember the item for send-time expansion. Insertion goes through the
    /// field editor when possible so the caret lands after the tag.
    private func acceptMention(_ item: MentionItem) {
        guard let token = activeMentionToken() else {
            mentionActive = false
            mentionResults = []
            return
        }
        if !pendingTags.contains(where: { $0.id == item.id }) {
            pendingTags.append(item)
        }
        let replacement = "@\(item.title) "
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.string == inputText {
            editor.insertText(replacement, replacementRange: NSRange(token.atRange, in: inputText))
        } else {
            inputText.replaceSubrange(token.atRange, with: replacement)
        }
        mentionActive = false
        mentionResults = []
    }

    /// The "@" composer button: focus the field and type an "@" at the
    /// caret (space-separated from any preceding word) so the panel opens.
    private func insertMentionTrigger() {
        inputFocused = true
        DispatchQueue.main.async {
            if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.string == inputText {
                let caret = editor.selectedRange()
                let needsSpace: Bool = {
                    guard caret.location > 0 else { return false }
                    let prev = (editor.string as NSString).substring(
                        with: NSRange(location: caret.location - 1, length: 1)
                    )
                    return prev.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
                }()
                editor.insertText(needsSpace ? " @" : "@", replacementRange: caret)
            } else {
                if !(inputText.isEmpty || inputText.hasSuffix(" ") || inputText.hasSuffix("\n")) {
                    inputText += " "
                }
                inputText += "@"
            }
        }
    }

    /// Expand accepted `@Title` tokens into the agent-readable inline item
    /// links. Longest titles first so "@Bob Smith" is never half-eaten by a
    /// "@Bob" tag. Tokens the user edited away simply don't match — the tag
    /// silently degrades to plain text.
    private func expandMentionTags(in text: String) -> String {
        guard !pendingTags.isEmpty else { return text }
        var out = text
        for tag in pendingTags.sorted(by: { $0.title.count > $1.title.count }) {
            out = out.replacingOccurrences(of: "@\(tag.title)", with: tag.markdownLink)
        }
        return out
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
                    // Dynamic UTIs (md on a stock system, tsv…) carry no MIME
                    // type — fall back by extension so markdown lands as
                    // text/markdown instead of application/octet-stream.
                    let mediaType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                        ?? ChatAttachment.fallbackMediaType(forExtension: url.pathExtension)
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

    /// A saved prompt sent from the Automations tab ("Use in chat") — fill
    /// the field but DON'T send; the user reviews and edits first.
    private func consumeComposerInsertIfNeeded() {
        guard let text = appState.pendingComposerInsert, !text.isEmpty else { return }
        appState.pendingComposerInsert = nil
        insertText(text)
    }

    /// Insert from the composer's bookmark popover.
    private func insertSavedPrompt(_ prompt: SavedPrompt) {
        Task { await appState.markSavedPromptUsed(id: prompt.id) }
        insertText(prompt.prompt)
    }

    /// Empty field → replace; otherwise append on a new line so an inserted
    /// prompt never silently clobbers typed text.
    private func insertText(_ text: String) {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        inputText = trimmed.isEmpty ? text : inputText + "\n" + text
        inputFocused = true
    }

    /// Hand the prompt to this conversation's run controller (created on
    /// first send) — it owns the turn log, streams events, and persists the
    /// session from the very first turn, so the query survives this view
    /// being torn down mid-run. Other conversations' runs are unaffected.
    private func sendMessage() {
        let text = expandMentionTags(in: inputText.trimmingCharacters(in: .whitespacesAndNewlines))
        let attachments = pendingAttachments
        guard !text.isEmpty || !attachments.isEmpty else { return }
        let controller = appState.chatRuns.openController(
            for: appState.activeChatSessionId,
            appState: appState
        )
        guard !controller.isRunning else { return }

        inputText = ""
        pendingAttachments = []
        pendingTags = []
        mentionActive = false
        mentionResults = []
        controller.send(text: text, attachments: attachments, appState: appState)
    }

    /// Navigation only — a run that's still streaming keeps going in its own
    /// session (reachable via the history sidebar) and stays persisted.
    private func newConversation() {
        appState.activeChatSessionId = nil
        loadedSessionId = nil
        loadedEntries = []
        inputText = ""
        pendingTags = []
        mentionActive = false
        mentionResults = []
    }
}

// MARK: - Message Bubble

private struct MessageBubble: View {
    let text: String
    let isUser: Bool
    let attachments: [ChatAttachment]
    /// Click handler for inline `otto://` item chips in assistant text.
    var onOttoLink: ((URL) -> Void)? = nil
    /// Click handler for attachment chips — opens the full-size preview.
    var onPreviewAttachment: ((ChatAttachment) -> Void)? = nil

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
                            AttachmentChip(attachment: a, onRemove: nil, onTap: {
                                onPreviewAttachment?(a)
                            })
                        }
                    }
                }

                if !text.isEmpty {
                    // One NSTextView per bubble so the whole message is a single,
                    // natively-selectable text region (SwiftUI's .textSelection made
                    // every markdown block its own selection island and dropped
                    // drags inside the scroll view). User messages stay plain
                    // except @-tagged item links, which render as chips;
                    // assistant messages render Claude's markdown so ### and **
                    // don't show as literal characters.
                    if isUser {
                        // Asymmetric radius — the bottom-trailing corner tucks
                        // toward the sender (mockup .mu .bub 14/14/5/14).
                        let bubbleShape = UnevenRoundedRectangle(
                            topLeadingRadius: 14,
                            bottomLeadingRadius: 14,
                            bottomTrailingRadius: 5,
                            topTrailingRadius: 14
                        )
                        SelectableMessageText(
                            attributed: ChatMessageRenderer.userText(text),
                            onOttoLink: onOttoLink
                        )
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(bubbleShape.fill(Theme.Colors.userBubble))
                            .overlay(bubbleShape.strokeBorder(Theme.Colors.border, lineWidth: 1))
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
    /// Opens the full-size attachment preview. The remove button (when
    /// present) keeps priority over the chip tap.
    var onTap: (() -> Void)? = nil

    @State private var hovering = false

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
                .fill(onTap != nil && hovering ? Theme.Colors.hoverTint : Theme.Colors.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .strokeBorder(Theme.Colors.border, lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
        .onHover { hovering = $0 }
        .help(onTap != nil ? "Click to preview" : "")
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
            VStack(alignment: .leading, spacing: 3) {
                // Serif italic + blinking teal dot (mockup .thinking).
                HStack(spacing: 9) {
                    Text("Thinking")
                        .font(Theme.Typography.displaySm.italic())
                        .foregroundStyle(Theme.Colors.tertiaryText)
                    Circle()
                        .fill(Theme.Colors.cyan)
                        .frame(width: 4, height: 4)
                        .opacity(pulse ? 0.25 : 1.0)
                        .animation(
                            .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                            value: pulse
                        )
                }
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

    /// Icon tint: teal once done (mockup .tchip), amber on error, dim while
    /// the call is still in flight.
    private var iconTint: Color {
        if isError { return Theme.Colors.amber }
        return isInFlight ? Theme.Colors.textDim : Theme.Colors.cyan
    }

    var body: some View {
        HStack(spacing: 0) {
            // Mono tool chip (mockup .tchip) — panel fill, hairline border,
            // teal icon once the call lands.
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: callIcon)
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(iconTint)
                        .opacity(isInFlight ? (pulse ? 0.35 : 1.0) : 1.0)
                        .animation(
                            isInFlight
                                ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true)
                                : .default,
                            value: pulse
                        )
                    Text(callLabel)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .tracking(0.4)
                        .foregroundStyle(isError ? Theme.Colors.amber : Theme.Colors.tertiaryText)
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
                    .padding(.leading, 16)  // align under callLabel (icon width + spacing)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(Theme.Colors.panel)
            )
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

// MARK: - Chat Media Card
//
// Inline preview for media files in the transcript — the payoff of a
// genmedia run (or an attach_item_preview on an image/video/audio file)
// should be the media itself, not a generic file row. Images render as a
// thumbnail, videos as an inline player, audio as a compact play bar; a
// caption row underneath keeps the name, size, save-to-disk, and the
// click-through to the full FilePreviewPopup lightbox.

private struct ChatMediaCard: View {
    let file: FileItem
    /// Opens the FilePreviewPopup sheet — owned by OttoChatView because
    /// sheets attached inside LazyVStack rows don't present.
    let onOpen: () -> Void

    @State private var fileURL: URL?
    @State private var missingOnDisk = false
    @State private var thumbnail: NSImage?
    @State private var thumbnailLoadFinished = false

    /// File types this card can render inline. Everything else stays on
    /// the generic ItemPreviewCard.
    static func supports(_ type: FileType) -> Bool {
        type == .image || type == .video || type == .audio
    }

    private var accent: Color { file.fileType.color }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                mediaArea
                captionBar
            }
            .frame(maxWidth: 440)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .fill(Theme.Colors.panel)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .strokeBorder(Theme.Colors.border, lineWidth: 1)
            )

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .task(id: file.id) {
            await resolveMedia()
        }
    }

    // MARK: Media area

    @ViewBuilder
    private var mediaArea: some View {
        if missingOnDisk {
            mediaPlaceholder(icon: file.fileType.iconName, label: "File missing on disk")
        } else {
            switch file.fileType {
            case .image:
                imageArea
            case .video:
                if let url = fileURL {
                    InlineVideoPlayer(url: url)
                } else {
                    mediaPlaceholder(icon: "film", label: nil)
                }
            case .audio:
                if let url = fileURL {
                    InlineAudioPlayer(url: url, accent: accent)
                        .padding(.horizontal, 13)
                        .padding(.top, 12)
                        .padding(.bottom, 4)
                } else {
                    mediaPlaceholder(icon: "waveform", label: nil)
                }
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var imageArea: some View {
        if let thumbnail {
            Button(action: onOpen) {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 320)
                    .background(Theme.Colors.bg1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open preview")
        } else if thumbnailLoadFinished {
            mediaPlaceholder(icon: "photo", label: "Unable to load image")
        } else {
            ZStack {
                Theme.Colors.bg1
                ProgressView().controlSize(.small)
            }
            .frame(height: 160)
            .frame(maxWidth: .infinity)
        }
    }

    private func mediaPlaceholder(icon: String, label: String?) -> some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .thin))
                .foregroundStyle(accent.opacity(0.8))
            if let label {
                Text(label)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
        }
        .frame(height: 110)
        .frame(maxWidth: .infinity)
        .background(Theme.Colors.bg1)
    }

    // MARK: Caption bar

    private var captionBar: some View {
        Button(action: onOpen) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: file.fileType.iconName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(accent)

                Text(file.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Colors.text)
                    .lineLimit(1)

                Text("\(file.fileType.displayName.lowercased()) • \(file.formattedSize)")
                    .font(Theme.Typography.monoSmall)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .lineLimit(1)
                    .layoutPriority(1)

                Spacer(minLength: 0)

                // Same save-to-disk affordance as the generic file card —
                // a generated image should end up in Finder in one click.
                Button {
                    FileSavePanel.save(file)
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.Colors.textDim)
                }
                .buttonStyle(.plain)
                .help("Save to disk…")

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Loading

    /// Resolve the stored binary's URL (and, for images, decode a
    /// downsampled thumbnail off the main thread).
    @MainActor
    private func resolveMedia() async {
        let url = await FileStorageService.shared.getFileURL(for: file)
        let exists = FileManager.default.fileExists(atPath: url.path)
        fileURL = exists ? url : nil
        missingOnDisk = !exists
        guard exists, file.fileType == .image else {
            thumbnailLoadFinished = true
            return
        }
        thumbnail = await MediaThumbnailLoader.load(url: url, maxPixel: 1000)
        thumbnailLoadFinished = true
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
    /// Full media lightbox (FilePreviewPopup) for a chat media card —
    /// richer than the generic search-result popup for images/video/audio.
    case filePreview(FileItem)

    var id: UUID {
        switch self {
        case .result(let r):      return r.id
        case .network(let n):     return n.id
        case .company(let c):     return c.id
        case .event(let e):       return e.id
        case .community(let c):   return c.id
        case .habit(let h):       return h.id
        case .filePreview(let f): return f.id
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
        case .automation: return nil
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

                // Files get a save-to-disk affordance right on the card —
                // "send me an xlsx" should end in a Finder-visible file, not
                // just an in-app preview.
                if type == .file, let file = appState.files.first(where: { $0.id == itemId }) {
                    Button {
                        FileSavePanel.save(file)
                    } label: {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Theme.Colors.textDim)
                    }
                    .buttonStyle(.plain)
                    .help("Save to disk…")
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.lg)
                    .fill(Theme.Colors.panel)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.lg)
                            .strokeBorder(Theme.Colors.border, lineWidth: 1)
                    )
            )
            .overlay(alignment: .leading) {
                // Teal result-card spine (mockup .rescard border-left).
                UnevenRoundedRectangle(
                    topLeadingRadius: Theme.Radius.lg,
                    bottomLeadingRadius: Theme.Radius.lg,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 0
                )
                .fill(Theme.Colors.cyan)
                .frame(width: 2)
            }
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
        case .automation: return nil
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
            case .automation: return nil
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
