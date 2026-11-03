import Foundation

public struct HubConfig: Sendable {
    public static let defaultPort: UInt16 = 47731
    public static let defaultIdleSeconds: Double = 600

    public var port: UInt16
    public var childPath: String
    public var idleSeconds: Double
    public var logPath: String
    /// Environment handed to the child: the hub's own, plus a bundled manifest.json when running
    /// from a .app (the child otherwise looks for it by walking up from its working directory).
    public var childEnvironment: [String: String]

    public init(port: UInt16, childPath: String, idleSeconds: Double, logPath: String,
                childEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
        self.port = port; self.childPath = childPath; self.idleSeconds = idleSeconds; self.logPath = logPath
        self.childEnvironment = childEnvironment
    }

    /// LOGIC_PRO_MCP_HUB_PORT (default 47731), LOGIC_PRO_MCP_HUB_IDLE_SECONDS (default 600),
    /// LOGIC_PRO_MCP_HUB_LOG (default ~/Library/Logs/LogicProMCPHub/hub.log),
    /// LOGIC_PRO_MCP_HUB_CHILD (default: `LogicProMCP` next to `executableDir`).
    public static func from(environment env: [String: String], executableDir: URL) -> HubConfig {
        let childPath = env["LOGIC_PRO_MCP_HUB_CHILD"]
            ?? executableDir.appendingPathComponent("LogicProMCP").path
        let log = env["LOGIC_PRO_MCP_HUB_LOG"]
            ?? NSHomeDirectory() + "/Library/Logs/LogicProMCPHub/hub.log"
        var childEnv = env
        let bundled = executableDir.deletingLastPathComponent().appendingPathComponent("Resources/manifest.json").path
        if childEnv["LOGIC_PRO_MCP_MANIFEST_PATH"] == nil, FileManager.default.fileExists(atPath: bundled) {
            childEnv["LOGIC_PRO_MCP_MANIFEST_PATH"] = bundled
        }
        return HubConfig(
            port: env["LOGIC_PRO_MCP_HUB_PORT"].flatMap { UInt16($0) } ?? defaultPort,
            childPath: childPath,
            idleSeconds: env["LOGIC_PRO_MCP_HUB_IDLE_SECONDS"].flatMap { Double($0) } ?? defaultIdleSeconds,
            logPath: log,
            childEnvironment: childEnv)
    }
}

/// Append-only log shared by the hub and (as stderr) the child.
public final class HubLog: @unchecked Sendable {
    public let handle: FileHandle
    private let lock = NSLock()

    public init(path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    public func log(_ message: String) {
        let line = "[hub \(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        lock.lock(); defer { lock.unlock() }
        try? handle.write(contentsOf: Data(line.utf8))
    }
}
