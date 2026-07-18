import Foundation
import XCTest
@testable import SSHConfigurator

@MainActor
final class TransferQueueEngineTests: XCTestCase {

    // MARK: - Helpers

    private func makeQueue(concurrency: Int = 3) -> TransferQueue {
        let q = TransferQueue()
        q.concurrencyLimit = concurrency
        return q
    }

    /// Every engine under test gets its own temp-backed history library so these
    /// tests never touch the real `~/Library/Application Support/Terly`
    /// directory.
    private func makeHistoryLibrary() -> TransferHistoryLibrary {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = TransferHistoryStore(
            fileURL: directory.appendingPathComponent("transfer-history.json")
        )
        return TransferHistoryLibrary(store: store)
    }

    private func makeEngine(
        queue: TransferQueue,
        historyLibrary: TransferHistoryLibrary? = nil
    ) -> TransferQueueEngine {
        TransferQueueEngine(queue: queue, historyLibrary: historyLibrary ?? makeHistoryLibrary())
    }

    private func makeItem(
        alias: String = "prod",
        direction: SCPTransferDirection = .download,
        isDirectory: Bool = false,
        proto: TransferProtocol = .scp
    ) -> TransferItem {
        TransferItem(
            direction: direction,
            alias: alias,
            localURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("transfer-\(UUID().uuidString)"),
            remotePath: "/tmp/file.txt",
            isDirectory: isDirectory,
            transferProtocol: proto
        )
    }

    // MARK: - Queue model transitions (no process launching)

    func testEnqueuedItemsStartAsWaiting() {
        let queue = makeQueue()
        let item = makeItem()
        queue.enqueue(item)
        XCTAssertEqual(queue.items.first?.state, .waiting)
    }

    func testMarkActiveTransition() {
        let queue = makeQueue()
        var item = makeItem()
        queue.enqueue(item)
        item.markActive()
        queue.update(item)
        XCTAssertEqual(queue.items.first?.state, .active)
    }

    func testMarkSucceededSetsProgressToOne() {
        var item = makeItem()
        item.markActive()
        item.markSucceeded()
        XCTAssertEqual(item.progress, 1)
        XCTAssertEqual(item.state, .succeeded)
        XCTAssertTrue(item.isTerminal)
    }

    func testMarkFailedStoresMessage() {
        var item = makeItem()
        item.markActive()
        item.markFailed("timeout")
        if case let .failed(message) = item.state {
            XCTAssertEqual(message, "timeout")
        } else {
            XCTFail("Expected .failed state")
        }
    }

    func testMarkCancelledIsTerminal() {
        var item = makeItem()
        item.markCancelled()
        XCTAssertEqual(item.state, .cancelled)
        XCTAssertTrue(item.isTerminal)
    }

    func testVerifyChecksumDefaultsToFalseAndDirectoriesCanStillOptOut() {
        let item = makeItem()
        XCTAssertFalse(item.verifyChecksum)
        XCTAssertNil(item.checksumState)
    }

    func testUpdateChecksumStateStoresLatestResult() {
        var item = makeItem()
        item.updateChecksumState(.verifying)
        XCTAssertEqual(item.checksumState, .verifying)
        item.updateChecksumState(.verified)
        XCTAssertEqual(item.checksumState, .verified)
        item.updateChecksumState(nil)
        XCTAssertNil(item.checksumState)
    }

    func testResetForRetryRestoresWaitingState() {
        var item = makeItem()
        item.markActive()
        item.markFailed("err")
        item.incrementRetryCount()
        item.resetForRetry()
        XCTAssertEqual(item.state, .waiting)
        XCTAssertEqual(item.retryCount, 1)
        XCTAssertNil(item.progress)
    }

    // MARK: - TransferQueue

    func testNextWaitingItemReturnsFirstWaiting() {
        let queue = makeQueue()
        let a = makeItem()
        var b = makeItem()
        b.markActive()
        queue.enqueue(a)
        queue.enqueue(b)
        queue.update(b)
        XCTAssertEqual(queue.nextWaitingItem()?.id, a.id)
    }

    func testClearTerminatedRemovesOnlyTerminalItems() {
        let queue = makeQueue()
        var a = makeItem()
        var b = makeItem()
        a.markSucceeded()
        queue.enqueue(a)
        queue.enqueue(b)
        queue.update(a)
        queue.clearTerminated()
        XCTAssertEqual(queue.items.count, 1)
        XCTAssertEqual(queue.items.first?.id, b.id)
    }

