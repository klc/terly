import Foundation
import Network

/// Wraps `NWPathMonitor` to report only the *transition* into a satisfied
/// network path (not every status update). WP7 uses this purely as a trigger
/// to retry sooner / suggest reconnecting — it never reconnects on its own
/// initiative (roadmap §8 requires user consent for automatic multi-host
/// action; here the same principle means "network is back" alone never opens
/// a connection when auto mode is off).
@MainActor
protocol NetworkPathObserving: AnyObject {
    var onBecomeSatisfied: (() -> Void)? { get set }
    func start()
    func stop()
}

@MainActor
final class NWPathAvailabilityObserver: NetworkPathObserving {
    var onBecomeSatisfied: (() -> Void)?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.mkilic.Terly.NWPathAvailabilityObserver")
    private var lastStatus: NWPath.Status?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.handle(status: path.status)
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        guard started else { return }
        started = false
        monitor.cancel()
    }

    private func handle(status: NWPath.Status) {
        defer { lastStatus = status }
        guard status == .satisfied, lastStatus != .satisfied else { return }
        onBecomeSatisfied?()
    }

    deinit {
        monitor.cancel()
    }
}

/// No-op stand-in for previews/tests that don't care about network state.
@MainActor
final class NullNetworkPathObserver: NetworkPathObserving {
    var onBecomeSatisfied: (() -> Void)?
    func start() {}
    func stop() {}
}
