import Foundation
import Network

public struct HTTPRequest: Sendable, Equatable {
    public var method: String
    public var path: String
    public var headers: [String: String]   // lowercased names
    public var body: Data
}

public enum HTTPParse: Equatable {
    case incomplete
    case invalid
    case complete(HTTPRequest)
}

public enum HTTPRequestParser {
    static let maxHeaderBytes = 64 * 1024
    static let maxBodyBytes = 8 * 1024 * 1024

    /// Parses one request from the front of `buffer`. No keep-alive/pipelining: every response closes.
    public static func parse(_ buffer: Data) -> HTTPParse {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > maxHeaderBytes ? .invalid : .incomplete
        }
        guard let head = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) else { return .invalid }
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count == 3, start[2].hasPrefix("HTTP/1.") else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil { return .invalid }   // chunked request bodies are not supported
        let length = headers["content-length"].flatMap { Int($0) } ?? 0
        guard length >= 0, length <= maxBodyBytes else { return .invalid }
        let bodyStart = end.upperBound
        guard buffer.endIndex - bodyStart >= length else { return .incomplete }
        let body = Data(buffer[bodyStart..<(bodyStart + length)])
        return .complete(HTTPRequest(method: String(start[0]), path: String(start[1]), headers: headers, body: body))
    }
}

/// Minimal HTTP/1.1 front end on 127.0.0.1: POST/GET/DELETE /mcp, one request per connection.
public final class HTTPServer: @unchecked Sendable {
    private let hub: Hub
    private let log: HubLog
    private let queue = DispatchQueue(label: "logic-pro-mcp-hub.http")
    private var listener: NWListener?

    public init(hub: Hub, log: HubLog) { self.hub = hub; self.log = log }

    /// Resolves once the listener is ready (or throws if it cannot bind).
    public func start(port: UInt16) async throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        self.listener = listener
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.fire() { cont.resume() }
                case .failed(let e): if once.fire() { cont.resume(throwing: e) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        log.log("listening on 127.0.0.1:\(port)")
    }

    public func stop() { listener?.cancel() }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        read(conn, buffer: Data())
    }

    private func read(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            switch HTTPRequestParser.parse(buf) {
            case .invalid:
                self.respond(conn, 400, nil, "bad request")
            case .complete(let req):
                Task { await self.route(req, conn) }
            case .incomplete:
                if error != nil || isComplete { conn.cancel() } else { self.read(conn, buffer: buf) }
            }
        }
    }

    private func route(_ req: HTTPRequest, _ conn: NWConnection) async {
        guard OriginCheck.isAllowed(req.headers["origin"]) else {
            return respond(conn, 403, nil, "forbidden origin")
        }
        guard req.path == "/mcp" else { return respond(conn, 404, nil, "not found") }
        let session = req.headers["mcp-session-id"]
        switch req.method {
        case "POST":
            let reply = await hub.handlePost(sessionID: session, body: req.body)
            respond(conn, reply.status, reply.body, nil, sessionID: reply.sessionID)
        case "GET":
            guard req.headers["accept"]?.contains("text/event-stream") == true else {
                return respond(conn, 406, nil, "Accept: text/event-stream required")
            }
            guard let session else { return respond(conn, 400, nil, "Mcp-Session-Id header required") }
            guard let (stream, _) = await hub.openStream(sessionID: session) else {
                return respond(conn, 404, nil, "unknown session")
            }
            await serveStream(conn, stream)
        case "DELETE":
            guard let session else { return respond(conn, 400, nil, "Mcp-Session-Id header required") }
            let existed = await hub.deleteSession(session)
            respond(conn, existed ? 200 : 404, nil, existed ? "" : "unknown session")
        default:
            respond(conn, 405, nil, "method not allowed", extra: ["Allow": "POST, GET, DELETE"])
        }
    }

    private func respond(_ conn: NWConnection, _ status: Int, _ json: Data?, _ text: String?,
                         sessionID: String? = nil, extra: [String: String] = [:]) {
        let body = json ?? Data((text ?? "").utf8)
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        head += "Content-Type: \(json != nil ? "application/json" : "text/plain; charset=utf-8")\r\n"
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n"
        if let sessionID { head += "Mcp-Session-Id: \(sessionID)\r\n" }
        for (k, v) in extra { head += "\(k): \(v)\r\n" }
        var out = Data((head + "\r\n").utf8)
        if status != 202 || !body.isEmpty { out.append(body) }
        conn.send(content: out, contentContext: .finalMessage, isComplete: true,
                  completion: .contentProcessed { _ in conn.cancel() })
    }

    /// SSE: headers, then one `message` event per notification. A comment line every 20 s keeps
    /// idle proxies and clients from timing the connection out. Ends when the client goes away.
    private func serveStream(_ conn: NWConnection, _ stream: AsyncStream<Data>) async {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        await write(conn, Data(head.utf8))
        // A read that returns means the client closed (it sends nothing on a GET stream).
        let closed = AsyncStream<Void> { c in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, _, _ in c.yield(); c.finish() }
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await data in stream {
                    var event = Data("event: message\ndata: ".utf8)
                    event.append(data)
                    event.append(Data("\n\n".utf8))
                    await self.write(conn, event)
                }
            }
            group.addTask {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                    await self.write(conn, Data(": ping\n\n".utf8))
                }
            }
            group.addTask { for await _ in closed { break } }
            // First to finish (stream replaced/deleted, or client gone) ends the response.
            await group.next()
            group.cancelAll()
        }
        conn.cancel()
    }

    private func write(_ conn: NWConnection, _ data: Data) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            conn.send(content: data, completion: .contentProcessed { _ in cont.resume() })
        }
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 406: return "Not Acceptable"
        default: return "Error"
        }
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func fire() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}
