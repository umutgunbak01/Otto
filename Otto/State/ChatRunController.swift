import Foundation

// MARK: - Chat UI Entry

/// One renderable row in the chat transcript — a message bubble, a tool-step
/// chip, an item-preview card, an approval prompt. Lived inside `OttoChatView`
/// as a private type until the live run was hoisted out of the view; now
/// shared between the view (rendering) and `ChatRunController` (event
/// handling).
struct ChatUIEntry: Identifiable {
    let id = UUID()
    /// Anthropic tool_use id, when this entry represents a tool step.
    /// Used to match a `.toolResult` back to its originating call.
    var toolUseId: String?
    var kind: Kind

    enum Kind {
        case userText(text: String, attachments: [ChatAttachment])
        case assistantText(String)
        /// Assistant text that's still being streamed in — visually
        /// identical to `.assistantText` but flagged so event handling can
        /// keep appending deltas to the same bubble. Replaced with the
        /// finalized `.assistantText` when the canonical `.text(...)`
        /// event lands at end-of-turn.
        case assistantTextStreaming(String)
        /// Streaming "chain of thought" from the model. Rendered dim and
        /// italic above the eventual answer so the user can follow the
        /// agent's reasoning. Stays visible after the turn ends.
        case thinkingStream(String)
        /// A single Claude tool step: the call line ("Searching for 'recipe'")
        /// and an optional result line ("→ Found 3 results"). While the call
        /// is in flight the icon pulses and `resultLabel` is nil.
        case toolStep(callIcon: String, callLabel: String, resultLabel: String?, isError: Bool, isInFlight: Bool)
        case itemPreview(type: ContentType, itemId: UUID)
        /// Inline chart/table/stat card from the `visualize` tool. The full
        /// spec is decoded from the tool call's input, so it renders with no
        /// AppState dependency and rebuilds from persisted sessions.
        case visualization(spec: VisualizationSpec)
        /// Hermes (ACP) approval card. `approvalId` is the opaque key
        /// `HermesAgentService` uses to match the user's decision back to
        /// the in-flight `session/request_permission` request. `resolved`
        /// flips to true once the user clicks a button so the buttons
        /// fade out and stop accepting input.
        case approvalRequest(approvalId: String, toolName: String, argsSummary: String, resolved: Bool)
        /// Subtle telemetry caption under an assistant turn — duration, tool
        /// count, tokens/cost where the backend reports them.
        case turnStats(TurnStats, toolCalls: Int)
        /// Degraded-turn warning (e.g. tools unavailable) — dim caption row.
        case notice(String)

        var isUser: Bool { if case .userText = self { return true }; return false }
        var isToolStep: Bool { if case .toolStep = self { return true }; return false }
        var isInFlightToolStep: Bool {
            if case .toolStep(_, _, _, _, let inFlight) = self { return inFlight }
            return false
        }
        /// Any entry that's actively absorbing streamed content — used by
        /// the idle-dots indicator to suppress itself the moment real
        /// output starts flowing in.
        var isStreaming: Bool {
            switch self {
            case .assistantTextStreaming, .thinkingStream: return true
            default: return false
            }
        }
    }
}

// MARK: - Chat Run Controller

/// Owns ONE conversation's live agent run — the turn log, the streaming UI
/// entries, and the in-flight run task. Instances live in `AppState`'s
/// `ChatRunRegistry` (NOT in the chat view) so a working query survives the
/// chat sheet closing, the user switching sessions or tabs, or the view
/// otherwise being torn down; reopening the conversation reattaches to the
/// same stream. Multiple controllers can run concurrently — one per
/// conversation — since every backend isolates runs by `sessionKey`.
///
/// Persistence contract (the reason this type exists):
///   1. The session is created + persisted the moment the user sends — an
///      in-flight chat shows up in the history sidebar immediately.
///   2. Progress is checkpointed after every tool result, so a quit/crash
///      mid-run keeps the partial transcript.
///   3. Stop and the error path persist whatever partial output streamed in.
///   4. Completion persists the canonical turn log returned by the backend.
@Observable
final class ChatRunController {
    /// The conversation this controller is permanently bound to.
    let sessionId: UUID
    /// Completed turns of the live conversation. The in-flight assistant
    /// turn is accumulated separately in `pendingBlocks` and only folded in
    /// for persistence snapshots (or when the run ends early).
    private(set) var turns: [ChatTurn] = []
    /// Renderable transcript, including streaming bubbles / tool chips.
    private(set) var entries: [ChatUIEntry] = []
    private(set) var isRunning = false
    /// Last run's failure, if any. The view shows it as a banner while the
    /// live session is on screen; dismissible by setting back to nil.
    var error: String?

