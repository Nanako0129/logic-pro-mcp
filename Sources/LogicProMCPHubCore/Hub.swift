import Foundation

public struct HubReply: Sendable {
    public var status: Int
    public var body: Data?
    public var sessionID: String?
    static let accepted = HubReply(status: 202, body: nil, sessionID: nil)
    static func json(_ data: Data, session: String? = nil) -> HubReply { HubReply(status: 200, body: data, sessionID: session) }
    static func failure(_ status: Int, _ message: String) -> HubReply {
        HubReply(status: status, body: RPCError.response(id: nil, code: -32000, message: message), sessionID: nil)
    }
}

struct SessionStream {
    let token: UUID
    let continuation: AsyncStream<Data>.Continuation
}

final class ChildHandle: @unchecked Sendable {
    let generation: Int
    let process = Process()
    let stdin = Pipe()
    let stdout = Pipe()
    init(generation: Int) { self.generation = generation }

    func send(_ data: Data) throws {
        var framed = data
        framed.append(0x0A)
        try stdin.fileHandleForWriting.write(contentsOf: framed)
    }

    /// stdin EOF is the child's graceful shutdown; SIGTERM only if it lingers.
    func terminate() {
        try? stdin.fileHandleForWriting.close()
        let p = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if p.isRunning { p.terminate() } }
    }
}

