import Foundation

// Pure parts of the hub: no I/O, no actors, so each is unit-testable on its own.

/// JSON-RPC id (string or integer). Anything else (null, float, bool) is not a valid request id.
public enum RPCID: Hashable, Sendable {
    case int(Int)
    case string(String)

    public init?(_ any: Any?) {
        if let s = any as? String { self = .string(s); return }
        if let n = any as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
           n.doubleValue == Double(n.intValue) { self = .int(n.intValue); return }
        return nil
    }

    public var any: Any {
        switch self {
        case .int(let i): return i
        case .string(let s): return s
        }
    }
}

public typealias JSONObject = [String: Any]

public enum HubProtocol {
    /// Mirrors swift-sdk 0.12.1 `Version.supported` (.build/checkouts/swift-sdk/Sources/MCP/Base/Versioning.swift).
    /// The child is a swift-sdk server, so these are the versions it can speak. Newest first.
    public static let supported = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    public static var latest: String { supported[0] }

    /// Spec: answer with the client's version if the server supports it, otherwise the server's latest.
    public static func pickVersion(requested: String?) -> String {
        if let requested, supported.contains(requested) { return requested }
        return latest
    }
}

public enum OriginCheck {
    /// DNS-rebinding protection: an Origin header, when present, must name a loopback host.
    public static func isAllowed(_ origin: String?) -> Bool {
        guard let origin else { return true }
        guard let host = URLComponents(string: origin)?.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }
}

/// Hub-global request ids toward the child, mapped back to (session, original id); and the same for
/// progress tokens. `register` hands out a unique id per forwarded client request.
public struct IdMap {
    public struct Entry: Equatable {
        public let session: String
        public let original: RPCID
        public let hubToken: String?
        public let originalToken: RPCID?
    }
    private struct Key: Hashable { let session: String; let id: RPCID }

    private var next = 0
    private var pending: [Int: Entry] = [:]
    private var byClient: [Key: Int] = [:]
    private var tokens: [String: Int] = [:]

    public init() {}

    public var pendingCount: Int { pending.count }

    /// A fresh id for hub-originated requests (initialize, re-subscribe); not tracked in `pending`.
    public mutating func freshID() -> Int { next += 1; return next }

    public mutating func register(session: String, original: RPCID, progressToken: RPCID?) -> (id: Int, entry: Entry) {
        let gid = freshID()
        let hubToken = progressToken == nil ? nil : "hub-\(gid)"
        let entry = Entry(session: session, original: original, hubToken: hubToken, originalToken: progressToken)
        pending[gid] = entry
        byClient[Key(session: session, id: original)] = gid
        if let hubToken { tokens[hubToken] = gid }
        return (gid, entry)
    }

    public mutating func complete(_ gid: Int) -> Entry? {
        guard let entry = pending.removeValue(forKey: gid) else { return nil }
        byClient.removeValue(forKey: Key(session: entry.session, id: entry.original))
        if let t = entry.hubToken { tokens.removeValue(forKey: t) }
        return entry
    }

    public func globalID(session: String, original: RPCID) -> Int? {
        byClient[Key(session: session, id: original)]
    }

    public func progressOwner(hubToken: String) -> Entry? {
        tokens[hubToken].flatMap { pending[$0] }
    }

    public mutating func drain() -> [(id: Int, entry: Entry)] {
        let all = pending.map { (id: $0.key, entry: $0.value) }
        pending = [:]; byClient = [:]; tokens = [:]
        return all
    }
}

/// Message rewriting between client ids and hub-global ids.
public enum Rewrite {
    public static func progressToken(of msg: JSONObject) -> RPCID? {
        ((msg["params"] as? JSONObject)?["_meta"] as? JSONObject).flatMap { RPCID($0["progressToken"]) }
    }

    /// Client request -> child: id and `params._meta.progressToken` replaced by the hub's.
    public static func request(_ msg: JSONObject, entry: Entry, id: Int) -> JSONObject {
        var out = msg
        out["id"] = id
        if let token = entry.hubToken, var params = out["params"] as? JSONObject,
           var meta = params["_meta"] as? JSONObject {
            meta["progressToken"] = token
            params["_meta"] = meta
            out["params"] = params
        }
        return out
    }
    public typealias Entry = IdMap.Entry

