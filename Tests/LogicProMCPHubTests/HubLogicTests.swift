import Foundation
import Testing
@testable import LogicProMCPHubCore

@Test func idMapRewritesIdsAndProgressTokensAndMapsBack() {
    var ids = IdMap()
    let a = ids.register(session: "A", original: .int(1), progressToken: .string("tok"))
    let b = ids.register(session: "B", original: .int(1), progressToken: nil)   // same client id, other session
    #expect(a.id != b.id)

    let req: JSONObject = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                           "params": ["name": "x", "_meta": ["progressToken": "tok"]] as JSONObject]
    let out = Rewrite.request(req, entry: a.entry, id: a.id)
    #expect(out["id"] as? Int == a.id)
    let token = ((out["params"] as? JSONObject)?["_meta"] as? JSONObject)?["progressToken"] as? String
    #expect(token == "hub-\(a.id)")
    #expect(Rewrite.progressToken(of: req) == .string("tok"))

    // progress from the child goes back to A with its original token
    let progress: JSONObject = ["method": "notifications/progress", "params": ["progressToken": "hub-\(a.id)", "progress": 5] as JSONObject]
    let routed = Rewrite.progress(progress, ids: ids)
    #expect(routed?.session == "A")
    #expect((routed?.message["params"] as? JSONObject)?["progressToken"] as? String == "tok")
    // unknown token: dropped
    #expect(Rewrite.progress(["params": ["progressToken": "hub-999"] as JSONObject], ids: ids) == nil)

    // response restores the original id
    let resp = Rewrite.response(["jsonrpc": "2.0", "id": a.id, "result": JSONObject()], entry: a.entry)
    #expect(resp["id"] as? Int == 1)

    // completing releases the mappings
    #expect(ids.complete(a.id) == a.entry)
    #expect(ids.globalID(session: "A", original: .int(1)) == nil)
    #expect(ids.progressOwner(hubToken: "hub-\(a.id)") == nil)
    #expect(ids.pendingCount == 1)
    #expect(ids.drain().count == 1)
    #expect(ids.pendingCount == 0)
}

@Test func cancelledRequestIdIsMappedAndUnknownIsDropped() {
    var ids = IdMap()
    let a = ids.register(session: "A", original: .string("req-7"), progressToken: nil)
    let cancel: JSONObject = ["method": "notifications/cancelled", "params": ["requestId": "req-7", "reason": "x"] as JSONObject]
    let out = Rewrite.cancel(cancel, session: "A", ids: ids)
    #expect((out?["params"] as? JSONObject)?["requestId"] as? Int == a.id)
    #expect((out?["params"] as? JSONObject)?["reason"] as? String == "x")
    #expect(Rewrite.cancel(cancel, session: "B", ids: ids) == nil)       // another session's id space
    _ = ids.complete(a.id)
    #expect(Rewrite.cancel(cancel, session: "A", ids: ids) == nil)       // already answered
}

@Test func rpcIDRejectsBoolAndAcceptsStringAndInt() {
    #expect(RPCID("a") == .string("a"))
    #expect(RPCID(NSNumber(value: 3)) == .int(3))
    #expect(RPCID(NSNumber(value: true)) == nil)
    #expect(RPCID(NSNull()) == nil)
    #expect(RPCID(nil) == nil)
}

@Test func subscriptionRefcountForwardsOnlyFirstAndLast() {
    var s = Subscriptions()
    #expect(s.subscribe(session: "A", uri: "u") == true)
    #expect(s.subscribe(session: "B", uri: "u") == false)
    #expect(s.subscribe(session: "B", uri: "u") == false)       // idempotent
    #expect(s.unsubscribe(session: "A", uri: "u") == false)
    #expect(s.unsubscribe(session: "A", uri: "u") == false)     // not subscribed: nothing to forward
    #expect(s.unsubscribe(session: "B", uri: "u") == true)
    #expect(s.uris.isEmpty)

    _ = s.subscribe(session: "A", uri: "x"); _ = s.subscribe(session: "A", uri: "y"); _ = s.subscribe(session: "B", uri: "y")
    #expect(s.remove(session: "A") == ["x"])                    // y still has B
    #expect(s.subscribers("y") == ["B"])
}

@Test func resourceUpdatedGoesOnlyToSubscribersWithAStreamOthersToAllStreams() {
    var s = Subscriptions()
    _ = s.subscribe(session: "A", uri: "u"); _ = s.subscribe(session: "B", uri: "u"); _ = s.subscribe(session: "C", uri: "v")
    let streams: Set<String> = ["A", "C", "D"]                  // B subscribed but has no open stream
    #expect(NotificationRouting.targets(method: "notifications/resources/updated", params: ["uri": "u"],
                                        subscriptions: s, withStream: streams) == ["A"])
    #expect(NotificationRouting.targets(method: "notifications/resources/updated", params: nil,
                                        subscriptions: s, withStream: streams).isEmpty)
    #expect(NotificationRouting.targets(method: "notifications/tools/list_changed", params: nil,
                                        subscriptions: s, withStream: streams) == streams)
}

