import Foundation
import Darwin
import AppKit

/// Unix-domain-socket MCP server exposing `OttoTools` to the `claude` CLI.
///
/// Why a Unix socket? The `claude` CLI's stdio MCP transport spawns a subprocess
/// and talks JSON-RPC over its stdin/stdout. We can't have the CLI spawn our
/// Swift app, so instead the CLI spawns `nc -U <socket>` as a tiny relay — that
/// hops stdin/stdout across a Unix socket into this server.
///
/// Protocol: JSON-RPC 2.0 over newline-delimited JSON. Methods we handle:
///   - `initialize` → server info + capabilities
///   - `notifications/initialized` → client done with handshake (no response)
///   - `tools/list` → advertise OttoTools
///   - `tools/call` → run a tool via OttoToolExecutor
///   - `ping` → empty ok
final class OttoMCPServer: @unchecked Sendable {
    static let shared = OttoMCPServer()

    private var serverFd: Int32 = -1
    private(set) var socketPath: String?
    weak var appState: AppState?

    private let acceptQueue = DispatchQueue(label: "otto.mcp.accept")
    private let connectionQueue = DispatchQueue(label: "otto.mcp.conn", attributes: .concurrent)
    private var running: Bool = false

    /// One live client connection. Writes are serialized through `send` so a
    /// server-initiated notification can't interleave mid-response on the
    /// same fd. `clientName` comes from the initialize handshake's
    /// clientInfo — used to tell backends apart (Hermes brings its own
    /// approval flow; the CLIs don't).
    final class ConnectionHandle: @unchecked Sendable {
        let fd: Int32
        var clientName: String = ""
        private let writeLock = NSLock()

        init(fd: Int32) { self.fd = fd }

        func send(_ payload: Data) {
            var out = payload
            out.append(0x0A)
            writeLock.lock()
            defer { writeLock.unlock() }
            out.withUnsafeBytes { ptr in
                _ = write(fd, ptr.baseAddress, out.count)
            }
        }
    }

    /// Live connections, for server-initiated notifications
    /// (`notifications/tools/list_changed`). Guarded by `connectionsLock`.
    private var activeConnections: [Int32: ConnectionHandle] = [:]
    private let connectionsLock = NSLock()

    private init() {}

    // MARK: - Public API

    /// Call once from `AppState.init` so the server can reach tool handlers.
    func configure(appState: AppState) {
        self.appState = appState
    }

    /// Idempotent start. Binds the Otto MCP Unix socket at a stable path
    /// (`~/.otto/mcp.sock`) and begins accepting.
    ///
    /// Why a stable path (vs. the previous `/tmp/otto-mcp-<pid>-<short>.sock`)?
    /// Claude Code and Codex consume the path at runtime via `--mcp-config`,
    /// so they don't care if it changes per launch. Hermes is different — it
    /// reads `~/.hermes/config.yaml` once at startup, so the path referenced
    /// in there must survive Otto restarts. Stable path it is.
    ///
    /// Returns the socket path on success, nil on failure.
    @discardableResult
    func ensureStarted() -> String? {
        if running, let path = socketPath { return path }
        let home = NSHomeDirectory()
        let dir = "\(home)/.otto"
        do {
            try FileManager.default.createDirectory(
                atPath: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            NSLog("[MCP] failed to create ~/.otto: \(error.localizedDescription)")
            return nil
        }
        let path = "\(dir)/mcp.sock"
        guard startListener(at: path) else { return nil }
        socketPath = path
        running = true
        NSLog("[MCP] listening at \(path)")
        return path
    }

    // MARK: - Socket setup

    private func startListener(at path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            NSLog("[MCP] socket() failed: \(String(cString: strerror(errno)))")
            return false
        }
        unlink(path) // clear any stale socket file

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        // sun_path is a fixed-size CChar tuple; copy the path in via strncpy.
        path.withCString { src in
            withUnsafeMutableBytes(of: &addr.sun_path) { dst in
                let ptr = dst.bindMemory(to: CChar.self)
                _ = strncpy(ptr.baseAddress, src, 103)
            }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { aptr in
            aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sptr in
                bind(fd, sptr, size)
            }
        }
        guard bindResult == 0 else {
            NSLog("[MCP] bind() failed: \(String(cString: strerror(errno)))")
            close(fd)
            return false
        }
        // Lock the socket file down to owner-only access. Without this, the
        // socket inherits the process umask (typically 022 → 0755), which
        // would let any other process running as the same UID connect and
        // call Otto's full tool surface (search_items, read_file, delete_item,
        // plus the user-registered Supabase MCP tools). 0600 limits the
        // connectable surface to processes we explicitly fork (i.e. the
        // agent CLI under our control).
        if chmod(path, 0o600) != 0 {
            NSLog("[MCP] chmod 0600 on socket failed: \(String(cString: strerror(errno)))")
            // Not fatal — but log loudly so it surfaces in Console if it ever happens.
        }
        guard listen(fd, 5) == 0 else {
            NSLog("[MCP] listen() failed: \(String(cString: strerror(errno)))")
            close(fd)
            return false
        }
        serverFd = fd
        acceptQueue.async { [weak self] in self?.acceptLoop() }
        return true
    }