    func testTotalProgressIsNilWhenEmpty() {
        let queue = makeQueue()
        XCTAssertNil(queue.totalProgress)
    }

    func testHasActiveOrPendingIsTrueWhenWaitingItemExists() {
        let queue = makeQueue()
        queue.enqueue(makeItem())
        XCTAssertTrue(queue.hasActiveOrPending)
    }

    func testHasActiveOrPendingIsFalseWhenAllTerminal() {
        let queue = makeQueue()
        var item = makeItem()
        item.markCancelled()
        queue.enqueue(item)
        queue.update(item)
        XCTAssertFalse(queue.hasActiveOrPending)
    }

    // MARK: - Engine: cancel and retry via queue model

    func testEngineRetryResetsFailedItemToWaiting() {
        let queue = makeQueue()
        let engine = makeEngine(queue: queue)
        var item = makeItem()
        item.markFailed("network error")
        queue.enqueue(item)
        queue.update(item)

        engine.retry(itemID: item.id)

        let updated = queue.items.first { $0.id == item.id }
        if let state = updated?.state, case .failed = state {
            XCTFail("Item should not remain failed after retry")
        }
    }

    func testEngineCancelIDMovesItemToCancelled() {
        let queue = makeQueue()
        let engine = makeEngine(queue: queue)
        var item = makeItem()
        item.markActive()
        queue.enqueue(item)
        queue.update(item)

        engine.cancel(itemID: item.id)

        let updated = queue.items.first { $0.id == item.id }
        XCTAssertEqual(updated?.state, .cancelled)
    }

    func testEngineCancelAllMovesAllActiveAndWaitingToCancelled() {
        let queue = makeQueue()
        let engine = makeEngine(queue: queue)
        var a = makeItem()
        let b = makeItem()
        a.markActive()
        queue.enqueue(a)
        queue.enqueue(b)
        queue.update(a)

        engine.cancelAll()

        for item in queue.items {
            XCTAssertEqual(item.state, .cancelled)
        }
    }

    func testEngineClearFinishedRemovesTerminalItems() {
        let queue = makeQueue()
        let engine = makeEngine(queue: queue)
        var a = makeItem()
        a.markCancelled()
        queue.enqueue(a)
        queue.update(a)

        engine.clearFinished()
        XCTAssertTrue(queue.items.isEmpty)
    }

    // MARK: - ConcurrencyLimit property

    func testConcurrencyLimitDefault() {
        let engine = TransferQueueEngine()
        XCTAssertEqual(engine.queue.concurrencyLimit, 3)
    }

    // MARK: - Terminal state -> history recording

    func testCancelItemRecordsCancelledHistoryEntry() {
        let queue = makeQueue()
        let history = makeHistoryLibrary()
        let engine = makeEngine(queue: queue, historyLibrary: history)
        var item = makeItem(alias: "prod", direction: .download)
        item.markActive()
        queue.enqueue(item)
        queue.update(item)

        engine.cancel(itemID: item.id)

        XCTAssertEqual(history.records.count, 1)
        XCTAssertEqual(history.records.first?.outcome, .cancelled)
        XCTAssertEqual(history.records.first?.alias, "prod")
    }

    func testCancelAllRecordsCancelledEntryForEachActiveOrWaitingItem() {
        let queue = makeQueue()
        let history = makeHistoryLibrary()
        let engine = makeEngine(queue: queue, historyLibrary: history)
        var a = makeItem()
        let b = makeItem()
        a.markActive()
        queue.enqueue(a)
        queue.enqueue(b)
        queue.update(a)

        engine.cancelAll()

        XCTAssertEqual(history.records.count, 2)
        XCTAssertTrue(history.records.allSatisfy { $0.outcome == .cancelled })
    }

    func testRetryDoesNotRecordAnyHistoryEntry() {
        let queue = makeQueue()
        let history = makeHistoryLibrary()
        let engine = makeEngine(queue: queue, historyLibrary: history)
        var item = makeItem()
        item.markFailed("network error")
        queue.enqueue(item)
        queue.update(item)

        engine.retry(itemID: item.id)

        XCTAssertTrue(history.records.isEmpty)
    }
}
