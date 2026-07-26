import Foundation

/// Hermes backend — drives a long-lived `hermes acp` process running locally
/// on the same Mac as Otto. Unlike `ClaudeCLIService` / `CodexCLIService`,
/// which are stateless and spawn a fresh CLI per turn, this actor keeps the
/// process alive and maintains one ACP session per Otto conversation
/// (`sessionKey`). The agent keeps each session's conversation state
/// in-memory, so every turn after a session's first is just a
/// `session/prompt` write into the existing stdin. Sessions can run turns
/// concurrently — updates are routed by the ACP sessionId they carry.
///
/// Transport stack:
///   Otto.app ── Process ──► `hermes acp` (local subprocess, stdio JSON-RPC)
///                                  │
///                                  │  MCP client (per ~/.hermes/config.yaml)
///                                  ▼
///                            nc -U ~/.otto/mcp.sock  ── OttoMCPServer
///
/// Hermes and Otto are sibling processes; the MCP client opens Otto's local
/// Unix socket directly. No SSH, no network, no reverse tunneling.
///
/// Tool execution runs on the Mac via `OttoToolExecutor` over the MCP bridge.
/// Hermes only sees synthesized JSON-RPC tool replies — the actual execution
/// (Drive token, Supabase PATs, file I/O) all happens in-process here.
///
/// Approval surface: ACP's `session/request_permission` is plumbed through
/// to the UI as `ChatEvent.approvalRequest`. `ToolApprovalPolicy` auto-resolves
/// requests for tools the user has marked alwaysAllow / alwaysDeny.
actor HermesAgentService {
    static let shared = HermesAgentService()

    enum ConnectionState {
        case idle
        case connecting
        case live
        case disconnected(Error?)
    }

    enum HermesError: LocalizedError {
        case binaryNotFound
        case launchFailed(String)
        case processExited(Int32, String)
        case initializeFailed(String)
        case sessionCreateFailed(String)
        case promptFailed(String)
        case disconnected
        case protocolMismatch(Int)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                return "Hermes not installed. Open Settings → Agent → Hermes for install instructions."
            case .launchFailed(let m): return "Failed to launch hermes: \(m)"
            case .processExited(let code, let stderr):
                return "hermes acp exited \(code): \(stderr)"
            case .initializeFailed(let m): return "Hermes ACP initialize failed: \(m)"
            case .sessionCreateFailed(let m): return "Hermes session/new failed: \(m)"
            case .promptFailed(let m): return "Hermes session/prompt failed: \(m)"
            case .disconnected: return "Hermes process exited."
            case .protocolMismatch(let v): return "Hermes returned unsupported ACP protocolVersion=\(v)."
            }
        }
    }

    // MARK: - State

    private var state: ConnectionState = .idle
    private var hermesProcess: Process?
    private var stdinHandle: FileHandle?
    private var stderrBuffer: Data = Data()
    private var stdoutReaderTask: Task<Void, Never>?
    private var sessionTmpDir: URL?

    /// Monotonic JSON-RPC request id. We use ints (encoded into JSONRPCID.int).
    private var nextRequestId: Int = 1

    /// In-flight requests we sent and are waiting on a response for.
    private var pendingResponses: [Int: CheckedContinuation<[String: Any], Error>] = [:]

    /// In-flight `session/request_permission` calls from the agent that haven't
    /// been resolved yet. Keyed by the stringified JSON-RPC id from the agent.
    private struct PendingApproval {
        let jsonRpcId: ACPParser.JSONRPCID
        let options: [ACPParser.PermissionOption]
        let toolName: String
    }
    private var pendingApprovals: [String: PendingApproval] = [:]

    /// `toolCallId` → canonical tool name (MCP prefix stripped, e.g.
    /// `attach_item_preview`), captured from the `tool_call` notification so
    /// we can label later approval requests and tool-result chips. The same
    /// name is used as the `ToolApprovalPolicy` lookup key.
    private var toolCallTitles: [String: String] = [:]

    /// `toolCallId` → tool argument object (ACP `rawInput`). The chat UI
    /// needs the input to render item-preview cards; some agents attach it
    /// on the initial `tool_call`, others only on later updates.
    private var toolCallInputs: [String: [String: Any]] = [:]

    /// Otto conversation id → ACP session id. One ACP session per Otto chat
    /// (and one for background work like the daily briefing), created lazily
    /// on the conversation's first turn after connect.
    private var acpSessions: [UUID: String] = [:]

    /// Otto conversation id → hash of the custom-tab manifest last sent into
    /// that ACP session. The session's seeded system prompt freezes at
    /// creation, so when tabs change mid-session we re-send the manifest as a
    /// context block with the next user message.
    private var sessionManifestHash: [UUID: Int] = [:]

    /// ACP session id → last time the agent showed signs of life (any
    /// session/update or permission request). Drives the stall watchdog.
    private var turnLastActivity: [String: Date] = [:]

    /// Abort a turn after this much silence — no streamed chunks, no tool
    /// calls, no permission requests. Generous: deep "thinking" stretches on
    /// hard prompts are silent but legitimate.
    private static let stallTimeout: TimeInterval = 300

    /// In-flight turn state, keyed by ACP session id. Installed at the start
    /// of `streamChatWithTools`, removed at the end. Multiple sessions can
    /// have a turn in flight at once; `session/update` frames carry the
    /// sessionId that picks the right context.
    private struct TurnContext {
        var onDelta: (@MainActor (String) -> Void)?
        var onEvent: (@MainActor (ChatEvent) -> Void)?
        /// Accumulator for the turn's assistant text — fed by every
        /// `agent_message_chunk`, emitted as `.text(...)` at end of turn.
        var assistantText: String = ""
        /// Ordered block log — text runs interleaved with tool calls/results,
        /// mirroring what the other backends persist. Saved into the returned
        /// assistant `ChatTurn` so reopened sessions rebuild tool chips.
        var turnBlocks: [ChatBlock] = []
    }
    private var activeTurns: [String: TurnContext] = [:]

    private init() {}

    // MARK: - Public API (mirrors ClaudeCLIService.streamChatWithTools)

    func streamChatWithTools(
        sessionKey: UUID,
        turns: [ChatTurn],
        systemPrompt: String,
        tools: [[String: Any]],         // ignored — tools come via MCP
        executor: OttoToolExecutor,    // ignored — executor lives MCP-side
        onDelta: @escaping @MainActor (String) -> Void,
        onEvent: @escaping @MainActor (ChatEvent) -> Void
    ) async throws -> [ChatTurn] {

        let turnStart = Date()
        try await ensureConnected()
        guard case .live = state else {
            throw HermesError.disconnected
        }
        let (sessionId, isFreshSession) = try await ensureSession(for: sessionKey)

        // Build the prompt for this turn. On a fresh ACP session, prepend the
        // system prompt (ACP doesn't have a separate system-prompt slot —
        // same compromise CodexCLIService makes) plus a compact replay of any
        // earlier turns, so continuing a conversation that predates this
        // session (say, after an app restart) doesn't lose its context.
        let lastUserTurn = turns.last { $0.role == "user" }
        var lastUserText = lastUserTurn.map { turn in
            turn.blocks.compactMap { block -> String? in
                if case .text(let s) = block { return s }
                return nil
            }.joined(separator: "\n\n")
        } ?? ""
        // Attachments ride along as inlined text (md/csv/txt…) or filename
        // stubs — Hermes runs remotely, so a local file path would be useless.
        if let turn = lastUserTurn,
           let attachmentSection = ChatTranscript.attachmentSection(turn.attachments) {
            lastUserText = lastUserText.isEmpty
                ? attachmentSection
                : lastUserText + "\n\n" + attachmentSection
        }

        // Current custom-tab manifest — hashed to detect mid-session changes.
        // (The seeded system prompt freezes at session start; see below.)
        let manifestNow: String? = await MainActor.run {
            guard let appState = OttoMCPServer.shared.appState else { return nil }
            return AgentService.customTabsSection(from: appState)
        }
        let manifestHash = (manifestNow ?? "").hashValue

        var combined: String
        if isFreshSession {
            var pieces: [String] = []
            if !systemPrompt.isEmpty { pieces.append("[system]\n\(systemPrompt)") }
            if let replay = Self.historyReplay(turns: turns) {
                pieces.append("[Earlier conversation, replayed for context]\n\(replay)")
            }
            pieces.append(lastUserText)
            combined = pieces.joined(separator: "\n\n")
            sessionManifestHash[sessionKey] = manifestHash
        } else {
            // Context refresher — the ACP session's system prompt was seeded
            // once and never updates, so anything time- or shape-sensitive in
            // it goes stale as the session lives on. Ride a compact refresh
            // along with each user message: the current date/time always
            // (otherwise "today" resolves against the seed timestamp), plus
            // the custom-tab manifest when it changed since last sent.
            var refresh: [String] = [AgentService.nowStamp()]
            if sessionManifestHash[sessionKey] != manifestHash {
                sessionManifestHash[sessionKey] = manifestHash
                if let manifestNow {
                    refresh.append("Custom tabs changed since earlier in this session — current manifest:\n\(manifestNow)")
                } else {
                    refresh.append("All custom tabs have been deleted since earlier in this session.")
                }
            }
            combined = "[context refresh — not from the user]\n\(refresh.joined(separator: "\n\n"))\n\n\(lastUserText)"
        }

        // Screen-vision handoff: IntentRouter stashes a PNG path on AppState.
        // Copy it into the current session's tmp dir as `screenshot.png` and
        // append a hint to the prompt so the agent knows to look there via
        // Otto's `read_file` MCP tool. Same posture as ClaudeCLIService.
        if let appState = OttoMCPServer.shared.appState,
           let tmpDir = sessionTmpDir {
            let pendingPath: String? = await MainActor.run {
                let path = appState.pendingScreenshotPath
                appState.pendingScreenshotPath = nil
                return path
            }
            if let pendingPath = pendingPath {
                let src = URL(fileURLWithPath: pendingPath)
                let dst = tmpDir.appendingPathComponent("screenshot.png")
                do {
                    if FileManager.default.fileExists(atPath: dst.path) {
                        try FileManager.default.removeItem(at: dst)
                    }
                    try FileManager.default.copyItem(at: src, to: dst)
                    try? FileManager.default.removeItem(at: src)
                    NSLog("[Hermes] screenshot staged at %@", dst.path)
                    combined += "\n\n[A screenshot of my screen is at \(dst.path). Read it if you need to see what I'm looking at.]"
                } catch {
                    NSLog("[Hermes] failed to stage screenshot: %@", error.localizedDescription)
                }
            }
        }

        // Install this turn's context — sinks plus accumulators — under the
        // ACP session id so the reader task routes concurrent sessions'
        // updates to the right turn. Guaranteed removal even on throw, so a
        // later turn isn't routed to a stale closure.
        activeTurns[sessionId] = TurnContext(onDelta: onDelta, onEvent: onEvent)
        turnLastActivity[sessionId] = Date()
        defer {
            activeTurns[sessionId] = nil
            turnLastActivity[sessionId] = nil
        }

        // Send session/prompt and await the stopReason response. Tool calls,
        // approval round-trips, and streaming chunks all flow asynchronously
        // through the reader task while we wait here.
        let promptId = allocateRequestId()
        let request = ACPParser.promptRequest(
            id: .int(promptId),
            sessionId: sessionId,
            text: combined
        )

        // Stall watchdog — a hung Hermes otherwise pins this turn forever
        // (`sendAndAwait` has no deadline of its own). Any session/update or
        // permission request counts as activity; a pending approval card
        // pauses the clock (the user may be away).
        let watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if Task.isCancelled { return }
                guard let self else { return }
                if await self.fireIfStalled(sessionId: sessionId, promptId: promptId) { return }
            }
        }
        defer { watchdog.cancel() }

        do {
            _ = try await sendAndAwait(id: promptId, request: request)
        } catch {
            throw HermesError.promptFailed(error.localizedDescription)
        }

        // Emit the final assistant text once at end-of-turn, mirroring how
        // ClaudeCLIService caps the stream with a `.text(...)` event.
        let assistantText = activeTurns[sessionId]?.assistantText ?? ""
        let finalText = assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalText.isEmpty {
            let captured = finalText
            await MainActor.run { onEvent(.text(captured)) }
        }

        // Persist the full block log (text + tool calls + results) so the
        // saved session rebuilds chips and preview cards; fall back to a bare
        // text block if nothing was logged.
        let turnBlocks = activeTurns[sessionId]?.turnBlocks ?? []
        let blocks = turnBlocks.isEmpty
            ? [ChatBlock.text(assistantText)]
            : turnBlocks
        let stats = TurnStats(
            durationMs: Int(Date().timeIntervalSince(turnStart) * 1000),
            backend: AgentBackend.hermes.rawValue
        )
        var updated = turns
        updated.append(ChatTurn(role: "assistant", blocks: blocks, stats: stats))
        return updated
    }

    /// Create (or reuse) the ACP session backing an Otto conversation.
    /// Returns `isFresh: true` when the session was just created — the caller
    /// then prepends the system prompt and any history replay.
    private func ensureSession(for key: UUID) async throws -> (sessionId: String, isFresh: Bool) {
        if let existing = acpSessions[key] { return (existing, false) }
        // Google MCP servers are injected per session with a freshly
        // refreshed Bearer token, so later-created sessions don't inherit a
        // stale token from connect time. Custom servers are read per session
        // too, so an Integrations change applies to the next conversation
        // without restarting Hermes.
        let googleServers = await Self.buildGoogleMcpServers()
        let customServers = await Self.buildCustomMcpServers()
        let sessionId = try await performSessionNew(extraMcpServers: googleServers + customServers)
        acpSessions[key] = sessionId
        return (sessionId, true)
    }

    /// Compact text replay of every turn before the final user turn — used to
    /// seed a fresh ACP session with a conversation that already has history
    /// (continued after an app restart or backend switch).
    ///
    /// Turn-aware: newest turns are kept whole (via `ChatTranscript.flattenTurn`,
    /// so tool calls/results ride along in bracketed form — much of a
    /// conversation's substance lives only in tool payloads), accumulating
    /// backwards until the budget is spent. Beats the old blind 12k-char tail
    /// slice, which cut mid-sentence and dropped everything but prose.
    private static let replayBudget = 30_000

    private static func historyReplay(turns: [ChatTurn]) -> String? {
        guard let lastUserIdx = turns.lastIndex(where: { $0.role == "user" }),
              lastUserIdx > 0 else { return nil }
        var kept: [String] = []
        var budget = replayBudget
        var omitted = 0
        // Attachments ride along automatically — flattenTurn appends each
        // turn's attachment section itself.
        for turn in turns[..<lastUserIdx].reversed() {
            guard let flat = ChatTranscript.flattenTurn(turn) else { continue }
            if flat.count <= budget {
                kept.append(flat)
                budget -= flat.count
            } else if kept.isEmpty {
                // A single monster turn — keep its tail so we return something.
                kept.append("…" + String(flat.suffix(budget)))
                budget = 0
            } else {
                omitted += 1
            }
        }
        guard !kept.isEmpty else { return nil }
        var out = kept.reversed().joined(separator: "\n\n")
        if omitted > 0 {
            out = "(\(omitted) earlier turn\(omitted == 1 ? "" : "s") omitted for length)\n\n" + out
        }
        return out
    }

    /// Idempotent: spawns `hermes acp` and runs the ACP handshake if we
    /// aren't already live. Throws if Hermes isn't installed or the
    /// handshake fails.
    func ensureConnected() async throws {
        if case .live = state { return }
        if case .connecting = state {
            // Race: a parallel caller is already in the middle of this. Spin
            // briefly. In practice Otto serializes turns so this is rare.
            while case .connecting = state {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            if case .live = state { return }
        }

        guard let binPath = HermesInstallation.binaryPath() else {
            throw HermesError.binaryNotFound
        }
        // The MCP server should already be running (Claude/Codex paths bring
        // it up too), but make sure — Hermes will try to connect to it.
        _ = OttoMCPServer.shared.ensureStarted()

        state = .connecting

        do {
            try launchHermes(binaryPath: binPath)
            try await performInitialize()
            // Sessions are created lazily per Otto conversation in
            // `ensureSession(for:)` — each gets its own ACP session (and a
            // freshly refreshed Google MCP Bearer token at creation time).
            state = .live
        } catch {
            disconnect()
            state = .disconnected(error)
            throw error
        }
    }

    /// Tear down the local `hermes acp` process + ACP session. Resolves any
    /// in-flight continuations with `HermesError.disconnected` so the chat
    /// UI doesn't hang on a never-arriving response.
    func disconnect() {
        stdoutReaderTask?.cancel()
        stdoutReaderTask = nil

        // Closing stdin signals EOF to `hermes acp`, which exits cleanly.
        try? stdinHandle?.close()
        stdinHandle = nil

        if let proc = hermesProcess, proc.isRunning {
            proc.terminate()
        }
        hermesProcess = nil

        // Best-effort cleanup of the session tmp dir.
        if let tmpDir = sessionTmpDir {
            try? FileManager.default.removeItem(at: tmpDir)
        }
        sessionTmpDir = nil

        // Resolve outstanding continuations with disconnected error.
        for (_, cont) in pendingResponses {
            cont.resume(throwing: HermesError.disconnected)
        }
        pendingResponses.removeAll()

        // Pending approvals: clear local state. Best-effort — stdin is closed,
        // so any unsent responses go nowhere, but the agent will be torn down
        // immediately anyway.
        pendingApprovals.removeAll()
        toolCallTitles.removeAll()
        toolCallInputs.removeAll()
        acpSessions.removeAll()
        activeTurns.removeAll()
        sessionManifestHash.removeAll()
        turnLastActivity.removeAll()

        state = .disconnected(nil)
    }

    // MARK: - Cancel turns

    /// Stop one conversation's in-flight prompt via ACP `session/cancel`,
    /// leaving its long-lived session (and conversation history) intact.
    /// Hermes sets its cancel event, aborts the turn, and resolves the
    /// pending `session/prompt` with `stopReason: cancelled` — which unblocks
    /// the `sendAndAwait` continuation in `streamChatWithTools` so that
    /// session is immediately ready for the next prompt. No-op when the
    /// conversation has no ACP session yet.
    func cancelTurn(sessionKey: UUID) {
        guard case .live = state, let sessionId = acpSessions[sessionKey] else { return }
        writeFrame(ACPParser.cancelNotification(sessionId: sessionId))
    }

    /// Legacy global stop — cancels every in-flight turn.
    func cancelActiveTurn() {
        guard case .live = state else { return }
        for sessionId in activeTurns.keys {
            writeFrame(ACPParser.cancelNotification(sessionId: sessionId))
        }
    }

    // MARK: - Approval resolution (called from UI)

    /// Resolve an approval card the user interacted with.
    ///
    /// `selectedOptionId` may be:
    ///   - `"__otto_allow"` / `"__otto_reject"` — synthetic ids from the UI;
    ///     we map them to the *actual* agent-sent option id by inspecting the
    ///     stored options' `kind` field.
    ///   - any other non-nil value — passed through as-is (for future direct
    ///     option-picker UIs).
    ///   - `nil` — the user dismissed without choosing; sent back as
    ///     `outcome: cancelled`.
    func resolveApproval(approvalId: String, selectedOptionId: String?) {
        guard let pending = pendingApprovals.removeValue(forKey: approvalId) else {
            // Already resolved — possibly auto-resolved by policy, or the
            // user clicked twice. Log and ignore.
            NSLog("[Hermes] resolveApproval: no pending approval for id=%@", approvalId)
            return
        }
        let resolvedOptionId: String?
        switch selectedOptionId {
        case "__otto_allow":
            resolvedOptionId = pending.options.first {
                $0.kind == "allow_once" || $0.kind == "allow_always"
            }?.optionId
        case "__otto_reject":
            resolvedOptionId = pending.options.first {
                $0.kind == "reject_once" || $0.kind == "reject_always"
            }?.optionId
        default:
            resolvedOptionId = selectedOptionId
        }
        let response = ACPParser.permissionResponse(
            id: pending.jsonRpcId,
            selectedOptionId: resolvedOptionId
        )
        writeFrame(response)
    }

    // MARK: - Local process launch

    private func launchHermes(binaryPath: String) throws {
        let tmpDir = try makeTempDir()
        sessionTmpDir = tmpDir

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = ["acp"]
        proc.currentDirectoryURL = tmpDir

        var env = ProcessInfo.processInfo.environment
        // Prepend common user-binary directories so anything `hermes acp`
        // shells out to (uvx, etc.) resolves. Same pattern Claude/Codex use.
        env["PATH"] = Self.augmentedPath(inheriting: env["PATH"])
        env["NO_COLOR"] = "1"
        proc.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        do {
            try proc.run()
        } catch {
            throw HermesError.launchFailed(error.localizedDescription)
        }

        hermesProcess = proc
        stdinHandle = stdin.fileHandleForWriting
        stderrBuffer = Data()

        // Drain stderr in the background. We keep a tail in case hermes
        // exits and we need to surface a reason.
        let stderrHandle = stderr.fileHandleForReading
        stderrHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            Task { [weak self] in
                await self?.appendStderr(data)
            }
        }

        // Start the stdout reader — drives the whole ACP event loop.
        let stdoutHandle = stdout.fileHandleForReading
        stdoutReaderTask = Task { [weak self] in
            await self?.readerLoop(handle: stdoutHandle)
        }
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("otto-hermes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Prepend common user-binary directories to the inherited PATH so any
    /// tool the agent shells out to via its built-in terminal (uvx, etc.)
    /// resolves. Same shape ClaudeCLIService uses.
    private static func augmentedPath(inheriting inherited: String?) -> String {
        let home = NSHomeDirectory()
        let prefix = [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin"
        ].joined(separator: ":")
        let tail = inherited ?? "/usr/bin:/bin"
        return "\(prefix):\(tail)"
    }

    private func appendStderr(_ data: Data) {
        stderrBuffer.append(data)
        // Cap to last ~16KB so we don't grow unbounded over long sessions.
        if stderrBuffer.count > 16_384 {
            stderrBuffer = stderrBuffer.suffix(16_384)
        }
    }

    private func stderrTail() -> String {
        return String(data: stderrBuffer, encoding: .utf8) ?? "(no stderr)"
    }

    // MARK: - ACP handshake

    private func performInitialize() async throws {
        let id = allocateRequestId()
        let request = ACPParser.initializeRequest(id: .int(id))
        let result: [String: Any]
        do {
            result = try await sendAndAwait(id: id, request: request)
        } catch {
            throw HermesError.initializeFailed(error.localizedDescription)
        }
        let version = result["protocolVersion"] as? Int ?? -1
        guard version == 1 else {
            throw HermesError.protocolMismatch(version)
        }
    }

    private func performSessionNew(extraMcpServers: [[String: Any]] = []) async throws -> String {
        let id = allocateRequestId()
        // `cwd` isn't meaningful to Otto — Otto's tools all flow through MCP,
        // and Otto doesn't expose fs/terminal capabilities, so the agent has
        // no reason to touch a working directory. Pass our session tmp dir
        // so any errant filesystem ops land in a contained spot.
        let cwd = sessionTmpDir?.path ?? "/tmp"
        let request = ACPParser.newSessionRequest(id: .int(id), cwd: cwd, mcpServers: extraMcpServers)
        let result: [String: Any]
        do {
            result = try await sendAndAwait(id: id, request: request)
        } catch {
            throw HermesError.sessionCreateFailed(error.localizedDescription)
        }
        guard let sessionId = result["sessionId"] as? String, !sessionId.isEmpty else {
            throw HermesError.sessionCreateFailed("Missing sessionId in response.")
        }
        return sessionId
    }

    // MARK: - Google MCP server injection

    /// Build the ACP `mcpServers` payload for whichever Google MCP integrations
    /// the user has connected (Calendar / Drive). These are Google-hosted
    /// streamable-HTTP MCP servers that authenticate with an OAuth Bearer
    /// token; we mint a fresh one from `GoogleAuthService` so the session
    /// starts with a valid grant. Mirrors the per-turn injection the Claude /
    /// Codex backends do, but expressed as ACP `HttpMcpServer` entries.
    ///
    /// Both servers share Otto's single Google OAuth token (same client, the
    /// extra scopes were granted when the user connected each card), so we
    /// fetch it once. If the token can't be refreshed, we skip injection
    /// entirely — Hermes still gets a working session with the `otto` tools,
    /// and the agent simply won't see calendar/drive tools this run.
    private static func buildGoogleMcpServers() async -> [[String: Any]] {
        let auth = GoogleAuthService.shared
        let wantCalendar = auth.hasCalendarMcpScopes()
        let wantDrive = auth.hasDriveScopes()
        guard wantCalendar || wantDrive else { return [] }

        let token: String
        do {
            token = try await auth.getValidAccessToken()
        } catch {
            NSLog("[Hermes] Google MCP skipped — token unavailable: %@", error.localizedDescription)
            return []
        }

        func httpServer(name: String, url: String) -> [String: Any] {
            return [
                "type": "http",
                "name": name,
                "url": url,
                "headers": [
                    ["name": "Authorization", "value": "Bearer \(token)"] as [String: Any]
                ]
            ]
        }

        var servers: [[String: Any]] = []
        if wantCalendar {
            servers.append(httpServer(
                name: "calendar",
                url: "https://calendarmcp.googleapis.com/mcp/v1"
            ))
        }
        if wantDrive {
            servers.append(httpServer(
                name: "drive",
                url: "https://drivemcp.googleapis.com/mcp/v1"
            ))
        }
        return servers
    }

    /// User-added custom MCP servers, expressed as ACP `mcpServers` entries.
    /// Secrets (env values / headers) resolve from Keychain at session-create
    /// time, and `.oauth` servers get a freshly minted Bearer token —
    /// mirroring how the Google servers refresh theirs above. Servers whose
    /// token can't be produced (needs sign-in) are skipped for this session.
    private static func buildCustomMcpServers() async -> [[String: Any]] {
        var out: [[String: Any]] = []
        for server in CustomMCPServersStore.shared.enabledServers() {
            guard let secrets = await CustomMCPServersStore.shared.effectiveSecrets(for: server) else { continue }
            out.append(CustomMCPServersStore.acpEntry(for: server, secrets: secrets))
        }
        return out
    }

    // MARK: - Reader loop

    private func readerLoop(handle: FileHandle) async {
        var leftover = ""
        while !Task.isCancelled {
            let chunk: Data
            do {
                chunk = try await readChunk(handle)
            } catch {
                break
            }
            if chunk.isEmpty { break }
            guard let s = String(data: chunk, encoding: .utf8) else { continue }
            leftover += s

            while let newlineRange = leftover.range(of: "\n") {
                let line = String(leftover[..<newlineRange.lowerBound])
                leftover = String(leftover[newlineRange.upperBound...])
                if line.isEmpty { continue }
                handleFrame(line: line)
            }
        }
        // Reader exited — connection closed. `Process.terminationStatus` is
        // an Objective-C accessor that throws NSInvalidArgumentException
        // ("task still running") when read before the process has actually
        // exited. Stdout closing doesn't guarantee the process has wound
        // down yet, so guard with isRunning and only read the status when
        // it's safe.
        let tail = stderrTail()
        NSLog("[Hermes] reader loop exited. stderr tail: %@", tail)
        let exitCode: Int32 = {
            guard let proc = hermesProcess, !proc.isRunning else { return -1 }
            return proc.terminationStatus
        }()
        let err: Error = HermesError.processExited(exitCode, tail)
        // Drain pending continuations so awaiters don't hang.
        for (_, cont) in pendingResponses {
            cont.resume(throwing: err)
        }
        pendingResponses.removeAll()
        if case .live = state {
            state = .disconnected(err)
        }
    }

    private func readChunk(_ handle: FileHandle) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let data = handle.availableData
                cont.resume(returning: data)
            }
        }
    }

    private func handleFrame(line: String) {
        guard let message = ACPParser.parse(line: line) else { return }
        switch message {
        case .response(let id, let result, let error):
            if case .int(let i) = id, let cont = pendingResponses.removeValue(forKey: i) {
                if let error = error {
                    cont.resume(throwing: HermesError.promptFailed("\(error.code) \(error.message)"))
                } else {
                    cont.resume(returning: result ?? [:])
                }
            }

        case .sessionUpdate(let sessionId, let update):
            touchActivity(sessionId)
            handleSessionUpdate(sessionId: sessionId, update)

        case .requestPermission(let id, let sessionId, let toolCallId, let options):
            touchActivity(sessionId)
            handlePermissionRequest(id: id, sessionId: sessionId, toolCallId: toolCallId, options: options)

        case .unknown:
            // Modeled-but-unhandled ACP shapes (plan updates, etc.) end up
            // here. We don't surface them — they're advisory.
            break
        }
    }

    /// Record sign-of-life for the stall watchdog. Frames with an empty
    /// sessionId (single-turn agents) touch the sole running turn.
    private func touchActivity(_ sessionId: String) {
        if let resolved = resolveTurnSession(sessionId) {
            turnLastActivity[resolved] = Date()
        } else if activeTurns.count == 1, let only = activeTurns.keys.first {
            turnLastActivity[only] = Date()
        }
    }

    /// Watchdog probe: aborts the turn (resuming its continuation with an
    /// error and best-effort cancelling agent-side) when the agent has been
    /// silent past `stallTimeout`. Returns true when the watchdog is done —
    /// either it fired, or the turn already ended.
    private func fireIfStalled(sessionId: String, promptId: Int) -> Bool {
        guard activeTurns[sessionId] != nil else { return true }
        // An approval card the user hasn't answered isn't a stall — they may
        // be away from the keyboard. Keep the clock parked while any is open.
        guard pendingApprovals.isEmpty else {
            turnLastActivity[sessionId] = Date()
            return false
        }
        let last = turnLastActivity[sessionId] ?? Date()
        guard Date().timeIntervalSince(last) > Self.stallTimeout else { return false }
        NSLog("[Hermes] turn stalled — no activity for %.0fs, aborting", Self.stallTimeout)
        writeFrame(ACPParser.cancelNotification(sessionId: sessionId))
        if let cont = pendingResponses.removeValue(forKey: promptId) {
            cont.resume(throwing: HermesError.promptFailed(
                "No agent activity for \(Int(Self.stallTimeout))s — turn aborted. Hermes may be stalled; try again, or restart it from Settings → Agent."
            ))
        }
        return true
    }

    /// Resolve which in-flight turn an agent frame belongs to. Frames carry
    /// the ACP sessionId; if an agent omits it and exactly one turn is
    /// running, route there (the pre-multi-session behavior).
    private func resolveTurnSession(_ sessionId: String) -> String? {
        if !sessionId.isEmpty {
            return activeTurns[sessionId] != nil ? sessionId : nil
        }
        return activeTurns.count == 1 ? activeTurns.keys.first : nil
    }

    private func handleSessionUpdate(sessionId rawSessionId: String, _ update: ACPParser.SessionUpdate) {
        guard let sid = resolveTurnSession(rawSessionId) else { return }
        switch update {
        case .agentMessageChunk(let text):
            guard !text.isEmpty else { return }
            activeTurns[sid]?.assistantText += text
            appendTurnText(text, session: sid)
            if let onDelta = activeTurns[sid]?.onDelta {
                let captured = text
                Task { @MainActor in onDelta(captured) }
            }
            if let onEvent = activeTurns[sid]?.onEvent {
                let captured = text
                Task { @MainActor in onEvent(.partialText(captured)) }
            }

        case .agentThoughtChunk(let text):
            guard !text.isEmpty else { return }
            if let onEvent = activeTurns[sid]?.onEvent {
                let captured = text
                Task { @MainActor in onEvent(.thinkingDelta(captured)) }
            }

        case .toolCall(let toolCallId, let title, _, let rawInput):
            // Hermes announces MCP tools as `mcp__otto__<tool>` — strip the
            // prefix so the UI (and ToolApprovalPolicy) sees the bare name.
            let name = OttoTools.canonicalToolName(title)
            toolCallTitles[toolCallId] = name
            let input = rawInput ?? [:]
            toolCallInputs[toolCallId] = input
            activeTurns[sid]?.turnBlocks.append(
                .toolUse(id: toolCallId, name: name, input: JSONValue.from(any: input))
            )
            if let onEvent = activeTurns[sid]?.onEvent {
                let id = toolCallId
                Task { @MainActor in onEvent(.toolCall(id: id, name: name, input: input)) }
            }

        case .toolCallUpdate(let toolCallId, let status, let contentSummary, let isError, let rawInput):
            // Some agents deliver the argument object only on updates —
            // backfill our records (and the persisted toolUse block) so the
            // preview-card path has real inputs.
            if let rawInput, !rawInput.isEmpty {
                toolCallInputs[toolCallId] = rawInput
                patchToolUseBlock(id: toolCallId, input: rawInput, session: sid)
            }
            // Only fire `toolResult` for terminal statuses (completed/failed).
            // Intermediate "in_progress" updates exist but Otto's UI doesn't
            // model partial tool progress yet.
            guard status == "completed" || status == "failed" else { return }
            let name = toolCallTitles[toolCallId] ?? "tool"
            // attach_item_preview: if the agent never delivered rawInput,
            // recover {type, id} from the executor's result line so the saved
            // toolUse block can rebuild the preview card on session reload.
            if OttoTools.isAttachItemPreview(name),
               (toolCallInputs[toolCallId] ?? [:]).isEmpty,
               let parsed = OttoTools.parsePreviewResult(contentSummary) {
                let recovered: [String: Any] = [
                    "type": parsed.typeString,
                    "id": parsed.id.uuidString
                ]
                toolCallInputs[toolCallId] = recovered
                patchToolUseBlock(id: toolCallId, input: recovered, session: sid)
            }
            activeTurns[sid]?.turnBlocks.append(
                .toolResult(toolUseId: toolCallId, content: contentSummary, isError: isError)
            )
            if let onEvent = activeTurns[sid]?.onEvent {
                let id = toolCallId
                let summary = contentSummary
                let err = isError
                let toolName = name
                Task { @MainActor in
                    onEvent(.toolResult(id: id, name: toolName, summary: summary, isError: err))
                }
            }

        case .unknown:
            break
        }
    }

    /// Append streamed assistant text to a turn's block log, merging into
    /// the trailing text block so a text run isn't split per delta.
    private func appendTurnText(_ text: String, session sid: String) {
        guard var context = activeTurns[sid] else { return }
        if case .text(let existing)? = context.turnBlocks.last {
            context.turnBlocks[context.turnBlocks.count - 1] = .text(existing + text)
        } else {
            context.turnBlocks.append(.text(text))
        }
        activeTurns[sid] = context
    }

    /// Rewrite the input of an already-logged toolUse block (rawInput arrived
    /// on a later update, or was recovered from the tool result).
    private func patchToolUseBlock(id: String, input: [String: Any], session sid: String) {
        guard var context = activeTurns[sid] else { return }
        guard let idx = context.turnBlocks.lastIndex(where: { block in
            if case .toolUse(let blockId, _, _) = block { return blockId == id }
            return false
        }), case .toolUse(_, let name, _) = context.turnBlocks[idx] else { return }
        context.turnBlocks[idx] = .toolUse(id: id, name: name, input: JSONValue.from(any: input))
        activeTurns[sid] = context
    }

    private func handlePermissionRequest(
        id: ACPParser.JSONRPCID,
        sessionId: String,
        toolCallId: String,
        options: [ACPParser.PermissionOption]
    ) {
        let toolName = toolCallTitles[toolCallId] ?? "tool"
        let policy = ToolApprovalPolicy.shared.decision(for: toolName)

        // Auto-resolve if the user has already decided on this tool.
        switch policy {
        case .alwaysAllow:
            if let opt = options.first(where: { $0.kind == "allow_once" || $0.kind == "allow_always" }) {
                let response = ACPParser.permissionResponse(id: id, selectedOptionId: opt.optionId)
                writeFrame(response)
                return
            }
        case .alwaysDeny:
            if let opt = options.first(where: { $0.kind == "reject_once" || $0.kind == "reject_always" }) {
                let response = ACPParser.permissionResponse(id: id, selectedOptionId: opt.optionId)
                writeFrame(response)
                return
            }
        case .askEachTime:
            break
        }

        // No auto-policy — store for user resolution and emit the event to
        // the turn the request belongs to.
        let approvalKey = approvalKeyFor(id: id)
        pendingApprovals[approvalKey] = PendingApproval(
            jsonRpcId: id,
            options: options,
            toolName: toolName
        )
        if let sid = resolveTurnSession(sessionId), let onEvent = activeTurns[sid]?.onEvent {
            let key = approvalKey
            let name = toolName
            let summary = "ask permission to run \(toolName)"
            Task { @MainActor in
                onEvent(.approvalRequest(id: key, toolName: name, argsSummary: summary))
            }
        }
    }

    /// Stable string key for an ACP request id so the UI can round-trip the
    /// approval id through `ChatEvent.approvalRequest(id: String, …)` and
    /// hand it back to `resolveApproval(approvalId:…)` later.
    private func approvalKeyFor(id: ACPParser.JSONRPCID) -> String {
        switch id {
        case .int(let i):    return "int:\(i)"
        case .string(let s): return "str:\(s)"
        }
    }

    // MARK: - JSON-RPC plumbing

    private func allocateRequestId() -> Int {
        let id = nextRequestId
        nextRequestId += 1
        return id
    }

    /// Send a JSON-RPC request keyed by integer `id`, return its result.
    /// Caller maps thrown errors to the right `HermesError.*` case.
    private func sendAndAwait(id: Int, request: [String: Any]) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { cont in
            pendingResponses[id] = cont
            writeFrame(request)
        }
    }

    /// Encode + write one JSON-RPC frame to stdin. Newline-delimited.
    private func writeFrame(_ frame: [String: Any]) {
        guard let stdin = stdinHandle else {
            NSLog("[Hermes] writeFrame: no stdin (disconnected)")
            return
        }
        guard var data = try? JSONSerialization.data(withJSONObject: frame) else {
            NSLog("[Hermes] writeFrame: failed to serialize frame")
            return
        }
        data.append(0x0A)
        do {
            try stdin.write(contentsOf: data)
        } catch {
            NSLog("[Hermes] writeFrame: stdin write failed: %@", error.localizedDescription)
        }
    }
}