/// One shared MCP server behind many Streamable-HTTP sessions: a single child LogicProMCP over stdio.
public actor Hub {
    private let config: HubConfig
    private let log: HubLog

    private var sessions = SessionTable<SessionStream>()
    private var ids = IdMap()
    private var subs = Subscriptions()

    private var child: ChildHandle?
    private var initialized = false
    private var generation = 0
    private var startTask: Task<Void, Error>?
    private var cachedInitResult: Data?           // serialized `result` of the child's initialize

    private var clientWaiters: [Int: CheckedContinuation<Data, Never>] = [:]
    private var internalWaiters: [Int: CheckedContinuation<Data?, Never>] = [:]
    private var lastActivity = Date()
    private var idleTask: Task<Void, Never>?

    public init(config: HubConfig, log: HubLog) {
        self.config = config
        self.log = log
    }

    // MARK: - HTTP-facing entry points

    public func handlePost(sessionID: String?, body: Data) async -> HubReply {
        touch()
        defer { touch() }
        guard let parsed = try? JSONSerialization.jsonObject(with: body) else {
            return .json(RPCError.response(id: nil, code: -32700, message: "parse error"))
        }
        guard let msg = parsed as? JSONObject else {
            return .failure(400, "JSON-RPC batches are not supported")
        }
        let method = msg["method"] as? String
        let rawID = msg["id"]

        if method == "initialize", rawID != nil {
            return await handleInitialize(msg)
        }
        guard let sessionID else { return .failure(400, "Mcp-Session-Id header required") }
        guard sessions.contains(sessionID) else { return .failure(404, "unknown session") }

        guard let method else { return .accepted }               // a response from the client: we never send requests
        guard rawID != nil else {                                // notification
            if method == "notifications/cancelled",
               let fwd = Rewrite.cancel(msg, session: sessionID, ids: ids), child != nil, initialized {
                send(fwd)
                // swift-sdk 0.12.1 sends no response for a cancelled request (Server.swift ~794-835), so the hub finishes it here:
                // left pending, it would hold its POST open forever and keep idleCheck (pendingCount == 0) from ever stopping the
                // child. A late response from the child finds no entry and is dropped.
                if let gid = (fwd["params"] as? JSONObject)?["requestId"] as? Int, let entry = ids.complete(gid),
                   let waiter = clientWaiters.removeValue(forKey: gid) {
                    waiter.resume(returning: RPCError.response(id: entry.original.any, code: -32800, message: "request cancelled"))
                    touch()
                }
            }
            return .accepted
        }
        guard let original = RPCID(rawID) else {
            return .json(RPCError.response(id: nil, code: -32600, message: "invalid request id"))
        }

        switch method {
        case "ping":
            return .json(Self.encode(["jsonrpc": "2.0", "id": original.any, "result": JSONObject()]))
        case "resources/subscribe":
            guard let uri = (msg["params"] as? JSONObject)?["uri"] as? String else {
                return .json(RPCError.response(id: original.any, code: -32602, message: "uri required"))
            }
            if subs.subscribe(session: sessionID, uri: uri) {
                let reply = await forward(msg, session: sessionID, original: original)
                if Self.isError(reply) { _ = subs.unsubscribe(session: sessionID, uri: uri) }
                return .json(reply)
            }
            return .json(Self.encode(["jsonrpc": "2.0", "id": original.any, "result": JSONObject()]))
        case "resources/unsubscribe":
            guard let uri = (msg["params"] as? JSONObject)?["uri"] as? String else {
                return .json(RPCError.response(id: original.any, code: -32602, message: "uri required"))
            }
            if subs.unsubscribe(session: sessionID, uri: uri) {
                return .json(await forward(msg, session: sessionID, original: original))
            }
            return .json(Self.encode(["jsonrpc": "2.0", "id": original.any, "result": JSONObject()]))
        default:
            return .json(await forward(msg, session: sessionID, original: original))
        }
    }

    public func openStream(sessionID: String) -> (stream: AsyncStream<Data>, token: UUID)? {
        guard sessions.contains(sessionID) else { return nil }
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let token = UUID()
        continuation.onTermination = { [weak self] _ in
            Task { await self?.streamClosed(session: sessionID, token: token) }
        }
        let attached = sessions.attach(SessionStream(token: token, continuation: continuation), to: sessionID)
        attached.old?.continuation.finish()
        return (stream, token)
    }

    public func deleteSession(_ id: String) async -> Bool {
        let removed = sessions.remove(id)
        guard removed.found else { return false }
        removed.stream?.continuation.finish()
        for uri in subs.remove(session: id) where child != nil && initialized {
            log.log("child <- resources/unsubscribe \(uri) (last subscriber left)")
            send(["jsonrpc": "2.0", "id": ids.freshID(), "method": "resources/unsubscribe", "params": ["uri": uri]])
        }
        touch()
        return true
    }

    public func shutdown() {
        idleTask?.cancel()
        stopChild(reason: "hub shutdown")
    }

    private func streamClosed(session: String, token: UUID) {
        if sessions.stream(of: session)?.token == token { sessions.detach(session) }
    }

    // MARK: - initialize (answered from the cache)

    private func handleInitialize(_ msg: JSONObject) async -> HubReply {
        let id = msg["id"]
        do { try await ensureChild() } catch {
            log.log("child start failed: \(error)")
            return .json(RPCError.response(id: id, code: -32603, message: "hub could not start the server: \(error)"))
        }
        guard let cached = cachedInitResult,
              var result = (try? JSONSerialization.jsonObject(with: cached)) as? JSONObject else {
            return .json(RPCError.response(id: id, code: -32603, message: "no cached initialize result"))
        }
        let requested = ((msg["params"] as? JSONObject)?["protocolVersion"] as? String)
        result["protocolVersion"] = HubProtocol.pickVersion(requested: requested)
        let session = sessions.create()
        log.log("session \(session) initialized (protocol \(result["protocolVersion"] ?? "?"))")
        return .json(Self.encode(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]), session: session)
    }

    // MARK: - Forwarding

    private func forward(_ msg: JSONObject, session: String, original: RPCID) async -> Data {
        do { try await ensureChild() } catch {
            log.log("child start failed: \(error)")
            return RPCError.response(id: original.any, code: -32603, message: "hub could not start the server: \(error)")
        }
        let (gid, entry) = ids.register(session: session, original: original, progressToken: Rewrite.progressToken(of: msg))
        let out = Rewrite.request(msg, entry: entry, id: gid)
        if let method = msg["method"] as? String, method.hasPrefix("resources/") && method.hasSuffix("subscribe") {
            log.log("child <- \(method) \((msg["params"] as? JSONObject)?["uri"] ?? "")")
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<Data, Never>) in
            clientWaiters[gid] = cont
            if !send(out) {
                _ = ids.complete(gid)
                clientWaiters.removeValue(forKey: gid)
                cont.resume(returning: RPCError.response(id: original.any, code: -32603, message: "server process unavailable"))
            }
        }
    }

    @discardableResult
    private func send(_ msg: JSONObject) -> Bool {
        guard let child else { return false }
        do { try child.send(Self.encode(msg)); return true } catch {
            log.log("write to child failed: \(error)")
            return false
        }
    }

    // MARK: - Child output

    private func childLine(generation gen: Int, line: Data) {
        guard gen == child?.generation, let msg = (try? JSONSerialization.jsonObject(with: line)) as? JSONObject else { return }
        let method = msg["method"] as? String
        let rawID = msg["id"]

        if method == nil, let id = RPCID(rawID), case .int(let gid) = id {
            if let waiter = internalWaiters.removeValue(forKey: gid) { waiter.resume(returning: line); return }
            guard let entry = ids.complete(gid), let waiter = clientWaiters.removeValue(forKey: gid) else { return }
            waiter.resume(returning: Self.encode(Rewrite.response(msg, entry: entry)))
            touch()
            return
        }
        guard let method else { return }
        if rawID != nil {   // the server never sends requests (verified in LogicProServer.swift); refuse politely
            log.log("unexpected request from child: \(method)")
            send(["jsonrpc": "2.0", "id": rawID!, "error": ["code": -32601, "message": "method not found"] as JSONObject])
            return
        }
        if method == "notifications/progress" {
            if let (session, out) = Rewrite.progress(msg, ids: ids) { deliver(Self.encode(out), to: [session]) }
            return
        }
        let targets = NotificationRouting.targets(
            method: method, params: msg["params"] as? JSONObject, subscriptions: subs, withStream: sessions.withStream)
        deliver(line, to: targets)
    }

    private func deliver(_ data: Data, to targets: Set<String>) {
        for id in targets { sessions.stream(of: id)?.continuation.yield(data) }
    }

    private func childExited(generation gen: Int) {
        guard gen == child?.generation else { return }
        log.log("child exited unexpectedly (generation \(gen))")
        child = nil
        initialized = false
        let message = "server process exited"
        for (gid, entry) in ids.drain() {
            clientWaiters.removeValue(forKey: gid)?.resume(returning: RPCError.response(id: entry.original.any, code: -32603, message: message))
        }
        for (_, waiter) in internalWaiters { waiter.resume(returning: nil) }
        internalWaiters = [:]
    }

    // MARK: - Child lifecycle

    private func ensureChild() async throws {
        if child != nil && initialized { return }
        if let startTask { return try await startTask.value }
        let task = Task { try await self.startChild() }
        startTask = task
        defer { startTask = nil }
        try await task.value
    }

    private func startChild() async throws {
        generation += 1
        let handle = ChildHandle(generation: generation)
        let p = handle.process
        p.executableURL = URL(fileURLWithPath: config.childPath)
        p.environment = config.childEnvironment
        p.standardInput = handle.stdin
        p.standardOutput = handle.stdout
        p.standardError = log.handle
        try p.run()
        child = handle
        log.log("child started pid \(p.processIdentifier) (generation \(handle.generation))")

        let (lines, continuation) = AsyncStream<Data>.makeStream()
        let readHandle = handle.stdout.fileHandleForReading
        Thread.detachNewThread {
            var pending = Data()
            while true {
                let chunk = readHandle.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let nl = pending.firstIndex(of: 0x0A) {
                    let frame = pending[pending.startIndex..<nl]
                    pending = Data(pending[(nl + 1)...])
                    if !frame.isEmpty { continuation.yield(Data(frame)) }
                }
            }
            continuation.finish()
        }
        let gen = handle.generation
        Task { [weak self] in
            for await line in lines { await self?.childLine(generation: gen, line: line) }
            await self?.childExited(generation: gen)
        }

        let initParams: JSONObject = [
            "protocolVersion": HubProtocol.latest,
            "capabilities": JSONObject(),         // no `experimental`: swift-sdk cannot decode object values there
            "clientInfo": ["name": "logic-pro-mcp-hub", "version": "1"] as JSONObject,
        ]
        guard let reply = await internalRequest("initialize", initParams),
              let obj = (try? JSONSerialization.jsonObject(with: reply)) as? JSONObject,
              let result = obj["result"] as? JSONObject else {
            stopChild(reason: "initialize failed")
            throw HubError.initializeFailed
        }
        cachedInitResult = Self.encode(result)
        send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        initialized = true
        for uri in subs.uris {
            log.log("child <- resources/subscribe \(uri) (re-subscribe after respawn)")
            _ = await internalRequest("resources/subscribe", ["uri": uri])
        }
    }

    private func internalRequest(_ method: String, _ params: JSONObject, timeout: Double = 30) async -> Data? {
        let gid = ids.freshID()
        return await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            internalWaiters[gid] = cont
            if !send(["jsonrpc": "2.0", "id": gid, "method": method, "params": params]) {
                internalWaiters.removeValue(forKey: gid)?.resume(returning: nil)
                return
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
                await self?.expireInternal(gid)
            }
        }
    }

    private func expireInternal(_ gid: Int) { internalWaiters.removeValue(forKey: gid)?.resume(returning: nil) }

    private func stopChild(reason: String) {
        guard let c = child else { return }
        log.log("stopping child: \(reason)")
        child = nil            // its EOF handler now sees a stale generation and does nothing
        initialized = false
        c.terminate()
        for (_, waiter) in internalWaiters { waiter.resume(returning: nil) }
        internalWaiters = [:]
    }

    // MARK: - Idle shutdown

    private func touch() {
        lastActivity = Date()
        idleTask?.cancel()
        let delay = config.idleSeconds
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
            if !Task.isCancelled { await self?.idleCheck() }
        }
    }

    private func idleCheck() {
        guard child != nil, startTask == nil, ids.pendingCount == 0,
              Date().timeIntervalSince(lastActivity) >= config.idleSeconds * 0.99 else { return }
        stopChild(reason: "idle for \(Int(config.idleSeconds))s")
    }

    // MARK: - Helpers

    static func encode(_ obj: JSONObject) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
    }

    static func isError(_ data: Data) -> Bool {
        ((try? JSONSerialization.jsonObject(with: data)) as? JSONObject)?["error"] != nil
    }
}

enum HubError: Error { case initializeFailed }
