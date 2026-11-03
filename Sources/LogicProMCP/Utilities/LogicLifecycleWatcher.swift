import AppKit
import Foundation

/// Wakes the background poller when a Logic Pro variant launches or terminates, so a poller that
/// idles while Logic is not running costs nothing between launches. `wait` also returns after the
/// timeout: the notifications are delivered through the process's main run loop, and a missed one
/// must only cost one slow re-check, never a stuck poller.
final class LogicLifecycleWatcher: @unchecked Sendable {
    static let shared = LogicLifecycleWatcher()

    private let lock = NSLock()
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var observers: [NSObjectProtocol] = []

    /// `bundleID` is injectable only so a test can post a synthetic notification (an
    /// `NSRunningApplication` cannot be fabricated).
    init(
        center: NotificationCenter = NSWorkspace.shared.notificationCenter,
        bundleID: @escaping @Sendable (Notification) -> String? = {
            ($0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
        }
    ) {
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                guard let id = bundleID(note), LogicProTarget.isKnownBundleID(id) else { return }
                self?.wakeAll()
            })
        }
    }

    func wait(timeoutNs: UInt64) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                waiters[id] = continuation
                lock.unlock()
                if Task.isCancelled { wake(id) }
                DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(clamping: timeoutNs))) { [weak self] in
                    self?.wake(id)
                }
            }
        } onCancel: {
            wake(id)
        }
    }

    private func wake(_ id: UUID) {
        lock.lock()
        let continuation = waiters.removeValue(forKey: id)
        lock.unlock()
        continuation?.resume()
    }

    private func wakeAll() {
        lock.lock()
        let all = waiters
        waiters = [:]
        lock.unlock()
        for continuation in all.values { continuation.resume() }
    }
}
