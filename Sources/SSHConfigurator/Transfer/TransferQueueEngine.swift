import Foundation

/// Manages the transfer queue: starts items up to the concurrency limit,
/// handles retries, and propagates progress and completion back to `TransferQueue`.
@MainActor
final class TransferQueueEngine: ObservableObject {
    static let maxRetries = 2          // up to 3 total attempts (initial + 2 retries)
    private static let retryBaseDelay: TimeInterval = 2.0

    private(set) var queue: TransferQueue
    /// Shared with any view that shows the "Geçmiş" tab — recording here and
    /// reading there is the same object, so there's no separate sync step.
    let historyLibrary: TransferHistoryLibrary
    private var runners: [UUID: TransferItemRunner] = [:]
    /// Identifies the currently running attempt for each item. A cancelled
    /// process can still deliver its completion callback; comparing the token
    /// prevents that stale callback from mutating a newer retry attempt.
    private var activeAttemptTokens: [UUID: UUID] = [:]
    /// Items waiting for their exponential-backoff delay must remain in the
    /// queue without being picked up by the regular scheduler.
    private var retryTasks: [UUID: Task<Void, Never>] = [:]
    private let checksumVerifier: any ChecksumVerifying
    private var checksumTasks: [UUID: Task<Void, Never>] = [:]
    /// Builds the `TransferItemRunner` for each started item. Defaults to a
    /// real runner (real `scp`/sftp processes); WP8 integration tests inject
    /// one wired to a fake `SSHProcessExecuting`, so the whole
    /// enqueue -> start -> completion -> history-record path can be exercised
    /// end-to-end without ever launching a real process.
    private let runnerFactory: @MainActor () -> TransferItemRunner
    private let retryDelayNanoseconds: @MainActor (Int) -> UInt64

    // MARK: - Progress throttling

    /// Progress updates arrive frequently (every line scp/sftp prints). Publishing
    /// each one drives `@Published items` and a full `TransferQueueView` re-render,
    /// so updates are gated per item: at most one publish per `progressThrottleInterval`
    /// unless the fraction moved enough to be visually meaningful, or the transfer
    /// completed.
    private static let progressThrottleInterval: TimeInterval = 0.15
    private static let progressThrottleMinFractionDelta = 0.01
    private var lastProgressPublish: [UUID: (date: Date, fraction: Double)] = [:]

    /// Convenience initialiser: creates its own `TransferQueue`.
    convenience init() {
        self.init(queue: TransferQueue())
    }

    init(
        queue: TransferQueue,
        checksumVerifier: any ChecksumVerifying = TransferChecksumVerifier(),
        historyLibrary: TransferHistoryLibrary = TransferHistoryLibrary(),
        runnerFactory: @escaping @MainActor () -> TransferItemRunner = { TransferItemRunner() },
        retryDelayNanoseconds: @escaping @MainActor (Int) -> UInt64 = { retryCount in
            let delay = retryBaseDelay * pow(2.0, Double(retryCount - 1))
            return UInt64(delay * 1_000_000_000)
        }
    ) {
        self.queue = queue
        self.checksumVerifier = checksumVerifier
        self.historyLibrary = historyLibrary
        self.runnerFactory = runnerFactory
        self.retryDelayNanoseconds = retryDelayNanoseconds
    }

    // MARK: - Public API

    /// Enqueues one or more items and kicks off scheduling.
    func enqueue(_ items: [TransferItem]) {
        queue.enqueue(contentsOf: items)
        scheduleNext()
    }

    /// Cancels a specific item. If it is active, its runner is stopped.
    func cancel(itemID: UUID) {
        guard let index = queue.items.firstIndex(where: { $0.id == itemID }) else { return }
        var item = queue.items[index]
        cancelScheduledRetry(itemID: itemID)
        activeAttemptTokens.removeValue(forKey: itemID)
        runners[itemID]?.cancel()
        runners.removeValue(forKey: itemID)
        lastProgressPublish.removeValue(forKey: itemID)
        item.markCancelled()
        queue.update(item)
        recordHistory(for: item, outcome: .cancelled)
        scheduleNext()
    }

    /// Cancels all waiting and active items, plus any checksum verification in flight.
    func cancelAll() {
        activeAttemptTokens.removeAll()
        for task in retryTasks.values { task.cancel() }
        retryTasks.removeAll()
        for runner in runners.values { runner.cancel() }
        runners.removeAll()
        for task in checksumTasks.values { task.cancel() }
        checksumTasks.removeAll()
        for index in queue.items.indices {
            var item = queue.items[index]
            if item.state == .active || item.state == .waiting {
                item.markCancelled()
                queue.update(item)
                recordHistory(for: item, outcome: .cancelled)
            }
        }
    }

    /// Retries a specific failed or cancelled item immediately.
    func retry(itemID: UUID) {
        guard let index = queue.items.firstIndex(where: { $0.id == itemID }) else { return }
        cancelScheduledRetry(itemID: itemID)
        activeAttemptTokens.removeValue(forKey: itemID)
        var item = queue.items[index]
        item.resetForRetry()
        queue.update(item)
        scheduleNext()
    }

    /// Removes all terminated items from the queue, cancelling any of their
    /// in-flight checksum verifications first.
    func clearFinished() {
        for item in queue.items where item.isTerminal {
            cancelScheduledRetry(itemID: item.id)
            activeAttemptTokens.removeValue(forKey: item.id)
            checksumTasks[item.id]?.cancel()
            checksumTasks.removeValue(forKey: item.id)
        }
        queue.clearTerminated()
    }

