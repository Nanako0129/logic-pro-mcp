import AppKit
import Foundation
import Testing
@testable import LogicProMCP

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    private var up = false
    func bump() -> Bool { lock.lock(); defer { lock.unlock() }; n += 1; return false }
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    var logicUp: Bool { get { lock.lock(); defer { lock.unlock() }; return up } set { lock.lock(); up = newValue; lock.unlock() } }
}

private func idleRuntime(
    windows: Counter, idles: Counter, gate: AsyncStream<Void>? = nil
) -> StatePoller.Runtime {
    var runtime = StatePoller.Runtime(
        hasVisibleWindow: { windows.bump() },
        sleep: { _ in try await Task.sleep(nanoseconds: 1_000_000) }
    )
    runtime.logicRunning = { windows.logicUp }
    runtime.idleWait = { _ in
        _ = idles.bump()
        if let gate { for await _ in gate { return } }
        else { try await Task.sleep(nanoseconds: 20_000_000) }
    }
    return runtime
}

private func waitFor(_ condition: @escaping @Sendable () async -> Bool) async throws -> Bool {
    for _ in 0..<400 {
        if await condition() { return true }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    return false
}

@Test func testPollerRecordsClosedDocumentThenIdlesWhileLogicIsNotRunning() async throws {
    let cache = StateCache()
    var project = ProjectInfo()
    project.name = "Old Session"
    await cache.updateProject(project)
    await cache.updateTracks([TrackState(id: 0, name: "Old Track", type: .audio)])
    let windows = Counter(), idles = Counter()
    let poller = StatePoller(
        axChannel: AccessibilityChannel(runtime: .production),
        cache: cache,
        runtime: idleRuntime(windows: windows, idles: idles)
    )
    await poller.start()
    // The running->stopped transition still ends with the cache reporting the document closed...
    #expect(try await waitFor { !(await cache.getHasDocument()) })
    // ...after exactly failureThreshold (3) cycles, and then no cycle runs again.
    #expect(try await waitFor { idles.count >= 3 })
    #expect(windows.count == 3)
    await poller.stop()
}

@Test func testPollerWakesFromIdleWhenLogicLaunches() async throws {
    let windows = Counter(), idles = Counter()
    let (gate, wake) = AsyncStream<Void>.makeStream()
    let poller = StatePoller(
        axChannel: AccessibilityChannel(runtime: .production),
        cache: StateCache(),
        runtime: idleRuntime(windows: windows, idles: idles, gate: gate)
    )
    await poller.start()
    #expect(try await waitFor { idles.count >= 1 })
    #expect(windows.count == 3)
    windows.logicUp = true
    wake.yield()
    #expect(try await waitFor { windows.count > 5 })   // cycling again, no longer idle
    await poller.stop()
}

@Test func testPollerKeepsCyclingWhileLogicIsRunning() async throws {
    let windows = Counter(), idles = Counter()
    windows.logicUp = true
    let poller = StatePoller(
        axChannel: AccessibilityChannel(runtime: .production),
        cache: StateCache(),
        runtime: idleRuntime(windows: windows, idles: idles)
    )
    await poller.start()
    #expect(try await waitFor { windows.count > 10 })
    #expect(idles.count == 0)
    await poller.stop()
}

@Test func testLifecycleWatcherWakesOnKnownBundleOnlyAndTimesOut() async throws {
    let center = NotificationCenter()
    let watcher = LogicLifecycleWatcher(center: center, bundleID: { $0.userInfo?["id"] as? String })
    let known = LogicProTarget.knownBundleIDs[0]

    // Unknown bundle: no wake, the timeout ends the wait.
    let t0 = ContinuousClock.now
    async let slow: Void = watcher.wait(timeoutNs: 300_000_000)
    try await Task.sleep(nanoseconds: 50_000_000)
    center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil, userInfo: ["id": "com.example.other"])
    await slow
    #expect(ContinuousClock.now - t0 >= .milliseconds(250))

    // Known bundle: wakes long before the timeout.
    let t1 = ContinuousClock.now
    async let fast: Void = watcher.wait(timeoutNs: 5_000_000_000)
    try await Task.sleep(nanoseconds: 50_000_000)
    center.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil, userInfo: ["id": known])
    await fast
    #expect(ContinuousClock.now - t1 < .seconds(2))
}
