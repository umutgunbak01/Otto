import Foundation

/// Codex backend — shells out to the `codex` CLI bundled inside Codex.app.
///
/// Mirrors `ClaudeCLIService`'s shape so the routing layer can swap backends
/// behind a flag without changing the call site:
///   - Same `streamChatWithTools` signature.
///   - Same MCP-server bridge: Otto's in-process MCP server is exposed to the
///     CLI via `nc -U <socket>`.
///   - Same screenshot-handoff pattern (copy `pendingScreenshotPath` into the
///     session tmpDir before launch).
///
/// Auth: the CLI reads `~/.codex/auth.json` itself; we just verify the file
/// is present (`CodexAuthService.isCLISignedIn`) — or that an API key is
/// set in Settings — and surface a clean error if neither is true. When an
/// API key is present, it's passed via `OPENAI_API_KEY` so the CLI bypasses
/// its stored OAuth credentials.
///
/// Streaming caveat: `codex exec --json` emits message-level events
/// (`item.completed` with `agent_message` items), not per-token deltas. The
/// assistant's full text arrives in one shot at end-of-turn, so on-screen the
/// reply will appear all-at-once instead of streaming word-by-word the way
/// Claude does. Voice mode still gets the full text into its TTS chunker.
actor CodexCLIService {
    static let shared = CodexCLIService()

    /// Candidate paths for the codex binary, probed in order. The desktop app
    /// bundles the CLI under its Resources dir; the npm/Homebrew installs
    /// land in the usual /opt/homebrew or /usr/local locations.
    private static let candidatePaths: [String] = [
        "/Applications/Codex.app/Contents/Resources/codex",
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
        "/usr/bin/codex"
    ]
    private var resolvedPath: String?

    /// Live CLI subprocesses keyed by the conversation (`sessionKey`) that
    /// launched them, so Stop can terminate the right one when several
    /// conversations run concurrently. Entries are cleared when their turn
    /// ends. Access is serialized by the actor.
    private var activeProcesses: [UUID: Process] = [:]

    /// Abort a turn when the CLI produces no stdout for this long — a wedged
    /// subprocess otherwise hangs the turn forever (waitUntilExit has no
    /// deadline). Generous: silent reasoning stretches are legitimate.
    private static let stallTimeout: TimeInterval = 300

    /// `nc` is used as a stdio ↔ Unix-socket bridge so the Codex CLI can talk
    /// to Otto's MCP server (which lives at a Unix socket path) without us
    /// implementing the streamable-HTTP MCP transport.
    private let netcatPath = "/usr/bin/nc"

    private init() {}

    enum CLIError: LocalizedError {
        case notFound
        case notSignedIn
        case apiKeyRejected
        case launchFailed(String)
        case crashed(Int32, String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .notFound:
                return "Codex CLI not found. Install the Codex desktop app from openai.com/codex."
            case .notSignedIn:
                return "Not signed in to Codex. Open the Codex app, run `codex login`, or paste an OpenAI API key in Settings."
            case .apiKeyRejected:
                return "Your OpenAI API key was rejected. Check Settings → Agent."
            case .launchFailed(let m): return "Failed to launch codex CLI: \(m)"
            case .crashed(let code, let stderr):
                return "codex CLI exited \(code): \(stderr)"
            case .timeout: return "codex CLI timed out."
            }
        }
    }

    // MARK: - Public API (mirrors ClaudeCLIService.streamChatWithTools)

    func streamChatWithTools(
        sessionKey: UUID,
        turns: [ChatTurn],
        systemPrompt: String,
        tools: [[String: Any]],        // ignored — Codex picks up tools via MCP
        executor: OttoToolExecutor,    // ignored — MCP path handles execution
        onDelta: @escaping @MainActor (String) -> Void,
        onEvent: @escaping @MainActor (ChatEvent) -> Void
    ) async throws -> [ChatTurn] {

        let turnStart = Date()
        let authMode = CodexAuthService.shared.effectiveAuthMode()
        guard authMode != .none else {
            throw CLIError.notSignedIn
        }

        let bin = try resolveCodexBinary()
        let combined = combinedPrompt(systemPrompt: systemPrompt, turns: turns)
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Screen-vision handoff: IntentRouter stashes a PNG path in AppState;
        // copy it into the CLI's cwd as `screenshot.png` so Codex's built-in
        // file tools can load it. Then clear so the next turn doesn't replay
        // a stale screenshot.
        if let state = OttoMCPServer.shared.appState {
            let capturedPath: String? = await MainActor.run {
                let path = state.pendingScreenshotPath
                state.pendingScreenshotPath = nil
                return path
            }
            if let capturedPath = capturedPath {
                let src = URL(fileURLWithPath: capturedPath)
                let dst = tmpDir.appendingPathComponent("screenshot.png")
                do {
                    try FileManager.default.copyItem(at: src, to: dst)
                    try? FileManager.default.removeItem(at: src)
                    NSLog("[CodexCLI] screenshot copied into session tmpDir")
                } catch {
                    NSLog("[CodexCLI] failed to stage screenshot: \(error.localizedDescription)")
                }
            }
        }

        // Data-workspace handoff: export every Otto tab as a grep-able
        // CSV/JSONL snapshot into the CLI's cwd. The system prompt's
        // "Data workspace" section advertises the files, so bulk questions
        // become one Grep instead of a chain of search_items round trips.
        if let state = OttoMCPServer.shared.appState {
            let snap = await MainActor.run { AgentWorkspaceExporter.snapshot(from: state) }
            AgentWorkspaceExporter.write(snap, into: tmpDir)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.currentDirectoryURL = tmpDir

        var args: [String] = [
            "exec",
            "--json",
            "--ephemeral",
            "--skip-git-repo-check",
            "--ignore-user-config",
            "--dangerously-bypass-approvals-and-sandbox",
            "--model", AgentService.Codex.getModel(),
            "-C", tmpDir.path
        ]
        // Wire Otto's MCP server. Codex accepts `-c key=tomlvalue` overrides,
        // so we inject an `mcp_servers.otto` entry that launches `nc -U` and
        // points it at our Unix socket. Both Claude and Codex consume the
        // same MCP server, so the tool surface is identical.
        // ensureStarted is idempotent — the second call is a cheap one-shot
        // retry if the first bind failed.
        if let socketPath = OttoMCPServer.shared.ensureStarted() ?? OttoMCPServer.shared.ensureStarted() {
            args.append(contentsOf: [
                "-c", "mcp_servers.otto.command=\"\(netcatPath)\"",
                "-c", "mcp_servers.otto.args=[\"-U\",\"\(socketPath)\"]"
            ])
        } else {
            NSLog("[CodexCLI] MCP server unavailable — Otto tools disabled this turn")
            await MainActor.run {
                onEvent(.notice("Otto's tools are unavailable this turn — the internal MCP server failed to start, so this reply can't read or change your data. Web tools still work."))
            }
        }

        // Also inject each user-registered Supabase project as a
        // streamable-HTTP MCP server. Codex won't accept secrets inline in
        // the TOML; it reads the bearer token from an env var at runtime,
        // so we pass the name here and set the matching env entry below
        // (before assigning to `proc.environment`).
        var env = ProcessInfo.processInfo.environment
        env["NO_COLOR"] = "1"
        // When the user has set an OpenAI API key in Otto's Settings,
        // forward it to the CLI. The CLI prefers this over its stored
        // OAuth credentials, so the subscription path is bypassed.
        if authMode == .apiKey, let key = CodexAuthService.shared.apiKey() {
            env["OPENAI_API_KEY"] = key
        }
        // Google Drive / Calendar MCP — same injection shape as Supabase
        // below, just with the bearer token sourced from GoogleAuthService
        // instead of a stored PAT. Each guarded by its own opt-in flag.
        // Token refreshes lazily within a 5-minute expiry buffer; skip
        // the server for this turn if it isn't fetchable.
        if GoogleAuthService.shared.hasDriveScopes() {
            do {
                let driveToken = try await GoogleAuthService.shared.getValidAccessToken()
                let envVarName = "OTTO_DRIVE_BEARER_TOKEN"
                args.append(contentsOf: [
                    "-c", "mcp_servers.drive.url=\"https://drivemcp.googleapis.com/mcp/v1\"",
                    "-c", "mcp_servers.drive.transport=\"streamable_http\"",
                    "-c", "mcp_servers.drive.bearer_token_env_var=\"\(envVarName)\""
                ])
                env[envVarName] = driveToken
            } catch {
                NSLog("[CodexCLI] Drive MCP skipped — token unavailable: %@", error.localizedDescription)
            }
        }
        if GoogleAuthService.shared.hasCalendarMcpScopes() {
            do {
                let calToken = try await GoogleAuthService.shared.getValidAccessToken()
                let envVarName = "OTTO_CALENDAR_BEARER_TOKEN"
                args.append(contentsOf: [
                    "-c", "mcp_servers.calendar.url=\"https://calendarmcp.googleapis.com/mcp/v1\"",
                    "-c", "mcp_servers.calendar.transport=\"streamable_http\"",
                    "-c", "mcp_servers.calendar.bearer_token_env_var=\"\(envVarName)\""
                ])
                env[envVarName] = calToken
            } catch {
                NSLog("[CodexCLI] Calendar MCP skipped — token unavailable: %@", error.localizedDescription)
            }
        }
        // Tally — same shape as Supabase below, single shared key from
        // TallyService.apiKey() instead of a per-project PAT.
        if let tallyKey = TallyService.shared.apiKey(), !tallyKey.isEmpty {
            let envVarName = "OTTO_TALLY_BEARER_TOKEN"
            args.append(contentsOf: [
                "-c", "mcp_servers.tally.url=\"https://api.tally.so/mcp\"",
                "-c", "mcp_servers.tally.transport=\"streamable_http\"",
                "-c", "mcp_servers.tally.bearer_token_env_var=\"\(envVarName)\""
            ])
            env[envVarName] = tallyKey
        }
        for project in SupabaseProjectsService.shared.allProjects() {
            guard let pat = SupabaseProjectsService.shared.pat(for: project.id) else { continue }
            let envVarName = "OTTO_SUPABASE_PAT_\(project.id.uuidString.replacingOccurrences(of: "-", with: ""))"
            let serverKey = "supabase_\(project.slug)"
            let url = "https://mcp.supabase.com/mcp?project_ref=\(project.projectRef)"
            args.append(contentsOf: [
                "-c", "mcp_servers.\(serverKey).url=\"\(url)\"",
                "-c", "mcp_servers.\(serverKey).transport=\"streamable_http\"",
                "-c", "mcp_servers.\(serverKey).bearer_token_env_var=\"\(envVarName)\""
            ])
            env[envVarName] = pat
        }
        // User-added custom MCP servers. `effectiveSecrets` mints a fresh
        // OAuth Bearer for `.oauth` servers (nil = needs sign-in, skip);
        // `codexArgs` returns [] for transports Codex can't drive (SSE) —
        // skip those with a log line rather than failing the turn.
        for server in CustomMCPServersStore.shared.enabledServers() {
            guard let secrets = await CustomMCPServersStore.shared.effectiveSecrets(for: server) else { continue }
            let overrides = CustomMCPServersStore.codexArgs(for: server, secrets: secrets, env: &env)
            if overrides.isEmpty {
                NSLog("[CodexCLI] custom MCP server %@ skipped — SSE transport unsupported by Codex", server.slug)
            } else {
                args.append(contentsOf: overrides)
            }
        }

        proc.arguments = args
        env["PATH"] = Self.augmentedPath(inheriting: env["PATH"])
        proc.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        do {
            try proc.run()
        } catch {
            throw CLIError.launchFailed(error.localizedDescription)
        }

        // Track the live subprocess so Stop can terminate it; clear on exit.
        activeProcesses[sessionKey] = proc
        defer { activeProcesses[sessionKey] = nil }

        // Feed prompt on stdin, then close — signals EOF so the CLI proceeds.
        if let data = combined.data(using: .utf8) {
            try? stdinPipe.fileHandleForWriting.write(contentsOf: data)
        }
        try? stdinPipe.fileHandleForWriting.close()

        var stderrBuffer = Data()
        let stderrHandle = stderrPipe.fileHandleForReading
        stderrHandle.readabilityHandler = { h in
            let chunk = h.availableData
            if chunk.isEmpty { h.readabilityHandler = nil; return }
            stderrBuffer.append(chunk)
        }
        // Guarantee the readabilityHandler is cleared even if parseStreamJSON
        // throws partway through. Otherwise the dispatch source can leak
        // until process exit on the error path.
        defer { stderrHandle.readabilityHandler = nil }

        // Stall watchdog — waitUntilExit has no deadline, so a wedged CLI
        // otherwise pins this turn until the user hits Stop. Touched on every
        // stdout chunk; silence past the timeout kills the subprocess and the
        // turn throws `.timeout` instead of `.crashed`.
        let clock = StallClock()
        let watchdog = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if Task.isCancelled { return }
                if clock.secondsSinceTouch() > Self.stallTimeout {
                    clock.markStalled()
                    proc.terminate()
                    return
                }
            }
        }
        defer { watchdog.cancel() }

        let parsed = try await parseStreamJSON(
            stdout: stdoutPipe.fileHandleForReading,
            clock: clock,
            onDelta: onDelta,
            onEvent: onEvent
        )

        proc.waitUntilExit()

        if clock.wasStalled {
            throw CLIError.timeout
        }
        if proc.terminationStatus != 0 {
            let msg = String(data: stderrBuffer, encoding: .utf8) ?? "(no stderr)"
            NSLog("[CodexCLI] exited \(proc.terminationStatus): \(msg)")
            if authMode == .apiKey && Self.looksLikeBadAPIKey(msg) {
                throw CLIError.apiKeyRejected
            }
            throw CLIError.crashed(proc.terminationStatus, msg)
        }

        // Text segments finalize per completed `agent_message` item (each
        // one already emitted `.text`), so tool chips interleave with
        // bubbles the way Hermes renders them. `unfinalized` is only
        // non-empty on degenerate streams — flush it so nothing is lost.
        var blocks = parsed.blocks
        let remainder = parsed.unfinalized.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remainder.isEmpty {
            blocks.append(.text(remainder))
            let captured = remainder
            await MainActor.run { onEvent(.text(captured)) }
        }
        if blocks.isEmpty {
            blocks = [.text(parsed.text)]
        }

        var updated = turns
        // Persist the full block log (text + toolUse + toolResult) — same as
        // the Hermes path — so reopened sessions rebuild tool chips, preview
        // cards, and media previews instead of just the prose.
        let stats = TurnStats(
            durationMs: Int(Date().timeIntervalSince(turnStart) * 1000),
            backend: AgentBackend.codex.rawValue,
            model: AgentService.Codex.getModel(),
            inputTokens: parsed.usage?.input,
            outputTokens: parsed.usage?.output,
            costUSD: nil
        )
        updated.append(ChatTurn(role: "assistant", blocks: blocks, stats: stats))
        return updated
    }

    /// Terminate one conversation's in-flight CLI subprocess, if any (the
    /// Stop button reaches this via `AgentService.cancelRun`). Killing the
    /// process closes its stdout, which unblocks the streaming reader and
    /// unwinds that turn — other conversations' runs are untouched.
    func cancelRun(sessionKey: UUID) {
        activeProcesses[sessionKey]?.terminate()
    }

    /// Legacy global stop — terminates every in-flight subprocess.
    func cancelActiveRun() {
        for proc in activeProcesses.values { proc.terminate() }
    }

    // MARK: - Helpers

    /// Prepend common user-binary directories to the inherited PATH so the
    /// agent's built-in shell tool can find binaries the user installed via
    /// install scripts, Homebrew, etc. — `genmedia`, `gh`, `jq`, `brew`,
    /// anything in `~/.local/bin`, etc. Without this, Otto's spawned
    /// subprocess only sees `/bin:/usr/bin:/usr/ucb:/usr/local/bin` (the
    /// macOS Launch Services default), which excludes virtually every
    /// user-installed tool the agent might want to shell out to.
    private static func augmentedPath(inheriting inherited: String?) -> String {
        let home = NSHomeDirectory()
        let prefix = [
            "\(home)/.genmedia/bin",   // genmedia CLI installer's default
            "\(home)/.local/bin",      // common user-bin convention
            "/opt/homebrew/bin",       // Apple Silicon Homebrew
            "/usr/local/bin"           // Intel Homebrew + generic /usr/local
        ].joined(separator: ":")
        let tail = inherited ?? "/usr/bin:/bin"
        return "\(prefix):\(tail)"
    }

    /// Heuristic match against the CLI's stderr to pick out the
    /// "your API key is bad" failure shape, so the user gets a clear
    /// pointer back to Settings instead of a raw subprocess dump.
    private static func looksLikeBadAPIKey(_ stderr: String) -> Bool {
        let needle = stderr.lowercased()
        return needle.contains("invalid api key")
            || needle.contains("invalid_api_key")
            || needle.contains("incorrect api key")
            || needle.contains("unauthorized")
            || needle.contains("401")
    }

    private func resolveCodexBinary() throws -> String {
        if let p = resolvedPath { return p }
        for p in Self.candidatePaths where FileManager.default.isExecutableFile(atPath: p) {
            resolvedPath = p
            return p
        }
        throw CLIError.notFound
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("otto-codex-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Codex `exec` doesn't have a `--system-prompt` flag the way `claude -p`
    /// does. We prepend the system prompt as a `[system]` block followed by
    /// the shared `ChatTranscript` flatten (role prefixes + compact bracketed
    /// tool calls/results, so follow-up turns keep the substance that lives
    /// in tool payloads), then pipe everything in on stdin.
    private func combinedPrompt(systemPrompt: String, turns: [ChatTurn]) -> String {
        var out: [String] = []
        let trimmedSystem = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSystem.isEmpty {
            out.append("[system]\n\(trimmedSystem)")
        }
        let history = ChatTranscript.flatten(turns)
        if !history.isEmpty {
            out.append(history)
        }
        return out.joined(separator: "\n\n")
    }

    /// Token usage reported by the terminal `turn.completed` event.
    struct StreamUsage {
        var input: Int
        var output: Int
    }

    /// Everything one CLI run produced: the concatenated message text (voice
    /// TTS + fallback), the ordered canonical blocks (text segments + tool
    /// calls + tool results, mirroring what Hermes persists), any text
    /// that never got folded into a block (degenerate streams only), and
    /// usage stats for turn telemetry.
    private struct ParsedTurn {
        let text: String
        let blocks: [ChatBlock]
        let unfinalized: String
        var usage: StreamUsage?
    }

    /// Mutable parse state threaded through `parseEvent` line by line.
    private struct ParserState {
        /// Most recent agent_reasoning summary, so `item.updated` bursts can
        /// emit just the delta rather than re-sending the full running text.
        var lastReasoning = ""
        /// Tool item ids whose `item.started` already produced a `.toolCall`,
        /// so `item.completed` knows whether to backfill the call event
        /// (some codex versions only emit `item.completed` for fast tools).
        var startedToolItems: Set<String> = []
    }

    /// Parse JSONL events from `codex exec --json`. Emitted events:
    ///   - `thread.started` — session metadata, no-op
    ///   - `turn.started` — agent loop iteration begins, no-op
    ///   - `item.started` — tool items (`mcp_tool_call`, `command_execution`,
    ///     `web_search`) surface as `.toolCall` so the UI shows a pulsing
    ///     chip while the tool runs, exactly like Hermes
    ///   - `item.completed` — wraps one completed item:
    ///       - `agent_message` → assistant text (delivered in one shot —
    ///         see streaming caveat in the actor doc — emitted as
    ///         `.partialText` + `.text` so the segment finalizes in place
    ///         and tool chips interleave between bubbles)
    ///       - tool items → `.toolResult` settles the matching chip
    ///       - `agent_reasoning` → emitted as `.thinkingDelta` so the
    ///         user can follow Codex's chain of thought
    ///   - `item.updated` — incremental updates while an item is forming;
    ///     `agent_reasoning` updates stream a growing summary which makes
    ///     a decent "thinking…" indicator even though Codex doesn't
    ///     stream the final agent_message per-token.
    ///   - `turn.completed` — token usage, captured for turn telemetry
    private func parseStreamJSON(
        stdout: FileHandle,
        clock: StallClock? = nil,
        onDelta: @escaping @MainActor (String) -> Void,
        onEvent: @escaping @MainActor (ChatEvent) -> Void
    ) async throws -> ParsedTurn {
        var textBuffer = ""
        var leftover = ""
        var blocks: [ChatBlock] = []
        var unfinalized = ""
        var state = ParserState()
        var usage: StreamUsage?

        while true {
            let chunk = try await readChunk(from: stdout)
            if chunk.isEmpty { break }
            clock?.touch()
            guard let s = String(data: chunk, encoding: .utf8) else { continue }
            leftover += s
            while let newlineRange = leftover.range(of: "\n") {
                let line = String(leftover[..<newlineRange.lowerBound])
                leftover = String(leftover[newlineRange.upperBound...])
                if line.isEmpty { continue }
                if let parsed = parseEvent(line, state: &state) {
                    if !parsed.textDelta.isEmpty {
                        textBuffer += parsed.textDelta
                        unfinalized += parsed.textDelta
                        let captured = parsed.textDelta
                        await MainActor.run { onDelta(captured) }
                    }
                    blocks.append(contentsOf: parsed.blocks)
                    if parsed.finalizedSegment { unfinalized = "" }
                    if let u = parsed.usage { usage = u }
                    for ev in parsed.events {
                        let captured = ev
                        await MainActor.run { onEvent(captured) }
                    }
                }
            }
        }
        return ParsedTurn(text: textBuffer, blocks: blocks, unfinalized: unfinalized, usage: usage)
    }

    private func readChunk(from handle: FileHandle) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let data = handle.availableData
                cont.resume(returning: data)
            }
        }
    }

    /// Result of parsing a single JSONL line. `blocks` are canonical
    /// ChatBlocks to persist in the assistant turn; `finalizedSegment`
    /// marks that a consolidated text segment landed.
    private struct ParsedEvent {
        var textDelta: String = ""
        var events: [ChatEvent] = []
        var blocks: [ChatBlock] = []
        var finalizedSegment: Bool = false
        var usage: StreamUsage?
    }

    /// Extract deltas, ChatEvents, and canonical blocks from one JSONL line.
    private func parseEvent(_ line: String, state: inout ParserState) -> ParsedEvent? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let type = obj["type"] as? String ?? ""

        switch type {
        case "item.started":
            // Tool items announce themselves here — surface the pulsing
            // chip right away, like Hermes's tool_call updates.
            guard let item = obj["item"] as? [String: Any],
                  let call = Self.toolCallDescriptor(item)
            else { return ParsedEvent() }
            state.startedToolItems.insert(call.id)
            var out = ParsedEvent()
            out.blocks.append(.toolUse(id: call.id, name: call.name, input: JSONValue.from(any: call.input)))
            out.events.append(.toolCall(id: call.id, name: call.name, input: call.input))
            return out

        case "item.completed":
            guard let item = obj["item"] as? [String: Any],
                  let itemType = item["type"] as? String
            else { return ParsedEvent() }
            switch itemType {
            case "agent_message":
                let text = item["text"] as? String ?? ""
                if text.isEmpty { return ParsedEvent() }
                // Codex emits the final agent_message in one shot. Send it
                // through `.partialText` (bubble appears immediately) and
                // `.text` (segment finalizes in place, so a following tool
                // chip starts a fresh bubble instead of merging).
                var out = ParsedEvent()
                out.textDelta = text
                out.events = [.partialText(text), .text(text)]
                out.blocks = [.text(text)]
                out.finalizedSegment = true
                return out
            case "agent_reasoning":
                // Finalize the thinking stream — emit only the tail that
                // hasn't already been surfaced via `item.updated` ticks.
                let full = (item["text"] as? String) ?? (item["summary"] as? String) ?? ""
                if full.isEmpty { return ParsedEvent() }
                let tail = Self.tail(of: full, since: state.lastReasoning)
                state.lastReasoning = ""
                if tail.isEmpty { return ParsedEvent() }
                return ParsedEvent(events: [.thinkingDelta(tail)])
            default:
                // Tool items (mcp_tool_call, command_execution, web_search):
                // settle the chip with the result. Backfill the call event
                // when this codex version skipped `item.started` for it.
                guard let call = Self.toolCallDescriptor(item) else {
                    return ParsedEvent()
                }
                var out = ParsedEvent()
                if !state.startedToolItems.contains(call.id) {
                    out.blocks.append(.toolUse(id: call.id, name: call.name, input: JSONValue.from(any: call.input)))
                    out.events.append(.toolCall(id: call.id, name: call.name, input: call.input))
                }
                let result = Self.toolResultDescriptor(item)
                out.blocks.append(.toolResult(toolUseId: call.id, content: result.summary, isError: result.isError))
                out.events.append(.toolResult(id: call.id, name: call.name, summary: result.summary, isError: result.isError))
                return out
            }

        case "item.updated":
            // Stream the reasoning summary as it grows. Codex sends the
            // *full* running text on each update, so we diff against the
            // previous value to get just the new portion.
            guard let item = obj["item"] as? [String: Any],
                  let itemType = item["type"] as? String,
                  itemType == "agent_reasoning"
            else { return ParsedEvent() }
            let full = (item["text"] as? String) ?? (item["summary"] as? String) ?? ""
            if full.isEmpty { return ParsedEvent() }
            let delta = Self.tail(of: full, since: state.lastReasoning)
            state.lastReasoning = full
            if delta.isEmpty { return ParsedEvent() }
            return ParsedEvent(events: [.thinkingDelta(delta)])

        case "turn.completed":
            // Usage stats for turn telemetry. Input is fresh + cached —
            // summed so the stat reflects the full context consumed.
            guard let usage = obj["usage"] as? [String: Any] else { return ParsedEvent() }
            let input = (usage["input_tokens"] as? Int ?? 0)
                + (usage["cached_input_tokens"] as? Int ?? 0)
            let output = usage["output_tokens"] as? Int ?? 0
            var out = ParsedEvent()
            out.usage = StreamUsage(input: input, output: output)
            return out

        case "thread.started", "turn.started":
            return ParsedEvent()

        default:
            return ParsedEvent()
        }
    }

    /// Map a codex tool item onto a `(id, name, input)` triple the chat UI
    /// can render. Field names are parsed defensively — the exec JSON schema
    /// has drifted across codex versions.
    private static func toolCallDescriptor(_ item: [String: Any]) -> (id: String, name: String, input: [String: Any])? {
        guard let id = item["id"] as? String else { return nil }
        switch item["type"] as? String ?? "" {
        case "mcp_tool_call":
            let rawName = (item["tool"] as? String)
                ?? (item["tool_name"] as? String)
                ?? "tool"
            return (id, OttoTools.canonicalToolName(rawName), objectify(item["arguments"] ?? item["args"]))
        case "command_execution":
            var input: [String: Any] = [:]
            if let cmd = item["command"] as? String { input["command"] = cmd }
            return (id, "shell", input)
        case "web_search":
            var input: [String: Any] = [:]
            if let query = item["query"] as? String { input["query"] = query }
            return (id, "web_search", input)
        default:
            return nil
        }
    }

    /// Best-effort result text + error flag for a completed tool item.
    /// MCP results can arrive as a plain string, an MCP CallToolResult
    /// (`{content:[{type:"text",text:…}], isError}`), or not at all (older
    /// codex versions only carry `status`).
    private static func toolResultDescriptor(_ item: [String: Any]) -> (summary: String, isError: Bool) {
        let status = (item["status"] as? String ?? "").lowercased()
        var isError = status == "failed" || status == "error"
        if let code = item["exit_code"] as? Int, code != 0 { isError = true }

        var text = ""
        if let s = item["result"] as? String {
            text = s
        } else if let obj = item["result"] as? [String: Any] {
            if let contents = obj["content"] as? [[String: Any]] {
                text = contents.compactMap { $0["text"] as? String }.joined(separator: "\n")
                if (obj["isError"] as? Bool) == true { isError = true }
            }
            if text.isEmpty,
               let data = try? JSONSerialization.data(withJSONObject: obj),
               let s = String(data: data, encoding: .utf8) {
                text = s
            }
        } else if let s = item["output"] as? String {
            text = s
        } else if let s = item["aggregated_output"] as? String {
            text = s
        } else if let s = item["error"] as? String {
            text = s
            isError = true
        }
        if text.isEmpty { text = isError ? "failed" : "done" }
        return (text, isError)
    }

    /// `arguments` may be a JSON object or a JSON-encoded string depending
    /// on codex version — normalize to a dictionary.
    private static func objectify(_ value: Any?) -> [String: Any] {
        if let dict = value as? [String: Any] { return dict }
        if let s = value as? String,
           let data = s.data(using: .utf8),
           let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return dict
        }
        return [:]
    }

    /// Return the suffix of `full` that comes after `prefix`. If `prefix`
    /// isn't actually a prefix of `full` (rare — Codex sometimes rewrites
    /// the running summary), fall back to the whole `full` so we don't
    /// silently drop reasoning.
    private static func tail(of full: String, since prefix: String) -> String {
        if prefix.isEmpty { return full }
        if full.hasPrefix(prefix) {
            return String(full.dropFirst(prefix.count))
        }
        return full
    }
}