    // MARK: - Scheduling

    private func scheduleNext() {
        let delayedItemIDs = Set(retryTasks.keys)
        while queue.activeCount < queue.concurrencyLimit,
              let item = queue.nextWaitingItem(excluding: delayedItemIDs) {
            startItem(item)
        }
    }

    private func startItem(_ item: TransferItem) {
        var mutable = item
        mutable.markActive()
        queue.update(mutable)

        let runner = runnerFactory()
        runners[item.id] = runner
        let attemptToken = UUID()
        activeAttemptTokens[item.id] = attemptToken

        let (launched, error) = runner.start(
            item: mutable,
            onProgress: { [weak self] update in
                self?.handleProgress(itemID: item.id, attemptToken: attemptToken, update: update)
            },
            onCompletion: { [weak self] result in
                self?.handleCompletion(itemID: item.id, attemptToken: attemptToken, result: result)
            }
        )

        if !launched {
            runners.removeValue(forKey: item.id)
            activeAttemptTokens.removeValue(forKey: item.id)
            var failed = mutable
            let message = error ?? String(localized: "Failed to start.")
            failed.markFailed(message)
            queue.update(failed)
            recordHistory(for: failed, outcome: .failed, failureMessage: message)
            scheduleNext()
        }
    }

    // MARK: - Callbacks

    private func handleProgress(
        itemID: UUID,
        attemptToken: UUID,
        update: SCPTransferProgressUpdate
    ) {
        guard activeAttemptTokens[itemID] == attemptToken else { return }
        guard let index = queue.items.firstIndex(where: { $0.id == itemID }) else { return }
        var item = queue.items[index]
        guard item.state == .active else { return }

        let now = Date()
        let fraction = update.fraction
        if let last = lastProgressPublish[itemID], fraction < 1.0 {
            let elapsed = now.timeIntervalSince(last.date)
            let fractionDelta = abs(fraction - last.fraction)
            if elapsed < Self.progressThrottleInterval,
               fractionDelta < Self.progressThrottleMinFractionDelta {
                return
            }
        }
        lastProgressPublish[itemID] = (date: now, fraction: fraction)

        item.updateProgress(fraction: fraction, rate: update.transferRate, etaSeconds: nil)
        queue.update(item)
    }

    private func handleCompletion(
        itemID: UUID,
        attemptToken: UUID,
        result: SCPTransferCompletion
    ) {
        guard activeAttemptTokens[itemID] == attemptToken else { return }
        activeAttemptTokens.removeValue(forKey: itemID)
        runners.removeValue(forKey: itemID)
        lastProgressPublish.removeValue(forKey: itemID)
        guard let index = queue.items.firstIndex(where: { $0.id == itemID }) else {
            scheduleNext()
            return
        }
        var item = queue.items[index]
        guard item.state == .active else {
            scheduleNext()
            return
        }
        switch result {
        case .succeeded:
            item.markSucceeded()
            queue.update(item)
            recordHistory(for: item, outcome: .completed)
            startChecksumVerificationIfNeeded(item)
        case let .failed(message):
            if item.retryCount < Self.maxRetries {
                item.incrementRetryCount()
                item.resetForRetry()
                queue.update(item)
                scheduleRetry(for: item.id, retryCount: item.retryCount)
            } else {
                item.markFailed(message)
                queue.update(item)
                recordHistory(for: item, outcome: .failed, failureMessage: message)
            }
        }
        scheduleNext()
    }

    private func scheduleRetry(for itemID: UUID, retryCount: Int) {
        cancelScheduledRetry(itemID: itemID)
        let delay = retryDelayNanoseconds(retryCount)
        retryTasks[itemID] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.retryTasks.removeValue(forKey: itemID)
            self.scheduleNext()
        }
    }

    private func cancelScheduledRetry(itemID: UUID) {
        retryTasks[itemID]?.cancel()
        retryTasks.removeValue(forKey: itemID)
    }

    // MARK: - History recording

    /// Records a terminal item to `historyLibrary`. Called exactly once per item,
    /// at the moment it becomes `.succeeded`, permanently `.failed` (retries
    /// exhausted or the item never even launched), or `.cancelled`. Waiting/active
    /// items, and failures that are about to auto-retry, are never recorded.
    private func recordHistory(
        for item: TransferItem,
        outcome: TransferHistoryOutcome,
        failureMessage: String? = nil
    ) {
        historyLibrary.recordTerminal(
            TransferHistoryRecord(item: item, outcome: outcome, failureMessage: failureMessage)
        )
    }

    // MARK: - Checksum verification

    /// Directories never verify — the request is per single-file item.
    private func startChecksumVerificationIfNeeded(_ item: TransferItem) {
        guard item.verifyChecksum, !item.isDirectory else { return }

        var verifying = item
        verifying.updateChecksumState(.verifying)
        queue.update(verifying)

        checksumTasks[item.id] = Task { [weak self] in
            guard let self else { return }
            let state = await self.checksumVerifier.verify(
                localURL: item.localURL,
                alias: item.alias,
                remotePath: item.remotePath
            )
            self.applyChecksumResult(itemID: item.id, state: state)
        }
    }

    private func applyChecksumResult(itemID: UUID, state: ChecksumVerificationState) {
        checksumTasks.removeValue(forKey: itemID)
        guard let index = queue.items.firstIndex(where: { $0.id == itemID }) else { return }
        var item = queue.items[index]
        item.updateChecksumState(state)
        queue.update(item)
    }
}
