import Foundation
import XCTest
@testable import SSHConfigurator

/// WP8: end-to-end transfer-queue tests driven through a fake `SSHProcessExecuting`
/// (the same test seam `SSHProcessClient` call sites already use — see
/// `ChecksumVerifierTests`/`RunbookTests`). Unlike `TransferQueueEngineTests`, which
/// drives `TransferQueue`/`TransferQueueEngine` state transitions directly, these
/// tests go through the *real* `enqueue -> TransferItemRunner -> SCPTransferRunner
/// -> SSHProcessExecuting` path, so they also exercise plan-building, process-result
/// classification, and the completion callback chain that unit tests stub out.
@MainActor
final class TransferQueueEngineIntegrationTests: XCTestCase {
    private func makeHistoryLibrary() -> TransferHistoryLibrary {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = TransferHistoryStore(
            fileURL: directory.appendingPathComponent("transfer-history.json")
        )
        return TransferHistoryLibrary(store: store)
    }

    /// A real local file is required: `SCPTransferPlanBuilder` rejects uploads
    /// whose local source doesn't exist before a process is ever launched.
    private func makeLocalFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("transfer-integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("report.txt")
        try Data("test".utf8).write(to: fileURL)
        return fileURL
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testEnqueuedItemSucceedsThroughFakeScpAndRecordsCompletedHistory() async throws {
        let localURL = try makeLocalFile()
        let fakeExecutor = FakeTransferProcessExecutor(outcome: .success)
        let history = makeHistoryLibrary()
        let engine = TransferQueueEngine(
            queue: TransferQueue(),
            historyLibrary: history,
            runnerFactory: { TransferItemRunner(scpExecutor: SCPTransferRunner(processClient: fakeExecutor)) }
        )
        let item = TransferItem(
            direction: .upload,
            alias: "prod-api",
            localURL: localURL,
            remotePath: "/var/tmp/report.txt",
            isDirectory: false,
            transferProtocol: .scp
        )

        engine.enqueue([item])
        await waitUntil { engine.queue.items.first?.state == .succeeded }

        XCTAssertEqual(engine.queue.items.first?.state, .succeeded)
        XCTAssertEqual(history.records.count, 1)
        XCTAssertEqual(history.records.first?.outcome, .completed)
        XCTAssertEqual(history.records.first?.alias, "prod-api")
    }

    func testEnqueuedItemPermanentlyFailsThroughFakeScpAndRecordsFailedHistory() async throws {
        let localURL = try makeLocalFile()
        let fakeExecutor = FakeTransferProcessExecutor(
            outcome: .failure(exitCode: 1, standardError: "Permission denied")
        )
        let history = makeHistoryLibrary()
        let engine = TransferQueueEngine(
            queue: TransferQueue(),
            historyLibrary: history,
            runnerFactory: { TransferItemRunner(scpExecutor: SCPTransferRunner(processClient: fakeExecutor)) }
        )
        var item = TransferItem(
            direction: .upload,
            alias: "prod-api",
            localURL: localURL,
            remotePath: "/var/tmp/report.txt",
            isDirectory: false,
            transferProtocol: .scp
        )
        // Exhausts the engine's own automatic-retry budget up front so this test
        // observes the *terminal* failure path (and its history record)
        // synchronously, instead of waiting through the real 2s/4s retry backoff
        // that `TransferQueueEngine.handleCompletion` schedules for fresh items.
        item.incrementRetryCount()
        item.incrementRetryCount()
        XCTAssertEqual(item.retryCount, TransferQueueEngine.maxRetries)

        engine.enqueue([item])
        await waitUntil {
            if case .failed = engine.queue.items.first?.state { return true }
            return false
        }

        guard case let .failed(message)? = engine.queue.items.first?.state else {
            return XCTFail("Expected the item to end up permanently failed")
        }
        XCTAssertTrue(message.contains("Permission denied") || !message.isEmpty)
        XCTAssertEqual(history.records.count, 1)
        XCTAssertEqual(history.records.first?.outcome, .failed)
        XCTAssertEqual(history.records.first?.alias, "prod-api")
    }
}

// MARK: - Fake SSHProcessExecuting

/// Responds synchronously to every `start()` call with a fixed outcome —
/// enough to drive `SCPTransferRunner`'s success/failure branches without a
/// real `scp`/`script` process. Mirrors the fakes already used in
/// `ChecksumVerifierTests`/`RunbookTests`.
private final class FakeTransferProcessExecutor: SSHProcessExecuting, @unchecked Sendable {
    enum Outcome {
        case success
        case failure(exitCode: Int32, standardError: String)
    }

    private let outcome: Outcome

    init(outcome: Outcome) {
        self.outcome = outcome
    }

    func start(
        _: SSHProcessRequest,
        onOutput _: @escaping @Sendable (SSHProcessStream, Data) -> Void,
        completion: @escaping @Sendable (Result<SSHProcessResult, SSHProcessClientError>) -> Void
    ) throws -> any SSHProcessTask {
        let result: SSHProcessResult
        switch outcome {
        case .success:
            result = SSHProcessResult(
                terminationStatus: 0,
                standardOutput: "report.txt 100% 4 1.0KB/s 00:00",
                standardError: "",
                duration: 0.001
            )
        case let .failure(exitCode, standardError):
            result = SSHProcessResult(
                terminationStatus: exitCode,
                standardOutput: "",
                standardError: standardError,
                duration: 0.001
            )
        }
        completion(.success(result))
        return FakeTransferProcessTask()
    }
}

private final class FakeTransferProcessTask: SSHProcessTask, @unchecked Sendable {
    func cancel() {}
}
