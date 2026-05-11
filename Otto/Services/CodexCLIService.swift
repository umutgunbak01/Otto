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
        turns: [ChatTurn],
        systemPrompt: String,
        tools: [[String: Any]],        // ignored — Codex picks up tools via MCP
        executor: OttoToolExecutor,    // ignored — MCP path handles execution
        onDelta: @escaping @MainActor (String) -> Void,
        onEvent: @escaping @MainActor (ChatEvent) -> Void
    ) async throws -> [ChatTurn] {

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
        if let socketPath = OttoMCPServer.shared.ensureStarted() {
            args.append(contentsOf: [
                "-c", "mcp_servers.otto.command=\"\(netcatPath)\"",
                "-c", "mcp_servers.otto.args=[\"-U\",\"\(socketPath)\"]"
            ])
        } else {
            NSLog("[CodexCLI] MCP server unavailable — Otto tools disabled this turn")
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

        let assistantText = try await parseStreamJSON(
            stdout: stdoutPipe.fileHandleForReading,
            onDelta: onDelta,
            onEvent: onEvent
        )

        proc.waitUntilExit()

        if proc.terminationStatus != 0 {
            let msg = String(data: stderrBuffer, encoding: .utf8) ?? "(no stderr)"
            NSLog("[CodexCLI] exited \(proc.terminationStatus): \(msg)")
            if authMode == .apiKey && Self.looksLikeBadAPIKey(msg) {
                throw CLIError.apiKeyRejected
            }
            throw CLIError.crashed(proc.terminationStatus, msg)
        }

        // OttoChatView renders bubbles from `onEvent(.text(...))` — not from
        // the returned turns — so the completed assistant message needs to
        // land there as a single event. Voice mode already got its text via
        // `onDelta` in `parseStreamJSON`, so this is harmless for it.
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
    /// role-prefixed turns, then pipe everything in on stdin.
    private func combinedPrompt(systemPrompt: String, turns: [ChatTurn]) -> String {
        var out: [String] = []
        let trimmedSystem = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSystem.isEmpty {
            out.append("[system]\n\(trimmedSystem)")
        }
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

    /// Parse JSONL events from `codex exec --json`. Emitted events:
    ///   - `thread.started` — session metadata, no-op
    ///   - `turn.started` — agent loop iteration begins, no-op
    ///   - `item.completed` — wraps one completed item:
    ///       - `agent_message` → assistant text (delivered in one shot —
    ///         see streaming caveat in the actor doc — but still emitted
    ///         to the UI as a `.partialText` so the bubble shows up the
    ///         moment Codex finishes, rather than at end-of-turn)
    ///       - `function_call` / `tool_call` → tool invocation event
    ///       - `agent_reasoning` → emitted as `.thinkingDelta` so the
    ///         user can follow Codex's chain of thought
    ///   - `item.updated` — incremental updates while an item is forming;
    ///     `agent_reasoning` updates stream a growing summary which makes
    ///     a decent "thinking…" indicator even though Codex doesn't
    ///     stream the final agent_message per-token.
    ///   - `turn.completed` — usage stats, no-op
    private func parseStreamJSON(
        stdout: FileHandle,
        onDelta: @escaping @MainActor (String) -> Void,
        onEvent: @escaping @MainActor (ChatEvent) -> Void
    ) async throws -> String {
        var textBuffer = ""
        var leftover = ""
        // Track the most recent agent_reasoning summary so `item.updated`
        // bursts can emit just the delta rather than re-sending the full
        // running text.
        var lastReasoning = ""

        while true {
            let chunk = try await readChunk(from: stdout)
            if chunk.isEmpty { break }
            guard let s = String(data: chunk, encoding: .utf8) else { continue }
            leftover += s
            while let newlineRange = leftover.range(of: "\n") {
                let line = String(leftover[..<newlineRange.lowerBound])
                leftover = String(leftover[newlineRange.upperBound...])
                if line.isEmpty { continue }
                if let parsed = parseEvent(line, lastReasoning: &lastReasoning) {
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

    private struct ParsedEvent {
        let textDelta: String
        let events: [ChatEvent]
    }

    /// Extract a text delta and/or ChatEvents from one NDJSON line.
    /// `lastReasoning` is read+written so `item.updated` bursts produce
    /// strict deltas off the previous reasoning summary — emitting the
    /// full running text every tick would produce N-shaped accumulation
    /// in the UI's thinking bubble.
    private func parseEvent(_ line: String, lastReasoning: inout String) -> ParsedEvent? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let type = obj["type"] as? String ?? ""

        switch type {
        case "item.completed":
            guard let item = obj["item"] as? [String: Any],
                  let itemType = item["type"] as? String
            else { return ParsedEvent(textDelta: "", events: []) }
            switch itemType {
            case "agent_message":
                let text = item["text"] as? String ?? ""
                if text.isEmpty { return ParsedEvent(textDelta: "", events: []) }
                // Codex emits the final agent_message in one shot. Send it
                // through `.partialText` too so the UI's streaming bubble
                // appears immediately rather than waiting for end-of-turn.
                return ParsedEvent(textDelta: text, events: [.partialText(text)])
            case "agent_reasoning":
                // Finalize the thinking stream — emit only the tail that
                // hasn't already been surfaced via `item.updated` ticks.
                let full = (item["text"] as? String) ?? (item["summary"] as? String) ?? ""
                if full.isEmpty { return ParsedEvent(textDelta: "", events: []) }
                let tail = Self.tail(of: full, since: lastReasoning)
                lastReasoning = ""
                if tail.isEmpty { return ParsedEvent(textDelta: "", events: []) }
                return ParsedEvent(textDelta: "", events: [.thinkingDelta(tail)])
            default:
                // function_call, tool_call, etc. — we don't surface these in
                // the chat UI for v1 (tool calls flow through the MCP bridge
                // via OttoToolExecutor, which fires its own .toolCall events).
                return ParsedEvent(textDelta: "", events: [])
            }

        case "item.updated":
            // Stream the reasoning summary as it grows. Codex sends the
            // *full* running text on each update, so we diff against the
            // previous value to get just the new portion.
            guard let item = obj["item"] as? [String: Any],
                  let itemType = item["type"] as? String,
                  itemType == "agent_reasoning"
            else { return ParsedEvent(textDelta: "", events: []) }
            let full = (item["text"] as? String) ?? (item["summary"] as? String) ?? ""
            if full.isEmpty { return ParsedEvent(textDelta: "", events: []) }
            let delta = Self.tail(of: full, since: lastReasoning)
            lastReasoning = full
            if delta.isEmpty { return ParsedEvent(textDelta: "", events: []) }
            return ParsedEvent(textDelta: "", events: [.thinkingDelta(delta)])

        case "thread.started", "turn.started", "turn.completed", "item.started":
            return ParsedEvent(textDelta: "", events: [])

        default:
            return ParsedEvent(textDelta: "", events: [])
        }
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
