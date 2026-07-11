import Foundation

/// Alternative Claude backend that shells out to the `claude` CLI instead of
/// hitting `api.anthropic.com` directly. Gives Otto access to Claude Code's
/// built-in tools — WebSearch, WebFetch, Read, Grep, Glob — that aren't
/// available over the plain Messages API.
///
/// Phase 1: no MCP server → no Otto tools here yet. The `tools` and `executor`
/// parameters are accepted (so the call-site matches `AgentService`) but
/// ignored. Phase 2 will wire a Unix-socket MCP server exposing `OttoTools`.
///
/// Signature-compatible with `AgentService.streamChatWithTools` so callers can
/// swap backends behind a flag without changing the pipeline.
actor ClaudeCLIService {
    static let shared = ClaudeCLIService()

    /// Common install locations — probed in order, first hit wins. Cached.
    private static let candidatePaths: [String] = [
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        "/usr/bin/claude"
    ]
    private var resolvedPath: String?

    /// Live CLI subprocesses keyed by the conversation (`sessionKey`) that
    /// launched them, so Stop can terminate the right one when several
    /// conversations run concurrently. Entries are cleared when their turn
    /// ends. Access is serialized by the actor.
    private var activeProcesses: [UUID: Process] = [:]

    /// CLI-side built-in tool whitelist. Keeps Otto from running Bash / Edit /
    /// Write unless we explicitly opt into those later. MCP tools (Otto tools)
    /// aren't listed here — they're gated separately by `--permission-mode
    /// bypassPermissions` + the MCP server allowlist.
    private let safeToolWhitelist = "WebSearch,WebFetch,Read,Grep,Glob"

    /// Path to `nc` (netcat) — used as a stdio ↔ Unix-socket bridge so the CLI
    /// can talk to our in-process MCP server without us implementing the full
    /// MCP streamable-HTTP transport.
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
                return "Claude CLI not found. Install Claude Code or set its path."
            case .notSignedIn:
                return "Not signed in to Claude. Run `claude` in Terminal, or paste an Anthropic API key in Settings."
            case .apiKeyRejected:
                return "Your Anthropic API key was rejected. Check Settings → Agent."
            case .launchFailed(let m): return "Failed to launch claude CLI: \(m)"
            case .crashed(let code, let stderr):
                return "claude CLI exited \(code): \(stderr)"
            case .timeout: return "claude CLI timed out."
            }
        }
    }

    // MARK: - Public API (mirrors AgentService.streamChatWithTools)

    func streamChatWithTools(
        sessionKey: UUID,
        turns: [ChatTurn],
        systemPrompt: String,
        tools: [[String: Any]],         // ignored in Phase 1
        executor: OttoToolExecutor,    // ignored in Phase 1
        onDelta: @escaping @MainActor (String) -> Void,
        onEvent: @escaping @MainActor (ChatEvent) -> Void
    ) async throws -> [ChatTurn] {

        let authMode = ClaudeAuthService.shared.effectiveAuthMode()
        guard authMode != .none else {
            throw CLIError.notSignedIn
        }

        let bin = try resolveClaudeBinary()
        let prompt = flattenTurns(turns)
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Screen-vision handoff: IntentRouter stashes a PNG path in AppState;
        // copy it into the CLI's cwd as `screenshot.png` so Claude Code's
        // Read tool can load it visually when the prompt references it.
        // Then clear so the next turn doesn't replay a stale screenshot.
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
                    // Best-effort cleanup of the captured source.
                    try? FileManager.default.removeItem(at: src)
                    NSLog("[ClaudeCLI] screenshot copied into session tmpDir")
                } catch {
                    NSLog("[ClaudeCLI] failed to stage screenshot: \(error.localizedDescription)")
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
        // Note: `--bare` would be nicer (skip CLAUDE.md auto-discovery, hooks,
        // plugin sync) but it forces ANTHROPIC_API_KEY-only auth, which blocks
        // the user's Claude Code OAuth subscription. We run in a fresh tmp dir
        // with `--system-prompt` overriding the default, so CLAUDE.md / hooks
        // shouldn't meaningfully pollute the session anyway.
        var args: [String] = [
            "-p",
            "--model", AgentService.Claude.getModel(),
            "--system-prompt", systemPrompt,
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
            "--permission-mode", "bypassPermissions",
            "--tools", safeToolWhitelist
        ]
        // Start the Otto MCP server (idempotent) and point the CLI at it via
        // an `nc -U` stdio bridge. `--strict-mcp-config` prevents any other
        // MCP servers the user may have configured globally from leaking in.
        // Each user-registered Supabase project is also injected here as a
        // streamable-HTTP MCP server, sharing the same `--mcp-config` JSON.
        let socketPath = OttoMCPServer.shared.ensureStarted()
        var mcpServers: [String: Any] = [:]
        if let socketPath {
            mcpServers["otto"] = [
                "command": netcatPath,
                "args": ["-U", socketPath],
                "env": [String: String]()
            ]
        } else {
            NSLog("[ClaudeCLI] MCP server unavailable — Otto tools disabled this turn")
        }
        // Google Drive / Calendar MCP — both Google-hosted streamable HTTP
        // servers that take the user's OAuth access token as a Bearer
        // header. Inject either whenever the user has flipped the
        // corresponding integration on. Token refresh happens at fetch
        // time (within getValidAccessToken's 5-minute buffer); on
        // failure, skip the relevant server for this turn rather than
        // crashing the whole chat.
        if GoogleAuthService.shared.hasDriveScopes() {
            do {
                let driveToken = try await GoogleAuthService.shared.getValidAccessToken()
                mcpServers["drive"] = [
                    "type": "http",
                    "url": "https://drivemcp.googleapis.com/mcp/v1",
                    "headers": ["Authorization": "Bearer \(driveToken)"]
                ]
            } catch {
                NSLog("[ClaudeCLI] Drive MCP skipped — token unavailable: %@", error.localizedDescription)
            }
        }
        if GoogleAuthService.shared.hasCalendarMcpScopes() {
            do {
                let calToken = try await GoogleAuthService.shared.getValidAccessToken()
                mcpServers["calendar"] = [
                    "type": "http",
                    "url": "https://calendarmcp.googleapis.com/mcp/v1",
                    "headers": ["Authorization": "Bearer \(calToken)"]
                ]
            } catch {
                NSLog("[ClaudeCLI] Calendar MCP skipped — token unavailable: %@", error.localizedDescription)
            }
        }
        // Tally — remote MCP server at api.tally.so/mcp. Auth is a stored
        // `tly-…` API key the user pasted in Integrations; no OAuth dance,
        // no per-turn refresh needed.
        if let tallyKey = TallyService.shared.apiKey(), !tallyKey.isEmpty {
            mcpServers["tally"] = [
                "type": "http",
                "url": "https://api.tally.so/mcp",
                "headers": ["Authorization": "Bearer \(tallyKey)"]
            ]
        }
        for project in SupabaseProjectsService.shared.allProjects() {
            guard let pat = SupabaseProjectsService.shared.pat(for: project.id) else { continue }
            mcpServers["supabase_\(project.slug)"] = [
                "type": "http",
                "url": "https://mcp.supabase.com/mcp?project_ref=\(project.projectRef)",
                "headers": ["Authorization": "Bearer \(pat)"]
            ]
        }
        // User-added custom MCP servers (Integrations → Custom MCP Servers).
        // Slugs are validated at add time against the reserved names above;
        // the guard keeps a stale entry from clobbering a built-in server.
        // `effectiveSecrets` mints a fresh OAuth Bearer for `.oauth` servers
        // and returns nil (skip this turn) when sign-in is required.
        for server in CustomMCPServersStore.shared.enabledServers() {
            guard mcpServers[server.slug] == nil else { continue }
            guard let secrets = await CustomMCPServersStore.shared.effectiveSecrets(for: server) else { continue }
            mcpServers[server.slug] = CustomMCPServersStore.claudeEntry(for: server, secrets: secrets)
        }
        if !mcpServers.isEmpty {
            let cfg: [String: Any] = ["mcpServers": mcpServers]
            if let cfgData = try? JSONSerialization.data(withJSONObject: cfg) {
                // Write the config to a 0600 file inside this turn's tmpDir
                // and pass the file path — never the inline JSON — so the
                // Supabase PAT in `headers.Authorization` doesn't appear in
                // `ps auxww` output. The file is deleted along with tmpDir
                // when this function returns (see the defer at the top).
                let cfgFile = tmpDir.appendingPathComponent("mcp.json")
                let written: Bool = {
                    do {
                        try cfgData.write(to: cfgFile, options: .atomic)
                        try FileManager.default.setAttributes(
                            [.posixPermissions: 0o600],
                            ofItemAtPath: cfgFile.path
                        )
                        return true
                    } catch {
                        NSLog("[ClaudeCLI] failed to stage MCP config file: %@", error.localizedDescription)
                        return false
                    }
                }()
                if written {
                    args.append(contentsOf: ["--mcp-config", cfgFile.path, "--strict-mcp-config"])
                }
            }
        }
        proc.arguments = args
        var env = ProcessInfo.processInfo.environment
        // Force ANSI-free output; stream-json should be clean but safety first.
        env["NO_COLOR"] = "1"
        // When the user has set an Anthropic API key in Otto's Settings,
        // forward it to the CLI. The CLI prefers this over its stored OAuth
        // credentials, so the subscription path is bypassed automatically.
        if authMode == .apiKey, let key = ClaudeAuthService.shared.apiKey() {
            env["ANTHROPIC_API_KEY"] = key
        }
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
        if let data = prompt.data(using: .utf8) {
            try? stdinPipe.fileHandleForWriting.write(contentsOf: data)
        }
        try? stdinPipe.fileHandleForWriting.close()

        // Drain stderr in the background so the pipe buffer never fills.
        var stderrBuffer = Data()
        let stderrHandle = stderrPipe.fileHandleForReading
        stderrHandle.readabilityHandler = { h in
            let chunk = h.availableData
            if chunk.isEmpty { h.readabilityHandler = nil; return }
            stderrBuffer.append(chunk)
        }

        let parsed = try await parseStreamJSON(
            stdout: stdoutPipe.fileHandleForReading,
            onDelta: onDelta,
            onEvent: onEvent
        )

        proc.waitUntilExit()
        stderrHandle.readabilityHandler = nil

        if proc.terminationStatus != 0 {
            let msg = String(data: stderrBuffer, encoding: .utf8) ?? "(no stderr)"
            NSLog("[ClaudeCLI] exited \(proc.terminationStatus): \(msg)")
            if authMode == .apiKey && Self.looksLikeBadAPIKey(msg) {
                throw CLIError.apiKeyRejected
            }
            throw CLIError.crashed(proc.terminationStatus, msg)
        }

        // Text segments are finalized per `assistant` message event (so tool
        // chips interleave with bubbles the way Hermes renders them). If the
        // stream ended with deltas that never got their consolidated
        // `assistant` event (degenerate stream / old CLI), flush the tail as
        // a final segment so it isn't lost.
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
        updated.append(ChatTurn(role: "assistant", blocks: blocks))
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
    /// agent's built-in Bash tool can find binaries the user installed via
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
            || needle.contains("authentication_error")
            || needle.contains("401")
    }

    private func resolveClaudeBinary() throws -> String {
        if let p = resolvedPath { return p }
        for p in Self.candidatePaths where FileManager.default.isExecutableFile(atPath: p) {
            resolvedPath = p
            return p
        }
        throw CLIError.notFound
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("otto-claude-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Flatten the turn log into a single prompt string. Uses the shared
    /// `ChatTranscript` flatten (role prefixes + compact bracketed tool
    /// calls/results) so follow-up turns keep the substance that lives in
    /// tool payloads — same replay format the Hermes backend uses.
    private func flattenTurns(_ turns: [ChatTurn]) -> String {
        ChatTranscript.flatten(turns)
    }

    /// Everything one CLI run produced: the concatenated delta text (voice
    /// TTS + fallback), the ordered canonical blocks (text segments + tool
    /// calls + tool results, mirroring what Hermes persists), and any delta
    /// text that never got its consolidated `assistant` event.
    private struct ParsedTurn {
        let text: String
        let blocks: [ChatBlock]
        let unfinalized: String
    }

    /// Parse line-delimited JSON events from the CLI, stream text deltas to
    /// `onDelta`, and mirror tool_use / tool_result blocks as ChatEvents so
    /// the chat UI renders the same chips/cards it does for Hermes.
    ///
    /// Key event types (from `claude -p --output-format stream-json`):
    ///   - `system` (subtype: init / result) — session metadata
    ///   - `user` — echoed user prompt, and tool_result blocks after each call
    ///   - `assistant` — full assistant message blocks (text + tool_use)
    ///   - `stream_event` (with --include-partial-messages) — raw Anthropic SSE
    ///     events like `content_block_delta` with `delta.text`
    ///   - `result` — terminal event with final result + usage stats
    private func parseStreamJSON(
        stdout: FileHandle,
        onDelta: @escaping @MainActor (String) -> Void,
        onEvent: @escaping @MainActor (ChatEvent) -> Void
    ) async throws -> ParsedTurn {
        var textBuffer = ""
        var leftover = ""
        var blocks: [ChatBlock] = []
        // Delta text since the last assistant-event finalize. Normally the
        // consolidated `assistant` event covers it exactly; whatever is left
        // at stream end becomes a final text segment upstream.
        var unfinalized = ""
        // tool_use id → canonical tool name, so the tool_result (which only
        // carries the id) can be labeled for the UI.
        var toolNames: [String: String] = [:]

        while true {
            let chunk = try await readChunk(from: stdout)
            if chunk.isEmpty { break }
            guard let s = String(data: chunk, encoding: .utf8) else { continue }
            leftover += s
            while let newlineRange = leftover.range(of: "\n") {
                let line = String(leftover[..<newlineRange.lowerBound])
                leftover = String(leftover[newlineRange.upperBound...])
                if line.isEmpty { continue }
                if let parsed = parseEvent(line, toolNames: &toolNames) {
                    if !parsed.textDelta.isEmpty {
                        textBuffer += parsed.textDelta
                        unfinalized += parsed.textDelta
                        let captured = parsed.textDelta
                        await MainActor.run { onDelta(captured) }
                    }
                    blocks.append(contentsOf: parsed.blocks)
                    if parsed.finalizedSegment { unfinalized = "" }
                    for ev in parsed.events {
                        let captured = ev
                        await MainActor.run { onEvent(captured) }
                    }
                }
            }
        }
        return ParsedTurn(text: textBuffer, blocks: blocks, unfinalized: unfinalized)
    }

    private func readChunk(from handle: FileHandle) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let data = handle.availableData
                cont.resume(returning: data)
            }
        }
    }

    /// Result of parsing a single NDJSON line from the Claude Code CLI.
    /// `textDelta` is the assistant-text delta (accumulated into the final
    /// reply + forwarded to voice TTS). `events` is the list of ChatEvents
    /// to surface to the UI for this line. `blocks` are canonical ChatBlocks
    /// to persist in the assistant turn (text segments, toolUse, toolResult).
    /// `finalizedSegment` marks that a consolidated text block landed, so
    /// the accumulated delta tail is accounted for.
    private struct ParsedEvent {
        var textDelta: String = ""
        var events: [ChatEvent] = []
        var blocks: [ChatBlock] = []
        var finalizedSegment: Bool = false
    }

    /// Extract deltas, ChatEvents, and canonical blocks from one NDJSON line.
    /// `stream_event` deltas drive live streaming; consolidated `assistant`
    /// events are the canonical source for text segments and tool_use blocks
    /// (mirrored as `.text` / `.toolCall`); `user` events carry tool_result
    /// blocks (mirrored as `.toolResult`).
    private func parseEvent(_ line: String, toolNames: inout [String: String]) -> ParsedEvent? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let type = obj["type"] as? String ?? ""

        switch type {
        case "stream_event":
            // Anthropic SSE passthrough. Two delta shapes matter here:
            //   delta.type == "text_delta"     → delta.text is assistant output
            //   delta.type == "thinking_delta" → delta.thinking is internal reasoning
            // We surface BOTH so the UI can render the response and the
            // chain of thought in distinct visual lanes.
            guard let event = obj["event"] as? [String: Any],
                  let eventType = event["type"] as? String,
                  eventType == "content_block_delta",
                  let delta = event["delta"] as? [String: Any]
            else { return ParsedEvent() }

            let deltaType = (delta["type"] as? String) ?? ""

            if deltaType == "thinking_delta",
               let thinking = delta["thinking"] as? String, !thinking.isEmpty {
                return ParsedEvent(events: [.thinkingDelta(thinking)])
            }

            // Default path covers `text_delta` (and legacy shapes that
            // omitted the `type` field but always had `text`).
            if let text = delta["text"] as? String, !text.isEmpty {
                return ParsedEvent(textDelta: text, events: [.partialText(text)])
            }
            return ParsedEvent()

        case "assistant":
            // Consolidated assistant message — one per message segment, so
            // text finalizes exactly where tool calls interleave (same
            // rendering shape as Hermes). Sub-agent traffic (non-null
            // parent_tool_use_id) stays internal.
            if let parent = obj["parent_tool_use_id"] as? String, !parent.isEmpty {
                return ParsedEvent()
            }
            guard let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]]
            else { return ParsedEvent() }
            var out = ParsedEvent()
            for block in content {
                switch block["type"] as? String ?? "" {
                case "text":
                    let text = block["text"] as? String ?? ""
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        out.blocks.append(.text(text))
                        out.events.append(.text(text))
                        out.finalizedSegment = true
                    }
                case "tool_use":
                    guard let id = block["id"] as? String,
                          let rawName = block["name"] as? String else { continue }
                    // MCP tools arrive as `mcp__otto__<tool>` — canonicalize
                    // so the UI and the preview/genmedia upgrades see the
                    // bare name, exactly like the Hermes path does.
                    let name = OttoTools.canonicalToolName(rawName)
                    let input = block["input"] as? [String: Any] ?? [:]
                    toolNames[id] = name
                    out.blocks.append(.toolUse(id: id, name: name, input: JSONValue.from(any: input)))
                    out.events.append(.toolCall(id: id, name: name, input: input))
                default:
                    break
                }
            }
            return out

        case "user":
            // Tool results come back as user-role messages with tool_result
            // blocks. (The echoed user prompt has string content — skipped.)
            if let parent = obj["parent_tool_use_id"] as? String, !parent.isEmpty {
                return ParsedEvent()
            }
            guard let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]]
            else { return ParsedEvent() }
            var out = ParsedEvent()
            for block in content where (block["type"] as? String) == "tool_result" {
                guard let toolUseId = block["tool_use_id"] as? String else { continue }
                let isError = (block["is_error"] as? Bool) ?? false
                let text = Self.toolResultText(block["content"])
                let name = toolNames[toolUseId] ?? "tool"
                out.blocks.append(.toolResult(toolUseId: toolUseId, content: text, isError: isError))
                out.events.append(.toolResult(id: toolUseId, name: name, summary: text, isError: isError))
            }
            return out

        case "system", "result", "rate_limit_event":
            return ParsedEvent()

        default:
            return ParsedEvent()
        }
    }

    /// tool_result `content` is either a plain string or an array of
    /// `{type:"text", text}` blocks — flatten to one string.
    private static func toolResultText(_ value: Any?) -> String {
        if let s = value as? String { return s }
        if let arr = value as? [[String: Any]] {
            return arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        if let obj = value as? [String: Any], let s = obj["text"] as? String { return s }
        return ""
    }
}