    /// `notifications/cancelled` client -> child: `requestId` mapped to the hub id; nil when the
    /// request is unknown (already answered), in which case the notification is dropped.
    public static func cancel(_ msg: JSONObject, session: String, ids: IdMap) -> JSONObject? {
        guard var params = msg["params"] as? JSONObject,
              let original = RPCID(params["requestId"]),
              let gid = ids.globalID(session: session, original: original) else { return nil }
        params["requestId"] = gid
        var out = msg
        out["params"] = params
        return out
    }

    /// Child response -> client: the original id restored.
    public static func response(_ msg: JSONObject, entry: Entry) -> JSONObject {
        var out = msg
        out["id"] = entry.original.any
        return out
    }

    /// `notifications/progress` child -> client: owner session and the message with the original token.
    public static func progress(_ msg: JSONObject, ids: IdMap) -> (session: String, message: JSONObject)? {
        guard var params = msg["params"] as? JSONObject,
              let hubToken = params["progressToken"] as? String,
              let entry = ids.progressOwner(hubToken: hubToken),
              let original = entry.originalToken else { return nil }
        params["progressToken"] = original.any
        var out = msg
        out["params"] = params
        return (entry.session, out)
    }
}

/// Resource subscriptions with a refcount per URI across sessions.
public struct Subscriptions {
    private var byURI: [String: Set<String>] = [:]
    public init() {}

    public var uris: [String] { Array(byURI.keys) }
    public func subscribers(_ uri: String) -> Set<String> { byURI[uri] ?? [] }

    /// True when this is the URI's first subscriber (forward to the child).
    public mutating func subscribe(session: String, uri: String) -> Bool {
        let first = byURI[uri] == nil
        byURI[uri, default: []].insert(session)
        return first
    }

    /// True when the session was the URI's last subscriber (forward to the child).
    public mutating func unsubscribe(session: String, uri: String) -> Bool {
        guard var set = byURI[uri], set.remove(session) != nil else { return false }
        if set.isEmpty { byURI.removeValue(forKey: uri); return true }
        byURI[uri] = set
        return false
    }

    /// Drops a session; returns the URIs that lost their last subscriber.
    public mutating func remove(session: String) -> [String] {
        uris.filter { unsubscribe(session: session, uri: $0) }
    }
}

public enum NotificationRouting {
    /// Sessions that receive a child notification (other than progress, which has one owner).
    /// `resources/updated` goes only to subscribers of that URI; everything else to every session.
    /// Both are intersected with `withStream`: no open GET stream, no delivery.
    public static func targets(method: String, params: JSONObject?, subscriptions: Subscriptions,
                               withStream: Set<String>) -> Set<String> {
        if method == "notifications/resources/updated" {
            guard let uri = params?["uri"] as? String else { return [] }
            return subscriptions.subscribers(uri).intersection(withStream)
        }
        return withStream
    }
}

/// Session table. `Stream` is whatever the hub keeps for an open GET stream.
public struct SessionTable<Stream> {
    private var sessions: [String: Stream?] = [:]
    public init() {}

    public func contains(_ id: String) -> Bool { sessions[id] != nil }
    public var ids: Set<String> { Set(sessions.keys) }
    public var withStream: Set<String> { Set(sessions.compactMap { $0.value != nil ? $0.key : nil }) }

    public mutating func create() -> String {
        let id = UUID().uuidString
        sessions[id] = .some(nil)
        return id
    }

    /// Attaches a stream; `old` is the stream it replaced. `found` is false for an unknown session.
    public mutating func attach(_ stream: Stream, to id: String) -> (found: Bool, old: Stream?) {
        guard let current = sessions[id] else { return (false, nil) }
        sessions[id] = .some(stream)
        return (true, current)
    }

    public func stream(of id: String) -> Stream? { sessions[id] ?? nil }
    public mutating func detach(_ id: String) { if sessions[id] != nil { sessions[id] = .some(nil) } }

    public mutating func remove(_ id: String) -> (found: Bool, stream: Stream?) {
        guard let old = sessions.removeValue(forKey: id) else { return (false, nil) }
        return (true, old)
    }
}

public enum RPCError {
    public static func response(id: Any?, code: Int, message: String) -> Data {
        let obj: JSONObject = ["jsonrpc": "2.0", "id": id ?? NSNull(),
                               "error": ["code": code, "message": message] as JSONObject]
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    }
}