    /// Handle to the in-flight turn so Stop can cancel it.
    @ObservationIgnored private var runTask: Task<Void, Never>?
    /// Assistant content blocks reconstructed from events during the
    /// in-flight turn. Persisted as a partial assistant turn on checkpoints
    /// and on stop/error — replaced by the backend's canonical turn log when
    /// the run completes normally.
    @ObservationIgnored private var pendingBlocks: [ChatBlock] = []
    /// Streamed-but-unfinalized assistant text (deltas since the last
    /// end-of-message `.text` event).
    @ObservationIgnored private var streamBuffer: String = ""
    /// Completion hook for programmatic (scheduled-task) runs. Fired exactly
    /// once per run with `nil` on success or an error/stop description —
    /// covers normal completion, errors, Stop, and session deletion, so a
    /// waiting scheduler can never deadlock on a run that ended sideways.
    @ObservationIgnored private var finishHandler: (@MainActor (String?) -> Void)?

    /// Bind to a conversation. For an existing session pass its persisted
    /// turns; a fresh chat starts empty.
    @MainActor
    init(sessionId: UUID, turns: [ChatTurn] = [], appState: AppState) {
        self.sessionId = sessionId
        self.turns = turns
        self.entries = turns.isEmpty ? [] : Self.rebuildEntries(from: turns, appState: appState)
    }

    // MARK: - Send

