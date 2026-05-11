import Foundation
import Darwin

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

    private init() {}

    // MARK: - Public API

    /// Call once from `AppState.init` so the server can reach tool handlers.
    func configure(appState: AppState) {
        self.appState = appState
    }

    /// Idempotent start. Binds a fresh Unix socket under /tmp and begins accepting.
    /// Returns the socket path on success, nil on failure.
    @discardableResult
    func ensureStarted() -> String? {
        if running, let path = socketPath { return path }
        let pid = ProcessInfo.processInfo.processIdentifier
        let short = UUID().uuidString.prefix(8)
        let path = "/tmp/otto-mcp-\(pid)-\(short).sock"
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
        defer { close(fd) }
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
                if let response = handleMessage(line) {
                    var out = response
                    out.append(0x0A)
                    out.withUnsafeBytes { ptr in
                        _ = write(fd, ptr.baseAddress, out.count)
                    }
                }
            }
        }
    }

    // MARK: - JSON-RPC dispatch

    private func handleMessage(_ data: Data) -> Data? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let id = obj["id"]
        let method = obj["method"] as? String ?? ""

        switch method {
        case "initialize":
            return respond(id: id, result: [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [String: Any]()],
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
            let result = executeToolSync(name: name, input: args)
            return respond(id: id, result: result)

        default:
            return respondError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    /// MCP tools/list schema differs from Anthropic's `tools` array by one key:
    /// `input_schema` → `inputSchema`. Everything else (name, description, JSON
    /// schema body) maps 1:1, so we just reshape.
    private func mcpToolList() -> [[String: Any]] {
        return OttoTools.all.map { brainTool -> [String: Any] in
            var out: [String: Any] = [:]
            if let n = brainTool["name"] { out["name"] = n }
            if let d = brainTool["description"] { out["description"] = d }
            if let s = brainTool["input_schema"] { out["inputSchema"] = s }
            return out
        }
    }

    /// Hop to MainActor, run the tool via `OttoToolExecutor`, wait for result.
    /// Connection-queue threads block on this (expected — MCP tool calls are
    /// request/response, the CLI waits on them too). 30s timeout to avoid a
    /// hung executor permanently holding the connection.
    private func executeToolSync(name: String, input: [String: Any]) -> [String: Any] {
        guard let state = appState else {
            return errorResult("Otto app state unavailable")
        }
        let sem = DispatchSemaphore(value: 0)
        let resultBox = ResultBox()
        Task { @MainActor in
            let executor = OttoToolExecutor(appState: state)
            let r = await executor.execute(name: name, input: input)
            resultBox.value = r
            sem.signal()
        }
        let waitResult = sem.wait(timeout: .now() + 30)
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
