import Darwin
import Foundation
import LogicProMCPHubCore

// LogicProMCPHub: one shared Streamable-HTTP front for a single LogicProMCP child (see README, "Shared hub").
signal(SIGPIPE, SIG_IGN)

let execDir = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).deletingLastPathComponent()
let config = HubConfig.from(environment: ProcessInfo.processInfo.environment, executableDir: execDir)
let log = try HubLog(path: config.logPath)
let hub = Hub(config: config, log: log)
let server = HTTPServer(hub: hub, log: log)

do { try await server.start(port: config.port) } catch {
    log.log("cannot listen on 127.0.0.1:\(config.port): \(error)")
    FileHandle.standardError.write(Data("LogicProMCPHub: cannot listen on 127.0.0.1:\(config.port): \(error)\n".utf8))
    exit(1)
}
log.log("hub up; child=\(config.childPath) idle=\(config.idleSeconds)s")

var sources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
    src.setEventHandler {
        Task {
            log.log("signal \(sig): shutting down")
            server.stop()
            await hub.shutdown()
            try? await Task.sleep(nanoseconds: 300_000_000)
            exit(0)
        }
    }
    src.resume()
    sources.append(src)
}
// Park forever; shutdown happens in the signal handlers above.
while true { try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