    /// Start a turn in this controller's conversation. The user's turn is
    /// persisted immediately, before the agent run begins, so the chat is
    /// never absent from history while it works.
    ///
    /// `background: true` is the scheduled-task path: the run must not yank
    /// the user's chat focus to this session, and must not fire IntentRouter
    /// side effects (opening URLs, capturing the screen) while unattended.
    /// `onFinish` reports the run's end exactly once — `nil` on success,
    /// otherwise an error/stop description.
    ///
    /// `contextNote` is appended to the model-bound text only — the chat
    /// bubble and persisted turn keep the user's raw words, exactly like
    /// IntentRouter's annotations. Quick capture uses it to point the agent
    /// at a staged screenshot.
    @MainActor
    func send(
        text: String,
        attachments: [ChatAttachment],
        appState: AppState,
        contextNote: String? = nil,
        background: Bool = false,
        onFinish: (@MainActor (String?) -> Void)? = nil
    ) {
        guard !isRunning else {
            onFinish?("A run is already in progress in this session.")
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else {
            onFinish?("Empty prompt.")
            return
        }

        // If the user only attached files without typing, send a default
        // prompt so the model has something to respond to.
        let baseText = trimmed.isEmpty ? "(see attached files)" : trimmed

        error = nil
        finishHandler = onFinish
        turns.append(ChatTurn(role: "user", blocks: [.text(baseText)], attachments: attachments))
        entries.append(ChatUIEntry(kind: .userText(text: trimmed, attachments: attachments)))
        isRunning = true
        if !background {
            appState.activeChatSessionId = sessionId
        }

        // Persist right away — the in-flight chat appears in the sidebar and
        // survives a crash even though the assistant hasn't replied yet.
        let eagerTurns = turns
        Task { await persist(turns: eagerTurns, appState: appState) }

        let state = appState
        let detectedIntent = background ? nil : IntentRouter.detect(userInput: trimmed)
        let capturedTurns = turns

        runTask = Task {
            // Deterministic intent side-effect (may be async, e.g. screen
            // capture). Runs before the agent so the URL is open / screenshot
            // is saved by the time the model reads its context note.
            var turnsForClaude = capturedTurns
            var annotations: [String] = []
            if let intent = detectedIntent {
                await IntentRouter.apply(intent, appState: state)
                annotations.append(IntentRouter.contextNote(for: intent))
            }
            if let contextNote {
                annotations.append(contextNote)
            }
            if !annotations.isEmpty, var lastTurn = turnsForClaude.popLast() {
                let annotated = baseText + "\n" + annotations.joined(separator: "\n")
                lastTurn = ChatTurn(
                    role: lastTurn.role,
                    blocks: [.text(annotated)],
                    attachments: lastTurn.attachments,
                    timestamp: lastTurn.timestamp
                )
                turnsForClaude.append(lastTurn)
            }

            let executor = await MainActor.run { OttoToolExecutor(appState: state) }
            let systemPrompt = state.claude.buildSystemPrompt(from: state)

            do {
                let updated = try await state.claude.chatWithTools(
                    sessionKey: self.sessionId,
                    turns: turnsForClaude,
                    systemPrompt: systemPrompt,
                    tools: OttoTools.all,
                    executor: executor,
                    onEvent: { event in
                        self.handleEvent(event, appState: state)
                    }
                )
                // User hit Stop mid-run: stop() already finalized + persisted
                // the partial transcript — drop this turn's late result.
                if Task.isCancelled { return }
                await MainActor.run {
                    self.turns = updated
                    self.pendingBlocks = []
                    self.streamBuffer = ""
                    self.isRunning = false
                    // Telemetry caption for the turn that just finished.
                    if let last = updated.last, last.role == "assistant", let stats = last.stats {
                        let toolCalls = last.blocks.filter {
                            if case .toolUse = $0 { return true }; return false
                        }.count
                        self.entries.append(ChatUIEntry(kind: .turnStats(stats, toolCalls: toolCalls)))
                    }
                }
                // Persist the canonical session (turns + tool calls) and the
                // legacy flattened askHistory in parallel so old code paths
                // that read askHistory continue to work.
                await self.persist(turns: updated, appState: state)
                let flattened = await MainActor.run { self.flattenForHistory(updated, appState: state) }
                await state.addToAskHistory(messages: flattened)
                await MainActor.run { self.fireFinish(nil) }
            } catch {
                // A user-initiated Stop surfaces as a cancellation / killed
                // subprocess — that's expected; stop() already cleaned up
                // (and fired the finish handler).
                if Task.isCancelled { return }
                await MainActor.run {
                    self.error = error.localizedDescription
                    self.finishRunKeepingPartialOutput(appState: state)
                    Sounds.play(.error)
                    self.fireFinish(error.localizedDescription)
                }
            }
        }
    }

    /// Invoke and clear the run's completion hook — exactly once per run.
    @MainActor
    private func fireFinish(_ error: String?) {
        guard let handler = finishHandler else { return }
        finishHandler = nil
        handler(error)
    }

    // MARK: - Externally-driven runs (voice mode)

    /// Voice mode drives a conversation through these four methods instead of
    /// `send` — the agent run itself lives in `VoiceSessionManager` (it needs
    /// per-token deltas for TTS chunking), but every UI and persistence side
    /// effect mirrors a typed run: user bubble, streaming text, tool chips,
    /// preview cards, checkpointing, history.
    ///
    /// `displayText` is what the user bubble shows (the raw transcript);
    /// `turnText` is what actually went to the model (may carry an intent
    /// context note) — same split `send` makes internally.
    @MainActor
    func beginExternalTurn(displayText: String, turnText: String, appState: AppState) {
        guard !isRunning else { return }
        error = nil
        turns.append(ChatTurn(role: "user", blocks: [.text(turnText)]))
        entries.append(ChatUIEntry(kind: .userText(text: displayText, attachments: [])))
        isRunning = true
        // Focus this conversation — a voice turn only happens when the user
        // just spoke, so it's what they expect to be looking at.
        appState.activeChatSessionId = sessionId
        let eagerTurns = turns
        Task { await persist(turns: eagerTurns, appState: appState) }
    }

    /// Forward one streamed event from the external run. Rendering is
    /// identical to a typed run because the backends emit the same events.
    @MainActor
    func ingestExternalEvent(_ event: ChatEvent, appState: AppState) {
        guard isRunning else { return }
        handleEvent(event, appState: appState)
    }

    /// The external run completed normally — adopt its canonical turn log and
    /// persist, exactly like `send`'s success path.
    @MainActor
    func completeExternalTurn(canonicalTurns: [ChatTurn], appState: AppState) {
        guard isRunning else { return }
        turns = canonicalTurns
        pendingBlocks = []
        streamBuffer = ""
        isRunning = false
        let flattened = flattenForHistory(canonicalTurns, appState: appState)
        Task {
            await self.persist(turns: canonicalTurns, appState: appState)
            await appState.addToAskHistory(messages: flattened)
        }
    }

    /// The external run ended early (barge-in, overlay closed, error) — keep
    /// whatever streamed in, same as Stop.
    @MainActor
    func interruptExternalTurn(appState: AppState) {
        guard isRunning else { return }
        finishRunKeepingPartialOutput(appState: appState)
    }

    // MARK: - Stop / abandon

    /// Stop this conversation's in-flight agent run. Cancels the Swift task
    /// driving the turn (so its late result is dropped) and tells the backend
    /// to abort just this run: Hermes cancels this session's ACP turn
    /// (session preserved), the CLI backends terminate this run's subprocess.
    /// Other conversations' runs keep going. Partial output that already
    /// streamed in is kept and persisted instead of being thrown away.
    @MainActor
    func stop(appState: AppState) {
        guard isRunning else { return }
        runTask?.cancel()
        runTask = nil
        Task { [sessionId] in await appState.claude.cancelRun(sessionKey: sessionId) }
        finishRunKeepingPartialOutput(appState: appState)
        fireFinish("Stopped by user.")
    }

    /// Forget the conversation — its session was deleted or history was
    /// cleared. Cancels any in-flight run so a late completion can't
    /// resurrect the deleted session.
    @MainActor
    func abandon() {
        let wasRunning = isRunning
        runTask?.cancel()
        runTask = nil
        if wasRunning {
            Task { [sessionId] in await AgentService.shared.cancelRun(sessionKey: sessionId) }
        }
        fireFinish("Session was deleted.")
        isRunning = false
        turns = []
        entries = []
        pendingBlocks = []
        streamBuffer = ""
        error = nil
    }

    /// Fold streamed-but-unfinished assistant output into `turns`, freeze the
    /// streaming UI entries, mark the run over, and persist. Shared by Stop
    /// and the error path so partial output survives a reload instead of
    /// vanishing.
    @MainActor
    private func finishRunKeepingPartialOutput(appState: AppState) {
        isRunning = false
        for idx in entries.indices {
            if case .assistantTextStreaming(let s) = entries[idx].kind {
                entries[idx].kind = .assistantText(s)
            } else if case .toolStep(_, let call, let result, let isErr, true) = entries[idx].kind {
                entries[idx].kind = .toolStep(
                    callIcon: "stop.circle",
                    callLabel: call,
                    resultLabel: result,
                    isError: isErr,
                    isInFlight: false
                )
            }
        }
        turns = snapshotTurns()
        pendingBlocks = []
        streamBuffer = ""
        let snapshot = turns
        Task { await persist(turns: snapshot, appState: appState) }
    }

    // MARK: - Event handling

    @MainActor
    private func handleEvent(_ event: ChatEvent, appState: AppState) {
        switch event {
        case .partialText(let chunk):
            guard !chunk.isEmpty else { return }
            streamBuffer += chunk
            // Mutate `kind` on the existing entry in place — assigning a
            // freshly-constructed ChatUIEntry would change its `id`, which
            // SwiftUI's ForEach treats as a delete+insert, re-mounting
            // the row on every delta and effectively making the streaming
            // bubble invisible (you only ever see the finalized state).
            if let lastIdx = entries.indices.last,
               case .assistantTextStreaming(let existing) = entries[lastIdx].kind {
                entries[lastIdx].kind = .assistantTextStreaming(existing + chunk)
            } else {
                entries.append(ChatUIEntry(kind: .assistantTextStreaming(chunk)))
            }
        case .thinkingDelta(let chunk):
            guard !chunk.isEmpty else { return }
            // Thinking and final text can interleave; merge into the most
            // recent thinking entry if it's the last thing we added, else
            // start a new one. Mutate `kind` in place for the same
            // identity-stability reason as `.partialText` above.
            if let lastIdx = entries.indices.last,
               case .thinkingStream(let existing) = entries[lastIdx].kind {
                entries[lastIdx].kind = .thinkingStream(existing + chunk)
            } else {
                entries.append(ChatUIEntry(kind: .thinkingStream(chunk)))
            }
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            pendingBlocks.append(.text(text))
            streamBuffer = ""
            // Promote the streaming bubble to its finalized form by
            // mutating `kind` — same identity-stability reasoning.
            if let lastIdx = entries.indices.last,
               case .assistantTextStreaming = entries[lastIdx].kind {
                entries[lastIdx].kind = .assistantText(text)
            } else {
                entries.append(ChatUIEntry(kind: .assistantText(text)))
            }
        case .toolCall(let id, let name, let input):
            pendingBlocks.append(.toolUse(id: id, name: name, input: JSONValue.from(any: input)))
            // attach_item_preview renders as a card directly — no chip. The
            // toolUseId is kept on the card so the result event can tell the
            // card already exists. Backends that don't deliver tool inputs
            // (ACP without rawInput) fall through to a chip here and get
            // upgraded to a card when the result arrives below.
            if OttoTools.isAttachItemPreview(name),
               let preview = Self.parseItemPreview(from: input) {
                // create_file auto-attaches a card for its output — if the
                // agent redundantly attaches the same item, don't double-render.
                if Self.containsPreview(entries, itemId: preview.id) { return }
                entries.append(ChatUIEntry(toolUseId: id, kind: .itemPreview(type: preview.type, itemId: preview.id)))
                return
            }
            // visualize renders as an inline chart/table card — same pattern
            // as attach_item_preview: the full spec lives in the tool input.
            // An unparseable spec falls through to a chip, which the error
            // result then settles with the executor's message.
            if OttoTools.isVisualize(name),
               let spec = try? VisualizationSpec.parse(input) {
                entries.append(ChatUIEntry(toolUseId: id, kind: .visualization(spec: spec)))
                return
            }
            let label = OttoToolLabels.describe(name: name, input: input, appState: appState)
            entries.append(ChatUIEntry(
                toolUseId: id,
                kind: .toolStep(
                    callIcon: "wrench.and.screwdriver",
                    callLabel: Self.composedCallLabel(label),
                    resultLabel: nil,
                    isError: false,
                    isInFlight: true
                )
            ))
        case .toolResult(let id, let name, let summary, let isError):
            pendingBlocks.append(.toolResult(toolUseId: id, content: summary, isError: isError))
            // Checkpoint after every completed tool call so a quit/crash
            // mid-run keeps the transcript up to this point. Rare enough
            // (a handful per turn) that whole-store writes are fine.
            let snapshot = snapshotTurns()
            Task { await persist(turns: snapshot, appState: appState) }

            // create_file: a successful call should read as a downloadable
            // file card, not a bare tool chip. Recover the new file's id from
            // the executor's "Created file: <uuid> …" line and upgrade the
            // chip in place (same identity-stability trick as the preview
            // path below). Errors fall through so the chip settles and shows
            // the failure line.
            if OttoTools.isCreateFile(name), !isError,
               let fileId = OttoTools.parseCreatedFileResult(summary) {
                if let idx = entries.lastIndex(where: { entry in
                    entry.toolUseId == id && entry.kind.isToolStep
                }) {
                    entries[idx].kind = .itemPreview(type: .file, itemId: fileId)
                } else {
                    entries.append(ChatUIEntry(toolUseId: id, kind: .itemPreview(type: .file, itemId: fileId)))
                }
                return
            }

            // genmedia_run: same treatment — a successful generation should
            // read as inline media, not a JSON blob in a chip. Recover the
            // imported file ids from the result payload and upgrade the chip
            // to one preview card per file (images render inline; video/audio
            // get players). "Model returned no media" results carry no ids
            // and fall through to a plain settled chip.
            if OttoTools.isGenmediaRun(name), !isError {
                let fileIds = OttoTools.parseGenmediaRunFileIds(summary)
                    .filter { !Self.containsPreview(entries, itemId: $0) }
                if !fileIds.isEmpty {
                    if let idx = entries.lastIndex(where: { entry in
                        entry.toolUseId == id && entry.kind.isToolStep
                    }) {
                        entries[idx].kind = .itemPreview(type: .file, itemId: fileIds[0])
                        for (offset, fileId) in fileIds.dropFirst().enumerated() {
                            entries.insert(
                                ChatUIEntry(toolUseId: id, kind: .itemPreview(type: .file, itemId: fileId)),
                                at: idx + 1 + offset
                            )
                        }
                    } else {
                        for fileId in fileIds {
                            entries.append(ChatUIEntry(toolUseId: id, kind: .itemPreview(type: .file, itemId: fileId)))
                        }
                    }
                    return
                }
            }

            if OttoTools.isAttachItemPreview(name) {
                // Card already rendered on the toolCall event → the result is
                // a no-op so we don't show a redundant checkmark chip.
                let cardExists = entries.contains { entry in
                    if case .itemPreview = entry.kind { return entry.toolUseId == id }
                    return false
                }
                if cardExists { return }
                // The call event had no usable input (ACP without rawInput) so
                // a plain chip is pulsing. Recover {type, id} from the
                // executor's result line and upgrade the chip to a card; on
                // failure (e.g. "No connection found…") fall through so the
                // chip settles and shows the error line.
                if !isError,
                   let parsed = OttoTools.parsePreviewResult(summary),
                   let type = OttoTools.previewContentType(parsed.typeString) {
                    // Same-item card already on screen (e.g. auto-attached by
                    // create_file) — swallow the duplicate.
                    if Self.containsPreview(entries, itemId: parsed.id) { return }
                    // Mutate `kind` in place (not a fresh entry) so the row's
                    // identity — and any tool-group expansion state keyed to
                    // it — survives the upgrade.
                    if let idx = entries.lastIndex(where: { entry in
                        entry.toolUseId == id && entry.kind.isToolStep
                    }) {
                        entries[idx].kind = .itemPreview(type: type, itemId: parsed.id)
                    } else {
                        entries.append(ChatUIEntry(toolUseId: id, kind: .itemPreview(type: type, itemId: parsed.id)))
                    }
                    return
                }
            }

            if OttoTools.isVisualize(name) {
                // Card already rendered on the toolCall event → suppress the
                // redundant result chip. If no card exists (invalid spec), a
                // plain chip is pulsing and settles below with the error.
                let cardExists = entries.contains { entry in
                    if case .visualization = entry.kind { return entry.toolUseId == id }
                    return false
                }
                if cardExists { return }
            }

            // Settle the matching in-flight step in place: keep the call line,
            // swap the icon, fill in the result line, drop the pulse.
            let idx = entries.lastIndex(where: { entry in
                guard let uid = entry.toolUseId, entry.kind.isInFlightToolStep else { return false }
                return uid == id
            }) ?? entries.lastIndex(where: { $0.kind.isInFlightToolStep })

            let icon = isError ? "exclamationmark.triangle" : "checkmark.circle"
            let resultText = Self.formatResultLine(summary)

            if let idx,
               case .toolStep(_, let callLabel, _, _, _) = entries[idx].kind {
                // In-place kind mutation keeps the entry's identity stable so
                // SwiftUI doesn't remount the row (or reset the tool-group
                // disclosure keyed to it) when the call settles.
                entries[idx].kind = .toolStep(
                    callIcon: icon,
                    callLabel: callLabel,
                    resultLabel: resultText,
                    isError: isError,
                    isInFlight: false
                )
            } else {
                // Fallback: result arrived without a matching call (shouldn't
                // happen, but keep something visible rather than dropping it).
                entries.append(ChatUIEntry(
                    toolUseId: id,
                    kind: .toolStep(
                        callIcon: icon,
                        callLabel: Self.prettyToolName(name),
                        resultLabel: resultText,
                        isError: isError,
                        isInFlight: false
                    )
                ))
            }
        case .approvalRequest(let approvalId, let toolName, let argsSummary):
            entries.append(ChatUIEntry(
                kind: .approvalRequest(
                    approvalId: approvalId,
                    toolName: toolName,
                    argsSummary: argsSummary,
                    resolved: false
                )
            ))
        case .notice(let text):
            entries.append(ChatUIEntry(kind: .notice(text)))
        }
    }

    // MARK: - Approvals

    /// Routes the user's button click back into `HermesAgentService` and
    /// flips the corresponding entry to `resolved: true` so the card stops
    /// accepting further clicks. Also writes "always" decisions to
    /// `ToolApprovalPolicy` so future runs auto-resolve.
    @MainActor
    func resolveApproval(approvalId: String, toolName: String, decision: ApprovalDecision, isAllow: Bool) {
        if decision == .alwaysAllow || decision == .alwaysDeny {
            ToolApprovalPolicy.shared.setDecision(decision, for: toolName)
        }
        // ACP's option ids aren't fixed strings — they're whatever the agent
        // sent us. HermesAgentService knows which optionId to send back
        // given an allow/deny choice and uses the option `kind` field to
        // pick (see PendingApproval.options). We forward a synthetic id
        // that HermesAgentService maps internally.
        let optionId = isAllow ? "__otto_allow" : "__otto_reject"
        Task {
            await HermesAgentService.shared.resolveApproval(approvalId: approvalId, selectedOptionId: optionId)
        }
        if let idx = entries.lastIndex(where: { entry in
            if case .approvalRequest(let aid, _, _, _) = entry.kind { return aid == approvalId }
            return false
        }) {
            if case .approvalRequest(let aid, let tn, let s, _) = entries[idx].kind {
                entries[idx].kind = .approvalRequest(approvalId: aid, toolName: tn, argsSummary: s, resolved: true)
            }
        }
    }

    // MARK: - Persistence

    /// `turns` plus a partial assistant turn assembled from whatever events
    /// have landed so far — what gets persisted mid-run.
    @MainActor
    private func snapshotTurns() -> [ChatTurn] {
        var out = turns
        var blocks = pendingBlocks
        if !streamBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append(.text(streamBuffer))
        }
        if !blocks.isEmpty {
            out.append(ChatTurn(role: "assistant", blocks: blocks))
        }
        return out
    }

