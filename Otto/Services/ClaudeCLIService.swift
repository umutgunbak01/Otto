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
        case launchFailed(String)
        case crashed(Int32, String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .notFound:
                return "Claude CLI not found. Install Claude Code or set its path."
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
                if let (delta, toolEvent) = parseEvent(line) {
                    if !delta.isEmpty {
                        textBuffer += delta
                        let captured = delta
                        await MainActor.run { onDelta(captured) }
                    }
                    if let event = toolEvent {
                        await MainActor.run { onEvent(event) }
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

    /// Extract a text delta and/or a tool event from one NDJSON line.
    private func parseEvent(_ line: String) -> (String, ChatEvent?)? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let type = obj["type"] as? String ?? ""

        switch type {
        case "stream_event":
            // Anthropic SSE passthrough — grab text deltas for TTS.
            guard let event = obj["event"] as? [String: Any],
                  let eventType = event["type"] as? String,
                  eventType == "content_block_delta",
                  let delta = event["delta"] as? [String: Any],
                  let text = delta["text"] as? String
            else { return ("", nil) }
            return (text, nil)

        case "assistant":
            // Full message blocks — use as a fallback text source when the
            // CLI isn't running with --include-partial-messages. Returns
            // nothing here since we already accumulate via stream_event.
            return ("", nil)

        case "system", "user", "result", "rate_limit_event":
            return ("", nil)

        default:
            return ("", nil)
        }
    }
}
