import Foundation

/// Opaque handle for a scheduled reconnect timer; used only to cancel it.
/// Callers never inspect its contents, only pass it back to `cancel(_:)`.
struct ReconnectTimerToken: Hashable {
    private let id = UUID()
}

/// Testable seam around "run this after N seconds." WP7's backoff/aliveness
/// timers all go through this instead of calling `Task.sleep` directly, so
/// unit tests can drive them deterministically without waiting on the wall
/// clock (see `ManualReconnectScheduler` in the test target).
@MainActor
protocol ReconnectScheduling: AnyObject {
    @discardableResult
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> ReconnectTimerToken
    func cancel(_ token: ReconnectTimerToken)
    func cancelAll()
}

/// Production implementation: one `Task` per scheduled timer, cancelled by
/// cancelling that task.
@MainActor
final class RealReconnectScheduler: ReconnectScheduling {
    private var tasks: [ReconnectTimerToken: Task<Void, Never>] = [:]

    @discardableResult
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> ReconnectTimerToken {
        let token = ReconnectTimerToken()
        let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
        tasks[token] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self?.tasks[token] = nil
            action()
        }
        return token
    }

    func cancel(_ token: ReconnectTimerToken) {
        tasks[token]?.cancel()
        tasks[token] = nil
    }

    func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }
}