@Test func protocolVersionPick() {
    #expect(HubProtocol.pickVersion(requested: "2025-06-18") == "2025-06-18")
    #expect(HubProtocol.pickVersion(requested: "2024-11-05") == "2024-11-05")
    #expect(HubProtocol.pickVersion(requested: "2030-01-01") == "2025-11-25")
    #expect(HubProtocol.pickVersion(requested: nil) == "2025-11-25")
}

@Test func originCheck() {
    #expect(OriginCheck.isAllowed(nil))
    #expect(OriginCheck.isAllowed("http://localhost:3000"))
    #expect(OriginCheck.isAllowed("http://127.0.0.1:47731"))
    #expect(OriginCheck.isAllowed("http://[::1]:8080"))
    #expect(!OriginCheck.isAllowed("https://evil.example"))
    #expect(!OriginCheck.isAllowed("http://localhost.evil.example"))
    #expect(!OriginCheck.isAllowed("null"))
    #expect(!OriginCheck.isAllowed(""))
}

@Test func sessionTableCreateAttachReplaceRemove() {
    var t = SessionTable<Int>()
    let a = t.create(), b = t.create()
    #expect(a != b && t.contains(a))
    #expect(!t.attach(1, to: "nope").found)
    #expect(t.attach(1, to: a).old == nil)
    #expect(t.attach(2, to: a).old == 1)                         // a new GET replaces the old stream
    #expect(t.withStream == [a])
    t.detach(a)
    #expect(t.withStream.isEmpty && t.contains(a))
    _ = t.attach(3, to: b)
    let removed = t.remove(b)
    #expect(removed.found && removed.stream == 3)
    #expect(!t.contains(b) && !t.remove(b).found)
}

@Test func httpParserHandlesPartialCompleteAndInvalid() {
    let full = "POST /mcp HTTP/1.1\r\nHost: x\r\nOrigin: http://localhost\r\nContent-Length: 5\r\n\r\nhello"
    #expect(HTTPRequestParser.parse(Data(full.utf8.dropLast(2))) == .incomplete)
    guard case .complete(let req) = HTTPRequestParser.parse(Data(full.utf8)) else { Issue.record("not complete"); return }
    #expect(req.method == "POST" && req.path == "/mcp" && req.body == Data("hello".utf8))
    #expect(req.headers["origin"] == "http://localhost")
    #expect(HTTPRequestParser.parse(Data("garbage\r\n\r\n".utf8)) == .invalid)
    #expect(HTTPRequestParser.parse(Data("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)) == .invalid)
}

@Test func configFromEnvironment() {
    let dir = URL(fileURLWithPath: "/opt/hub/bin")
    let d = HubConfig.from(environment: [:], executableDir: dir)
    #expect(d.port == HubConfig.defaultPort && d.idleSeconds == 600 && d.childPath == "/opt/hub/bin/LogicProMCP")
    #expect(d.logPath.hasSuffix("/Library/Logs/LogicProMCPHub/hub.log"))
    let e = HubConfig.from(environment: ["LOGIC_PRO_MCP_HUB_PORT": "5000", "LOGIC_PRO_MCP_HUB_IDLE_SECONDS": "2",
                                         "LOGIC_PRO_MCP_HUB_LOG": "/tmp/h.log", "LOGIC_PRO_MCP_HUB_CHILD": "/x/y"], executableDir: dir)
    #expect(e.port == 5000 && e.idleSeconds == 2 && e.logPath == "/tmp/h.log" && e.childPath == "/x/y")
}

@Test func bundledManifestIsHandedToTheChild() throws {
    let app = FileManager.default.temporaryDirectory.appendingPathComponent("hubtest-\(UUID().uuidString)/X.app/Contents")
    try FileManager.default.createDirectory(at: app.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: app.appendingPathComponent("Resources"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent().deletingLastPathComponent()) }
    let exeDir = app.appendingPathComponent("MacOS")

    // No manifest in Resources: environment passes through untouched.
    #expect(HubConfig.from(environment: ["A": "1"], executableDir: exeDir).childEnvironment["LOGIC_PRO_MCP_MANIFEST_PATH"] == nil)

    FileManager.default.createFile(atPath: app.appendingPathComponent("Resources/manifest.json").path, contents: Data("{}".utf8))
    let cfg = HubConfig.from(environment: ["A": "1"], executableDir: exeDir)
    #expect(cfg.childEnvironment["LOGIC_PRO_MCP_MANIFEST_PATH"] == app.appendingPathComponent("Resources/manifest.json").path)
    #expect(cfg.childEnvironment["A"] == "1")
    // An explicit setting wins.
    let explicit = HubConfig.from(environment: ["LOGIC_PRO_MCP_MANIFEST_PATH": "/mine"], executableDir: exeDir)
    #expect(explicit.childEnvironment["LOGIC_PRO_MCP_MANIFEST_PATH"] == "/mine")
}
