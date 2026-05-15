import Foundation

/// Hermes backend — drives a long-lived `hermes acp` process running locally
/// on the same Mac as Otto. Unlike `ClaudeCLIService` / `CodexCLIService`,
/// which are stateless and spawn a fresh CLI per turn, this actor owns one
/// ACP session for the lifetime of the Otto run. The agent keeps its
/// conversation state in-memory, so every turn after the first is just a
/// `session/prompt` write into the existing stdin.
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
        case live(sessionId: String)
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

    /// `toolCallId` → human-readable title, captured from the `tool_call`
    /// notification so we can label later approval requests and tool-result
    /// chips. The same title is used as the `ToolApprovalPolicy` lookup key.
    private var toolCallTitles: [String: String] = [:]

    /// Per-turn event sinks. Set at the start of `streamChatWithTools`,
    /// cleared at the end. Otto serializes turns, so a single pair is fine.
    private var currentOnDelta: (@MainActor (String) -> Void)?
    private var currentOnEvent: (@MainActor (ChatEvent) -> Void)?

    /// Accumulator for the current turn's assistant text — fed by every
    /// `agent_message_chunk` and emitted as `.text(...)` once the prompt
    /// response arrives with a `stopReason`.
    private var currentAssistantText: String = ""

    private init() {}

    // MARK: - Public API (mirrors ClaudeCLIService.streamChatWithTools)

    func streamChatWithTools(
        turns: [ChatTurn],
        systemPrompt: String,
        tools: [[String: Any]],         // ignored — tools come via MCP
        executor: OttoToolExecutor,    // ignored — executor lives MCP-side
        onDelta: @escaping @MainActor (String) -> Void,
        onEvent: @escaping @MainActor (ChatEvent) -> Void
    ) async throws -> [ChatTurn] {

        try await ensureConnected()
        guard case .live(let sessionId) = state else {
            throw HermesError.disconnected
        }

        // Build the prompt for this turn. On a fresh session, prepend the
        // system prompt to the first user turn (ACP doesn't have a separate
        // system-prompt slot — same compromise CodexCLIService makes).
        let lastUserText = turns.reversed().first { $0.role == "user" }
            .flatMap { turn -> String? in
                let text = turn.blocks.compactMap { block -> String? in
                    if case .text(let s) = block { return s }
                    return nil
                }.joined(separator: "\n\n")
                return text.isEmpty ? nil : text
            } ?? ""

        var combined: String
        if turns.filter({ $0.role == "user" }).count == 1 && !systemPrompt.isEmpty {
            combined = "[system]\n\(systemPrompt)\n\n\(lastUserText)"
        } else {
            combined = lastUserText
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

        // Install per-turn sinks and reset the assistant accumulator.
        currentOnDelta = onDelta
        currentOnEvent = onEvent
        currentAssistantText = ""
        // Guarantee sinks get cleared even on throw, so a later turn that
        // reuses them isn't routed to a stale closure.
        defer {
            currentOnDelta = nil
            currentOnEvent = nil
            currentAssistantText = ""
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
        do {
            _ = try await sendAndAwait(id: promptId, request: request)
        } catch {
            throw HermesError.promptFailed(error.localizedDescription)
        }

        // Emit the final assistant text once at end-of-turn, mirroring how
        // ClaudeCLIService caps the stream with a `.text(...)` event.
        let finalText = currentAssistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalText.isEmpty {
            let captured = finalText
            await MainActor.run { onEvent(.text(captured)) }
        }

        var updated = turns
        updated.append(ChatTurn(role: "assistant", blocks: [.text(currentAssistantText)]))
        return updated
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
            let sessionId = try await performSessionNew()
            state = .live(sessionId: sessionId)
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

        state = .disconnected(nil)
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

    private func performSessionNew() async throws -> String {
        let id = allocateRequestId()
        // `cwd` isn't meaningful to Otto — Otto's tools all flow through MCP,
        // and Otto doesn't expose fs/terminal capabilities, so the agent has
        // no reason to touch a working directory. Pass our session tmp dir
        // so any errant filesystem ops land in a contained spot.
        let cwd = sessionTmpDir?.path ?? "/tmp"
        let request = ACPParser.newSessionRequest(id: .int(id), cwd: cwd)
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

        case .sessionUpdate(let update):
            handleSessionUpdate(update)

        case .requestPermission(let id, _, let toolCallId, let options):
            handlePermissionRequest(id: id, toolCallId: toolCallId, options: options)

        case .unknown:
            // Modeled-but-unhandled ACP shapes (plan updates, etc.) end up
            // here. We don't surface them — they're advisory.
            break
        }
    }

    private func handleSessionUpdate(_ update: ACPParser.SessionUpdate) {
        switch update {
        case .agentMessageChunk(let text):
            guard !text.isEmpty else { return }
            currentAssistantText += text
            if let onDelta = currentOnDelta {
                let captured = text
                Task { @MainActor in onDelta(captured) }
            }
            if let onEvent = currentOnEvent {
                let captured = text
                Task { @MainActor in onEvent(.partialText(captured)) }
            }

        case .agentThoughtChunk(let text):
            guard !text.isEmpty else { return }
            if let onEvent = currentOnEvent {
                let captured = text
                Task { @MainActor in onEvent(.thinkingDelta(captured)) }
            }

        case .toolCall(let toolCallId, let title, _):
            toolCallTitles[toolCallId] = title
            if let onEvent = currentOnEvent {
                let id = toolCallId
                let name = title
                Task { @MainActor in onEvent(.toolCall(id: id, name: name, input: [:])) }
            }

        case .toolCallUpdate(let toolCallId, let status, let contentSummary, let isError):
            // Only fire `toolResult` for terminal statuses (completed/failed).
            // Intermediate "in_progress" updates exist but Otto's UI doesn't
            // model partial tool progress yet.
            guard status == "completed" || status == "failed" else { return }
            let name = toolCallTitles[toolCallId] ?? "tool"
            if let onEvent = currentOnEvent {
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

    private func handlePermissionRequest(
        id: ACPParser.JSONRPCID,
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

        // No auto-policy — store for user resolution and emit the event.
        let approvalKey = approvalKeyFor(id: id)
        pendingApprovals[approvalKey] = PendingApproval(
            jsonRpcId: id,
            options: options,
            toolName: toolName
        )
        if let onEvent = currentOnEvent {
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
