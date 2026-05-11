import Foundation

/// Spawns the `genmedia` CLI (fal.ai's agent-first generative-media tool) on
/// demand and returns parsed JSON results. Every invocation injects the
/// existing fal API key (`FalAIService.shared.getAPIKey()`) as `FAL_KEY` in
/// the subprocess env — no separate config, no `genmedia setup` round-trip.
///
/// Architecturally mirrors `ClaudeCLIService` / `CodexCLIService`: probe the
/// binary lazily, spawn `Process`, pipe stdio, parse `--json` output.
/// The big difference is that this service is **per-tool-call**, not
/// per-chat-turn — each method here corresponds to one agent tool.
actor GenMediaService {
    static let shared = GenMediaService()

    /// Locations probed for the genmedia binary, in order. First hit wins.
    /// `~/.genmedia/bin/genmedia` is where the official install script
    /// drops it; the others cover Homebrew / system installs.
    private static let candidatePaths: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.genmedia/bin/genmedia",
            "/opt/homebrew/bin/genmedia",
            "/usr/local/bin/genmedia",
            "/usr/bin/genmedia"
        ]
    }()
    private var resolvedPath: String?

    /// Default subprocess timeout. genmedia's synchronous `run` blocks until
    /// the model finishes; most image generations land in 5-20s, but some
    /// video models exceed a minute. 120s is a comfortable upper bound for
    /// v1 — longer jobs should use --async + status polling (v2).
    private let defaultTimeout: TimeInterval = 120

    private init() {}

    // MARK: - Errors

    enum GenMediaError: LocalizedError {
        case notInstalled
        case noAPIKey
        case launchFailed(String)
        case crashed(Int32, String)
        case invalidJSON(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "genmedia CLI not installed. Open Integrations → GenMedia for setup."
            case .noAPIKey:
                return "No fal API key set. Open Settings → Voice Mode and paste your fal.ai key."
            case .launchFailed(let m): return "Failed to launch genmedia: \(m)"
            case .crashed(let code, let stderr):
                return "genmedia exited \(code): \(stderr)"
            case .invalidJSON(let detail):
                return "Couldn't parse genmedia output: \(detail)"
            case .timeout: return "genmedia timed out."
            }
        }
    }

    // MARK: - Installation status

    /// Non-blocking check used by Settings/Integrations to render the
    /// "Found at <path>" badge. Caches the resolved path on first hit so
    /// repeat calls are cheap.
    nonisolated func isInstalled() -> Bool {
        binaryPath() != nil
    }

    /// Returns the path of the first existing genmedia binary, or nil.
    /// `nonisolated` so SwiftUI views can call it synchronously.
    nonisolated func binaryPath() -> String? {
        for p in Self.candidatePaths where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        return nil
    }

    // MARK: - Public API (one method per agent tool)

    /// Runs `genmedia models <query> --json --limit <n>`.
    func searchModels(query: String, category: String? = nil, limit: Int = 10) async throws -> Data {
        var args = ["models"]
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            args.append(query)
        }
        if let category = category, !category.isEmpty {
            args.append(contentsOf: ["--category", category])
        }
        args.append(contentsOf: ["--limit", String(max(1, min(limit, 50))), "--json"])
        return try await invoke(args: args)
    }

    /// Runs `genmedia schema <modelId> --json`.
    func modelSchema(modelId: String) async throws -> Data {
        try await invoke(args: ["schema", modelId, "--json"])
    }

    /// Result of a successful `genmedia run` invocation. `downloadedFiles`
    /// contains absolute paths to media the CLI just wrote to disk inside
    /// `downloadDir` (one per output index, named via the genmedia
    /// {request_id}_{index}.{ext} template).
    struct RunResult {
        let rawOutput: Data
        let downloadedFiles: [URL]
        let requestId: String?
    }

    /// Runs `genmedia run <modelId> --json --download "<dir>/{request_id}_{index}.{ext}"`,
    /// plus each `inputs` entry as a CLI flag (`--<key> <value>`). JSON-
    /// shaped values are encoded as JSON strings, scalars as plain strings.
    /// `downloadDir` is created if needed and scanned after the subprocess
    /// exits to enumerate the produced files.
    func runModel(
        modelId: String,
        inputs: [String: Any],
        downloadDir: URL
    ) async throws -> RunResult {
        try FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)
        let beforeFiles = Set((try? FileManager.default.contentsOfDirectory(atPath: downloadDir.path)) ?? [])

        let downloadTemplate = downloadDir
            .appendingPathComponent("{request_id}_{index}.{ext}").path

        var args: [String] = ["run", modelId, "--json", "--download", downloadTemplate]
        for (key, value) in inputs {
            args.append("--\(key)")
            args.append(Self.encodeInputValue(value))
        }

        let data = try await invoke(args: args, timeout: defaultTimeout)

        // Diff the dir to identify exactly the files this invocation produced.
        let afterFiles = Set((try? FileManager.default.contentsOfDirectory(atPath: downloadDir.path)) ?? [])
        let newFiles = afterFiles.subtracting(beforeFiles).map {
            downloadDir.appendingPathComponent($0)
        }

        // Pluck request_id out of the JSON for traceability — best-effort, the
        // exact shape varies by model. Common keys: "request_id", "requestId".
        let requestId = Self.extractRequestId(from: data)

        return RunResult(rawOutput: data, downloadedFiles: newFiles, requestId: requestId)
    }

    /// Runs `genmedia upload <path> --json`. Returns the CDN URL fal hands
    /// back. Used for image-to-image / video-to-video chains where the
    /// agent has a local file (likely an Otto-imported FileItem) it wants
    /// to feed into another model.
    func uploadFile(at fileURL: URL) async throws -> String {
        let data = try await invoke(args: ["upload", fileURL.path, "--json"])
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = (obj["url"] as? String) ?? (obj["cdn_url"] as? String)
        else {
            throw GenMediaError.invalidJSON("upload response did not include a 'url' field")
        }
        return url
    }

    // MARK: - Subprocess plumbing

    /// Resolves the binary path (lazily cached), validates the fal key is
    /// set, then spawns the subprocess with FAL_KEY in env, captures stdout
    /// to completion, and returns the raw bytes. Throws specific GenMediaError
    /// cases so the executor can map them to user-friendly messages.
    private func invoke(args: [String], timeout: TimeInterval? = nil) async throws -> Data {
        guard let bin = binaryPath() else {
            throw GenMediaError.notInstalled
        }
        resolvedPath = bin

        let key = FalAIService.shared.getAPIKey()
        guard !key.isEmpty else {
            throw GenMediaError.noAPIKey
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = args

        var env = ProcessInfo.processInfo.environment
        env["FAL_KEY"] = key
        // Silence the auto-update probe — we don't want the subprocess
        // pulling new binaries during a generation.
        env["GENMEDIA_NO_UPDATE"] = "1"
        // ANSI in --json output would break parsing.
        env["NO_COLOR"] = "1"
        proc.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        do {
            try proc.run()
        } catch {
            throw GenMediaError.launchFailed(error.localizedDescription)
        }

        let stdoutTask = Task.detached { stdoutPipe.fileHandleForReading.readDataToEndOfFile() }
        let stderrTask = Task.detached { stderrPipe.fileHandleForReading.readDataToEndOfFile() }

        // Watchdog: if the subprocess outlives the timeout, force-terminate.
        let watchdog = Task.detached { [weak proc] in
            try? await Task.sleep(nanoseconds: UInt64((timeout ?? 60) * 1_000_000_000))
            proc?.terminate()
        }

        proc.waitUntilExit()
        watchdog.cancel()

        let stdoutData = await stdoutTask.value
        let stderrData = await stderrTask.value

        if proc.terminationStatus != 0 {
            let stderr = String(data: stderrData, encoding: .utf8) ?? "(no stderr)"
            // SIGTERM = 15; if the watchdog killed us, surface as timeout
            // rather than a generic crash.
            if proc.terminationStatus == SIGTERM {
                throw GenMediaError.timeout
            }
            throw GenMediaError.crashed(proc.terminationStatus, stderr)
        }

        return stdoutData
    }

    /// Encode a tool-call input value as a CLI argument. Strings/numbers
    /// pass through; collections become compact JSON so they survive the
    /// `--key value` round-trip (genmedia parses JSON-shaped values).
    private static func encodeInputValue(_ value: Any) -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        if let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.fragmentsAllowed, .sortedKeys]
        ), let s = String(data: data, encoding: .utf8) {
            return s
        }
        return String(describing: value)
    }

    private static func extractRequestId(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let s = obj["request_id"] as? String { return s }
        if let s = obj["requestId"] as? String { return s }
        return nil
    }
}
