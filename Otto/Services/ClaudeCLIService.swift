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

        let assistantText = try await parseStreamJSON(
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

        // OttoChatView renders bubbles from `onEvent(.text(...))` — not from
        // the returned turns — so the completed assistant message needs to land
        // there as a single event. Voice mode ignores `onEvent` entirely and
        // already got its text via `onDelta`, so this is harmless for it.
        let finalText = assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalText.isEmpty {
            let captured = finalText
            await MainActor.run { onEvent(.text(captured)) }
        }

        var updated = turns
        updated.append(ChatTurn(role: "assistant", blocks: [.text(assistantText)]))
        return updated
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

    /// Flatten the turn log into a single prompt string. Each turn gets a role
    /// prefix so Claude can read the back-and-forth. Tool result blocks are
    /// elided — Phase 1 doesn't execute Otto tools through the CLI path.
    private func flattenTurns(_ turns: [ChatTurn]) -> String {
        var out: [String] = []
        for turn in turns {
            var chunks: [String] = []
            for block in turn.blocks {
                if case .text(let s) = block,
                   !s.trimmingCharacters(in: .whitespaces).isEmpty {
                    chunks.append(s)
                }
            }
            let combined = chunks.joined(separator: "\n\n")
            if combined.isEmpty { continue }
            let prefix = turn.role == "assistant" ? "Assistant" : "User"
            out.append("\(prefix): \(combined)")
        }
        return out.joined(separator: "\n\n")
    }

    /// Parse line-delimited JSON events from the CLI and stream text deltas to
    /// `onDelta`. Returns the complete assistant text once the stream ends.
    ///
    /// Key event types (from `claude -p --output-format stream-json`):
    ///   - `system` (subtype: init / result) — session metadata
    ///   - `user` — echoed user message
    ///   - `assistant` — full assistant message blocks
    ///   - `stream_event` (with --include-partial-messages) — raw Anthropic SSE
    ///     events like `content_block_delta` with `delta.text`
    ///   - `result` — terminal event with final result + usage stats
    private func parseStreamJSON(
        stdout: FileHandle,
        onDelta: @escaping @MainActor (String) -> Void,
        onEvent: @escaping @MainActor (ChatEvent) -> Void
    ) async throws -> String {
        var textBuffer = ""
        var leftover = ""

        while true {
            let chunk = try await readChunk(from: stdout)
            if chunk.isEmpty { break }
            guard let s = String(data: chunk, encoding: .utf8) else { continue }
            leftover += s
            while let newlineRange = leftover.range(of: "\n") {
                let line = String(leftover[..<newlineRange.lowerBound])
                leftover = String(leftover[newlineRange.upperBound...])
                if line.isEmpty { continue }
                if let parsed = parseEvent(line) {
                    if !parsed.textDelta.isEmpty {
                        textBuffer += parsed.textDelta
                        let captured = parsed.textDelta
                        await MainActor.run { onDelta(captured) }
                    }
                    for ev in parsed.events {
                        let captured = ev
                        await MainActor.run { onEvent(captured) }
                    }
                }
            }
        }
        return textBuffer
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
    /// to surface to the UI for this line — typically a `.partialText` for
    /// each text delta, a `.thinkingDelta` for each thinking delta, plus
    /// any tool-related events.
    private struct ParsedEvent {
        let textDelta: String
        let events: [ChatEvent]
    }

    /// Extract a text delta and/or ChatEvents from one NDJSON line.
    /// Handles both `text_delta` content blocks (visible assistant output)
    /// and `thinking_delta` content blocks (extended-thinking reasoning).
    private func parseEvent(_ line: String) -> ParsedEvent? {
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
            else { return ParsedEvent(textDelta: "", events: []) }

            let deltaType = (delta["type"] as? String) ?? ""

            if deltaType == "thinking_delta",
               let thinking = delta["thinking"] as? String, !thinking.isEmpty {
                return ParsedEvent(textDelta: "", events: [.thinkingDelta(thinking)])
            }

            // Default path covers `text_delta` (and legacy shapes that
            // omitted the `type` field but always had `text`).
            if let text = delta["text"] as? String, !text.isEmpty {
                return ParsedEvent(textDelta: text, events: [.partialText(text)])
            }
            return ParsedEvent(textDelta: "", events: [])

        case "assistant":
            // Full message blocks — use as a fallback text source when the
            // CLI isn't running with --include-partial-messages. Returns
            // nothing here since we already accumulate via stream_event.
            return ParsedEvent(textDelta: "", events: [])

        case "system", "user", "result", "rate_limit_event":
            return ParsedEvent(textDelta: "", events: [])

        default:
            return ParsedEvent(textDelta: "", events: [])
        }
    }
}