    /// Upsert the live conversation into AppState's chat history. Keeps the
    /// original creation date; `upsertChatSession` re-derives the title and
    /// bumps `updatedAt`. Deliberately does NOT touch `activeChatSessionId` —
    /// the user may have navigated to another session while the run works.
    @MainActor
    private func persist(turns: [ChatTurn], appState: AppState) async {
        guard !turns.isEmpty else { return }
        let id = sessionId
        let existing = appState.chatSession(id)
        let session = ChatSession(
            id: id,
            title: existing?.title,
            turns: turns,
            createdAt: existing?.createdAt ?? Date(),
            updatedAt: Date(),
            titlePinned: existing?.titlePinned ?? false
        )
        await appState.upsertChatSession(session)
    }

    // MARK: - Rebuilding saved sessions

    /// Reconstruct the UI event log from a saved session's turns. Tool-result
    /// blocks are merged into their preceding tool-use step with the same id
    /// so the UI shows the call line + result line, just like the live stream.
    @MainActor
    static func rebuildEntries(from turns: [ChatTurn], appState: AppState) -> [ChatUIEntry] {
        var out: [ChatUIEntry] = []
        // Map tool_use id → index in `out` so we can rewrite the step in place
        // when its result comes through.
        var toolIndex: [String: Int] = [:]
        // attach_item_preview calls whose input was missing/unparseable — we
        // rendered a plain chip and will try to upgrade it to a preview card
        // from the tool result's "Attached preview: <type> <uuid>" line.
        var previewChipIds: Set<String> = []
        // create_file calls — their chips get upgraded to downloadable file
        // cards from the result's "Created file: <uuid> …" line, mirroring
        // the live handleEvent path.
        var createFileChipIds: Set<String> = []
        // genmedia_run calls — their chips get upgraded to media preview
        // cards (one per imported file id in the result payload), mirroring
        // the live handleEvent path.
        var genmediaRunChipIds: Set<String> = []

        for turn in turns {
            switch turn.role {
            case "user":
                let text = turn.blocks.compactMap { block -> String? in
                    if case let .text(s) = block { return s } else { return nil }
                }.joined(separator: "\n")
                out.append(ChatUIEntry(kind: .userText(text: text, attachments: turn.attachments)))
            case "assistant":
                let toolCallCount = turn.blocks.filter {
                    if case .toolUse = $0 { return true }; return false
                }.count
                for block in turn.blocks {
                    switch block {
                    case .text(let s):
                        let trimmed = s.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty {
                            out.append(ChatUIEntry(kind: .assistantText(s)))
                        }
                    case .toolUse(let id, let name, let input):
                        if OttoTools.isAttachItemPreview(name),
                           let preview = previewFromInput(input) {
                            // Skip cards for items already shown (create_file
                            // auto-attaches its output, so a redundant
                            // attach call would double-render).
                            if !containsPreview(out, itemId: preview.id) {
                                out.append(ChatUIEntry(toolUseId: id, kind: .itemPreview(type: preview.type, itemId: preview.id)))
                            }
                        } else if OttoTools.isVisualize(name),
                                  let spec = VisualizationSpec.parse(json: input) {
                            // Not registered in toolIndex, so the matching
                            // .toolResult block is skipped — card only, no chip.
                            out.append(ChatUIEntry(toolUseId: id, kind: .visualization(spec: spec)))
                        } else {
                            if OttoTools.isAttachItemPreview(name) {
                                previewChipIds.insert(id)
                            }
                            if OttoTools.isCreateFile(name) {
                                createFileChipIds.insert(id)
                            }
                            if OttoTools.isGenmediaRun(name) {
                                genmediaRunChipIds.insert(id)
                            }
                            let label = OttoToolLabels.describe(name: name, input: input, appState: appState)
                            let callLabel: String
                            if let arg = label.arg, !arg.isEmpty {
                                callLabel = "\(label.verb) \(arg)"
                            } else {
                                callLabel = label.verb
                            }
                            let entry = ChatUIEntry(
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
                            // create_file chip: recover the new file's id from
                            // the result line and upgrade to a downloadable
                            // file card, matching the live path.
                            if createFileChipIds.contains(toolUseId), !isError,
                               let fileId = OttoTools.parseCreatedFileResult(content) {
                                out[idx] = ChatUIEntry(
                                    toolUseId: toolUseId,
                                    kind: .itemPreview(type: .file, itemId: fileId)
                                )
                                continue
                            }
                            // genmedia_run chip: recover the imported file ids
                            // from the result payload and upgrade to media
                            // preview cards, matching the live path. Extra
                            // cards shift every index after the chip, so
                            // toolIndex entries past it must be re-based.
                            if genmediaRunChipIds.contains(toolUseId), !isError {
                                let fileIds = OttoTools.parseGenmediaRunFileIds(content)
                                    .filter { !containsPreview(out, itemId: $0) }
                                if !fileIds.isEmpty {
                                    out[idx] = ChatUIEntry(
                                        toolUseId: toolUseId,
                                        kind: .itemPreview(type: .file, itemId: fileIds[0])
                                    )
                                    for (offset, fileId) in fileIds.dropFirst().enumerated() {
                                        out.insert(
                                            ChatUIEntry(toolUseId: toolUseId, kind: .itemPreview(type: .file, itemId: fileId)),
                                            at: idx + 1 + offset
                                        )
                                    }
                                    let extras = fileIds.count - 1
                                    if extras > 0 {
                                        for (key, value) in toolIndex where value > idx {
                                            toolIndex[key] = value + extras
                                        }
                                    }
                                    continue
                                }
                            }
                            // Preview chip whose call had no usable input:
                            // recover {type, id} from the executor's result
                            // line and upgrade the chip to a real card.
                            // (When the item is already carded — create_file
                            // auto-attach — fall through so the chip settles
                            // as a plain step instead of double-rendering.)
                            if previewChipIds.contains(toolUseId), !isError,
                               let parsed = OttoTools.parsePreviewResult(content),
                               let type = OttoTools.previewContentType(parsed.typeString),
                               !containsPreview(out, itemId: parsed.id) {
                                out[idx] = ChatUIEntry(
                                    toolUseId: toolUseId,
                                    kind: .itemPreview(type: type, itemId: parsed.id)
                                )
                                continue
                            }
                            let icon = isError ? "exclamationmark.triangle" : "checkmark.circle"
                            let resultText = formatResultLine(content)
                            out[idx] = ChatUIEntry(
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
                if let stats = turn.stats {
                    out.append(ChatUIEntry(kind: .turnStats(stats, toolCalls: toolCallCount)))
                }
            default:
                break
            }
        }
        return out
    }

    // MARK: - Helpers

    private static func previewFromInput(_ input: JSONValue) -> (type: ContentType, id: UUID)? {
        guard case let .object(dict) = input,
              case let .string(typeStr) = dict["type"] ?? .null,
              let type = OttoTools.previewContentType(typeStr),
              case let .string(idStr) = dict["id"] ?? .null,
              let id = UUID(uuidString: idStr)
        else { return nil }
        return (type, id)
    }

    /// True when an item-preview card for `itemId` is already in the
    /// transcript — used to keep create_file's auto-attached card and a
    /// redundant attach_item_preview from rendering the same item twice.
    private static func containsPreview(_ entries: [ChatUIEntry], itemId: UUID) -> Bool {
        entries.contains { entry in
            if case .itemPreview(_, let existingId) = entry.kind { return existingId == itemId }
            return false
        }
    }

    private static func parseItemPreview(from input: [String: Any]) -> (type: ContentType, id: UUID)? {
        guard let typeStr = input["type"] as? String,
              let type = OttoTools.previewContentType(typeStr),
              let idStr = input["id"] as? String,
              let id = UUID(uuidString: idStr)
        else { return nil }
        return (type, id)
    }

    private static func composedCallLabel(_ label: OttoToolLabels.Label) -> String {
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

    private static func prettyToolName(_ rawName: String) -> String {
        let raw = OttoTools.canonicalToolName(rawName)
        switch raw {
        case "create_todo": return "Creating todo"
        case "create_note": return "Creating note"
        case "create_idea": return "Creating idea"
        case "create_reminder": return "Creating reminder"
        case "create_bookmark": return "Saving bookmark"
        case "create_meeting": return "Creating meeting"
        case "update_todo": return "Updating todo"
        case "update_note": return "Updating note"
        case "update_idea": return "Updating idea"
        case "update_reminder": return "Updating reminder"
        case "update_bookmark": return "Updating bookmark"
        case "update_meeting": return "Updating meeting"
        case "update_habit": return "Updating habit"
        case "create_network_entry": return "Adding network entry"
        case "update_network_entry": return "Updating network entry"
        case "create_company": return "Creating company"
        case "update_company": return "Updating company"
        case "create_event": return "Creating event"
        case "update_event": return "Updating event"
        case "create_community": return "Creating community"
        case "update_community": return "Updating community"
        case "complete_todo": return "Completing todo"
        case "uncomplete_todo": return "Reopening todo"
        case "complete_reminder": return "Completing reminder"
        case "delete_item": return "Deleting item"
        case "search_items": return "Searching"
        case "get_item": return "Fetching details"
        case "attach_item_preview": return "Attaching preview"
        case "create_file": return "Creating file"
        case "open_url": return "Opening website"
        case "create_habit": return "Creating habit"
        case "log_habit_entry": return "Logging habit entry"
        case "complete_habit": return "Completing habit"
        case "list_habits": return "Listing habits"
        default: return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Convert a full tool-calling turn log into plain [ChatMessage] for askHistory persistence.
    @MainActor
    private func flattenForHistory(_ turns: [ChatTurn], appState: AppState) -> [ChatMessage] {
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

// MARK: - Chat Run Registry

/// One `ChatRunController` per conversation, so multiple chats can run
/// concurrently — every backend isolates runs by `sessionKey` (the CLI
/// backends spawn a subprocess per run; Hermes keeps one ACP session per
/// conversation). Lives on `AppState`. Controllers stick around after their
/// run completes so reopening a recent conversation reattaches to its live
/// transcript; idle controllers are pruned lazily.
@Observable
final class ChatRunRegistry {
    private(set) var controllers: [UUID: ChatRunController] = [:]

    /// Controller for a conversation, if one exists (live or recently run).
    func controller(for sessionId: UUID?) -> ChatRunController? {
        guard let sessionId else { return nil }
        return controllers[sessionId]
    }

    /// Controller to send from: reuses the conversation's existing controller
    /// or creates one seeded with its persisted turns. `sessionId == nil`
    /// mints a fresh conversation.
    @MainActor
    func openController(for sessionId: UUID?, appState: AppState) -> ChatRunController {
        if let sessionId, let existing = controllers[sessionId] { return existing }
        let id = sessionId ?? UUID()
        let saved = appState.chatSession(id)
        let controller = ChatRunController(sessionId: id, turns: saved?.turns ?? [], appState: appState)
        controllers[id] = controller
        prune(keeping: id)
        return controller
    }

    var anyRunning: Bool { controllers.values.contains { $0.isRunning } }

    var runningSessionIds: [UUID] {
        controllers.filter { $0.value.isRunning }.map(\.key)
    }

    func isRunning(_ sessionId: UUID) -> Bool {
        controllers[sessionId]?.isRunning ?? false
    }

    /// Drop a conversation's controller (its session was deleted).
    @MainActor
    func abandon(sessionId: UUID) {
        controllers[sessionId]?.abandon()
        controllers[sessionId] = nil
    }

    /// Drop everything (history cleared).
    @MainActor
    func abandonAll() {
        for controller in controllers.values { controller.abandon() }
        controllers.removeAll()
    }

    /// Cap retained idle controllers so a long app run doesn't accumulate
    /// stale transcripts. Running controllers and the one being opened are
    /// never dropped.
    private func prune(keeping keep: UUID) {
        let cap = 8
        guard controllers.count > cap else { return }
        let idleKeys = controllers.compactMap { key, controller -> UUID? in
            (!controller.isRunning && key != keep) ? key : nil
        }
        for key in idleKeys.prefix(controllers.count - cap) {
            controllers[key] = nil
        }
    }
}