    private func acceptLoop() {
        while running {
            var clientAddr = sockaddr()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr>.size)
            let conn = accept(serverFd, &clientAddr, &clientAddrLen)
            if conn < 0 {
                if errno == EINTR { continue }
                NSLog("[MCP] accept() failed: \(String(cString: strerror(errno)))")
                break
            }
            let connFd = conn
            connectionQueue.async { [weak self] in
                self?.handleConnection(fd: connFd)
            }
        }
    }

    // MARK: - Per-connection loop

    private func handleConnection(fd: Int32) {
        let handle = ConnectionHandle(fd: fd)
        connectionsLock.lock()
        activeConnections[fd] = handle
        connectionsLock.unlock()
        defer {
            connectionsLock.lock()
            activeConnections[fd] = nil
            connectionsLock.unlock()
            close(fd)
        }
        var buffer = Data()
        var scratch = [UInt8](repeating: 0, count: 8192)

        while true {
            let n = read(fd, &scratch, scratch.count)
            if n <= 0 { break }
            buffer.append(scratch, count: n)

            while let newlineIdx = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newlineIdx)
                buffer.removeSubrange(buffer.startIndex...newlineIdx)
                if line.isEmpty { continue }
                if let response = handleMessage(line, connection: handle) {
                    handle.send(response)
                }
            }
        }
    }

    // MARK: - Server-initiated notifications

    /// Tell every connected MCP client the tool catalogue changed (a custom
    /// tab was created / reshaped / deleted), so spec-compliant clients
    /// re-fetch `tools/list` mid-session. The per-turn CLI backends get a
    /// fresh list anyway; this exists for Hermes, whose long-lived session
    /// otherwise only sees the catalogue from session start.
    func notifyToolsListChanged() {
        let note: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "notifications/tools/list_changed"
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: note) else { return }
        connectionsLock.lock()
        let handles = Array(activeConnections.values)
        connectionsLock.unlock()
        for handle in handles {
            handle.send(data)
        }
        if !handles.isEmpty {
            NSLog("[MCP] notified %d client(s): tools/list_changed", handles.count)
        }
    }

    // MARK: - JSON-RPC dispatch

    private func handleMessage(_ data: Data, connection: ConnectionHandle) -> Data? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let id = obj["id"]
        let method = obj["method"] as? String ?? ""

        switch method {
        case "initialize":
            if let params = obj["params"] as? [String: Any],
               let clientInfo = params["clientInfo"] as? [String: Any],
               let clientName = clientInfo["name"] as? String {
                connection.clientName = clientName
                NSLog("[MCP] client connected: %@", clientName)
            }
            return respond(id: id, result: [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": ["listChanged": true]],
                "serverInfo": ["name": "otto", "version": "1.0.0"]
            ])

        case "notifications/initialized",
             "notifications/cancelled":
            return nil // notifications have no response

        case "ping":
            return respond(id: id, result: [String: Any]())

        case "tools/list":
            return respond(id: id, result: ["tools": mcpToolList()])

        case "tools/call":
            guard let params = obj["params"] as? [String: Any],
                  let name = params["name"] as? String else {
                return respondError(id: id, code: -32602, message: "Invalid params")
            }
            let args = params["arguments"] as? [String: Any] ?? [:]
            let result = executeToolSync(name: name, input: args, clientName: connection.clientName)
            return respond(id: id, result: result)

        default:
            return respondError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    /// MCP tools/list schema differs from Anthropic's `tools` array by one key:
    /// `input_schema` → `inputSchema`. Everything else (name, description, JSON
    /// schema body) maps 1:1, so we just reshape.
    private func mcpToolList() -> [[String: Any]] {
        return catalogSync().map { brainTool -> [String: Any] in
            var out: [String: Any] = [:]
            if let n = brainTool["name"] { out["name"] = n }
            if let d = brainTool["description"] { out["description"] = d }
            if let s = brainTool["input_schema"] { out["inputSchema"] = s }
            return out
        }
    }

    /// Build the tool catalogue including the user's custom-tab tools. AppState
    /// is MainActor-bound, so hop over and wait — same pattern as
    /// `executeToolSync`. Each `tools/list` rebuilds fresh, so tabs created
    /// mid-run appear on the CLI's next session without an app restart.
    private func catalogSync() -> [[String: Any]] {
        guard let state = appState else { return OttoTools.catalog(customTabs: []) }
        let sem = DispatchSemaphore(value: 0)
        let box = CatalogBox()
        Task { @MainActor in
            box.value = OttoTools.catalog(customTabs: state.customTabs)
            sem.signal()
        }
        let waitResult = sem.wait(timeout: .now() + 10)
        guard waitResult == .success, let tools = box.value else {
            return OttoTools.catalog(customTabs: [])
        }
        return tools
    }

    private final class CatalogBox: @unchecked Sendable {
        var value: [[String: Any]]?
    }

    // MARK: - Destructive-tool confirmation (CLI backends)

    /// UserDefaults key: require a confirmation dialog before destructive
    /// agent tools (`delete_item`) on backends that run with approvals
    /// bypassed (Claude `--permission-mode bypassPermissions`, Codex
    /// `--dangerously-bypass-approvals-and-sandbox`). Hermes is exempt —
    /// it has its own approval-card flow. Default: on.
    static let confirmDestructiveDefaultsKey = "agent.confirmDestructiveCLI"

    private static var confirmDestructiveEnabled: Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: confirmDestructiveDefaultsKey) == nil
            ? true
            : defaults.bool(forKey: confirmDestructiveDefaultsKey)
    }

    private func needsDestructiveConfirmation(name: String, clientName: String) -> Bool {
        guard Self.confirmDestructiveEnabled else { return false }
        guard OttoTools.canonicalToolName(name) == OttoTools.Name.delete_item.rawValue else { return false }
        // Hermes announces itself in the initialize handshake and brings its
        // own session/request_permission approvals — don't double-prompt it.
        return !clientName.lowercased().contains("hermes")
    }

    /// Modal confirm for an agent-initiated deletion. Runs on the main
    /// thread; the connection thread stays blocked on the semaphore below
    /// while the user decides.
    @MainActor
    private static func confirmDeletion(input: [String: Any], appState: AppState) -> Bool {
        let type = (input["type"] as? String) ?? "item"
        let idStr = (input["id"] as? String) ?? "?"
        let title = UUID(uuidString: idStr).flatMap { itemTitle(type: type, id: $0, appState: appState) }
        let alert = NSAlert()
        alert.messageText = "Allow the agent to delete this \(type)?"
        alert.informativeText = title.map { "\u{201C}\($0)\u{201D}" } ?? "id \(idStr)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Best-effort item title for the confirm dialog.
    @MainActor
    private static func itemTitle(type: String, id: UUID, appState: AppState) -> String? {
        switch type {
        case "todo":      return appState.todos.first { $0.id == id }?.title
        case "note":      return appState.notes.first { $0.id == id }?.title
        case "idea":      return appState.ideas.first { $0.id == id }?.title
        case "reminder":  return appState.reminders.first { $0.id == id }?.title
        case "bookmark":  return appState.bookmarks.first { $0.id == id }?.title
        case "meeting":   return appState.meetings.first { $0.id == id }?.title
        case "habit":     return appState.habits.first { $0.id == id }?.title
        case "file":      return appState.files.first { $0.id == id }?.name
        case "network":   return appState.networkEntries.first { $0.id == id }?.name
        case "company":   return appState.companies.first { $0.id == id }?.name
        case "event":     return appState.events.first { $0.id == id }?.name
        case "community": return appState.communities.first { $0.id == id }?.name
        default:
            if let record = appState.customRecords.first(where: { $0.id == id }),
               let tab = appState.customTabs.first(where: { $0.id == record.tabId }) {
                return record.displayTitle(in: tab)
            }
            return nil
        }
    }

    /// Hop to MainActor, run the tool via `OttoToolExecutor`, wait for result.
    /// Connection-queue threads block on this (expected — MCP tool calls are
    /// request/response, the CLI waits on them too). 30s timeout to avoid a
    /// hung executor permanently holding the connection — stretched to 180s
    /// when a destructive-tool confirmation dialog is waiting on the user.
    private func executeToolSync(name: String, input: [String: Any], clientName: String = "") -> [String: Any] {
        guard let state = appState else {
            return errorResult("Otto app state unavailable")
        }
        let gated = needsDestructiveConfirmation(name: name, clientName: clientName)
        let sem = DispatchSemaphore(value: 0)
        let resultBox = ResultBox()
        Task { @MainActor in
            if gated, !Self.confirmDeletion(input: input, appState: state) {
                resultBox.value = OttoToolExecutor.ToolResult(
                    content: "The user declined this deletion. Do not retry it; ask what they'd like to do instead.",
                    isError: true,
                    summary: "Deletion declined by user"
                )
                sem.signal()
                return
            }
            let executor = OttoToolExecutor(appState: state)
            let r = await executor.execute(name: name, input: input)
            resultBox.value = r
            sem.signal()
        }
        let waitResult = sem.wait(timeout: .now() + (gated ? 180 : 30))
        guard waitResult == .success, let r = resultBox.value else {
            return errorResult("Tool execution timed out")
        }
        return [
            "content": [["type": "text", "text": r.content]],
            "isError": r.isError
        ]
    }

    private func errorResult(_ message: String) -> [String: Any] {
        return [
            "content": [["type": "text", "text": message]],
            "isError": true
        ]
    }

    // MARK: - Response builders

    private func respond(id: Any?, result: [String: Any]) -> Data? {
        var obj: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id = id { obj["id"] = id }
        return try? JSONSerialization.data(withJSONObject: obj)
    }

    private func respondError(id: Any?, code: Int, message: String) -> Data? {
        var obj: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message]
        ]
        if let id = id { obj["id"] = id }
        return try? JSONSerialization.data(withJSONObject: obj)
    }

    private final class ResultBox: @unchecked Sendable {
        var value: OttoToolExecutor.ToolResult?
    }
}
