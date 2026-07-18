import Foundation
import XCTest
@testable import SSHConfigurator

final class TransferHistoryStoreTests: XCTestCase {

    // MARK: - Helpers

    private func makeItem(
        alias: String = "prod",
        direction: SCPTransferDirection = .download,
        localURL: URL? = nil,
        remotePath: String = "/tmp/remote-file.txt",
        isDirectory: Bool = false,
        verifyChecksum: Bool = false
    ) -> TransferItem {
        TransferItem(
            direction: direction,
            alias: alias,
            localURL: localURL ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("history-\(UUID().uuidString)"),
            remotePath: remotePath,
            isDirectory: isDirectory,
            transferProtocol: .scp,
            verifyChecksum: verifyChecksum
        )
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        return permissions.intValue & 0o777
    }

    // MARK: - Store: atomic write + permissions + round trip

    func testStoreRoundTripIsAtomicOwnerOnlyAndSecuresExistingParent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: root.path
        )
        let fileURL = root.appendingPathComponent("transfer-history.json")
        let store = TransferHistoryStore(fileURL: fileURL)

        let record = TransferHistoryRecord(
            direction: .upload,
            alias: "prod",
            localPath: "/Users/tester/report.txt",
            remotePath: "/srv/report.txt",
            isDirectory: false,
            transferProtocol: .scp,
            verifyChecksum: true,
            fileSize: 1024,
            durationSeconds: 4.2,
            outcome: .completed
        )
        let state = TransferHistoryState(records: [record])

        try store.save(state)

        XCTAssertEqual(try store.load(), state)
        XCTAssertEqual(try permissions(at: fileURL), 0o600)
        XCTAssertEqual(try permissions(at: root), 0o700)
    }

    func testMissingStoreFileLoadsEmptyState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TransferHistoryStore(fileURL: root.appendingPathComponent("transfer-history.json"))

        XCTAssertEqual(try store.load(), TransferHistoryState())
    }

    // MARK: - Library: trimming to the last 200 records

    @MainActor
    func testLibraryTrimsToMostRecentTwoHundredRecords() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TransferHistoryStore(fileURL: root.appendingPathComponent("transfer-history.json"))
        let library = TransferHistoryLibrary(store: store)

        for index in 0..<205 {
            library.recordTerminal(TransferHistoryRecord(
                direction: .download,
                alias: "host-\(index)",
                localPath: "/tmp/file-\(index)",
                remotePath: "/tmp/remote-\(index)",
                isDirectory: false,
                transferProtocol: .scp,
                verifyChecksum: false,
                fileSize: nil,
                durationSeconds: nil,
                outcome: .completed
            ))
        }

        XCTAssertEqual(library.records.count, TransferHistoryLibrary.maxRecords)
        // Newest first, oldest dropped: the very last inserted record is at the front...
        XCTAssertEqual(library.records.first?.alias, "host-204")
        // ...and the oldest surviving record is exactly 200 back from it.
        XCTAssertEqual(library.records.last?.alias, "host-5")
        // Persisted state matches in-memory state after trimming.
        XCTAssertEqual(try store.load().records.count, TransferHistoryLibrary.maxRecords)
    }

    @MainActor
    func testLibraryClearRemovesAllRecordsAndPersists() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TransferHistoryStore(fileURL: root.appendingPathComponent("transfer-history.json"))
        let library = TransferHistoryLibrary(store: store)
        library.recordTerminal(TransferHistoryRecord(
            direction: .upload,
            alias: "prod",
            localPath: "/tmp/a",
            remotePath: "/tmp/b",
            isDirectory: false,
            transferProtocol: .scp,
            verifyChecksum: false,
            fileSize: nil,
            durationSeconds: nil,
            outcome: .cancelled
        ))
        XCTAssertEqual(library.records.count, 1)

        library.clear()

        XCTAssertTrue(library.records.isEmpty)
        XCTAssertTrue(try store.load().records.isEmpty)
    }

    @MainActor
    func testLibraryLoadSurvivesAcrossInstancesAppRestartSimulation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("transfer-history.json")

        let firstRun = TransferHistoryLibrary(store: TransferHistoryStore(fileURL: fileURL))
        firstRun.recordTerminal(TransferHistoryRecord(
            direction: .download,
            alias: "prod",
            localPath: "/tmp/a",
            remotePath: "/tmp/b",
            isDirectory: false,
            transferProtocol: .sftp,
            verifyChecksum: false,
            fileSize: 42,
            durationSeconds: 1.5,
            outcome: .completed
        ))

        // Simulate an app restart: a brand-new library instance backed by the same file.
        let secondRun = TransferHistoryLibrary(store: TransferHistoryStore(fileURL: fileURL))
        secondRun.load()

        XCTAssertEqual(secondRun.records.count, 1)
        XCTAssertEqual(secondRun.records.first?.alias, "prod")
    }

    // MARK: - Terminal state -> record mapping

    func testRecordFromSucceededItemCapturesDurationAndOutcome() throws {
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-\(UUID().uuidString)")
        try Data("hello".utf8).write(to: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }

        var item = makeItem(direction: .upload, localURL: localURL)
        item.markActive()
        item.markSucceeded()

        let record = TransferHistoryRecord(item: item, outcome: .completed)

        XCTAssertEqual(record.outcome, .completed)
        XCTAssertEqual(record.direction, .upload)
        XCTAssertEqual(record.fileSize, 5)
        XCTAssertNotNil(record.durationSeconds)
        XCTAssertNil(record.failureMessage)
    }

    func testRecordFromFailedItemStoresFailureMessage() {
        var item = makeItem()
        item.markActive()
        item.markFailed("bağlantı zaman aşımına uğradı")

        let record = TransferHistoryRecord(item: item, outcome: .failed, failureMessage: "bağlantı zaman aşımına uğradı")

        XCTAssertEqual(record.outcome, .failed)
        XCTAssertEqual(record.failureMessage, "bağlantı zaman aşımına uğradı")
    }

    func testRecordFromCancelledItemHasNoFailureMessage() {
        var item = makeItem()
        item.markCancelled()

        let record = TransferHistoryRecord(item: item, outcome: .cancelled)

        XCTAssertEqual(record.outcome, .cancelled)
        XCTAssertNil(record.failureMessage)
    }

    func testRecordFromDirectoryItemNeverReportsSize() throws {
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-dir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localURL) }

        var item = makeItem(direction: .upload, localURL: localURL, isDirectory: true)
        item.markSucceeded()

        let record = TransferHistoryRecord(item: item, outcome: .completed)

        XCTAssertNil(record.fileSize)
    }

    // MARK: - Redaction

    func testRedactionShortensHomeDirectoryToTilde() {
        let redacted = TransferHistoryRedaction.redact(
            "/Users/klc/Documents/report.txt",
            homeDirectory: "/Users/klc",
            userName: "klc"
        )
        XCTAssertEqual(redacted, "~/Documents/report.txt")
    }

    func testRedactionMasksUserNameComponentOutsideHomeDirectory() {
        // A remote path won't share the local home directory prefix, but it may
        // still contain the same login name as a path component.
        let redacted = TransferHistoryRedaction.redact(
            "/home/klc/uploads/report.txt",
            homeDirectory: "/Users/klc",
            userName: "klc"
        )
        XCTAssertEqual(redacted, "/home/•••/uploads/report.txt")
    }

    func testRedactionLeavesUnrelatedPathsUntouched() {
        let redacted = TransferHistoryRedaction.redact(
            "/srv/shared/report.txt",
            homeDirectory: "/Users/klc",
            userName: "klc"
        )
        XCTAssertEqual(redacted, "/srv/shared/report.txt")
    }

    // MARK: - Retry parameter copy

    func testMakeRetryItemCopiesAllParametersForDownload() {
        let record = TransferHistoryRecord(
            direction: .download,
            alias: "prod",
            localPath: "/tmp/does-not-need-to-exist-for-download",
            remotePath: "/srv/data.txt",
            isDirectory: false,
            transferProtocol: .sftp,
            verifyChecksum: true,
            fileSize: nil,
            durationSeconds: nil,
            outcome: .failed,
            failureMessage: "timeout"
        )

        let result = record.makeRetryItem()

        guard case let .success(item) = result else {
            return XCTFail("Expected a successfully rebuilt item for a download, regardless of local path")
        }
        XCTAssertEqual(item.direction, .download)
        XCTAssertEqual(item.alias, "prod")
        XCTAssertEqual(item.localURL.path, record.localPath)
        XCTAssertEqual(item.remotePath, "/srv/data.txt")
        XCTAssertEqual(item.transferProtocol, .sftp)
        XCTAssertTrue(item.verifyChecksum)
        XCTAssertEqual(item.state, .waiting)
    }

    func testMakeRetryItemFailsForUploadWhenLocalSourceIsGone() {
        let record = TransferHistoryRecord(
            direction: .upload,
            alias: "prod",
            localPath: "/tmp/definitely-does-not-exist-\(UUID().uuidString)",
            remotePath: "/srv/data.txt",
            isDirectory: false,
            transferProtocol: .scp,
            verifyChecksum: false,
            fileSize: nil,
            durationSeconds: nil,
            outcome: .cancelled
        )

        let result = record.makeRetryItem()

        guard case let .failure(error) = result, case let .missingLocalSource(path) = error else {
            return XCTFail("Expected missingLocalSource for an upload whose local file is gone")
        }
        XCTAssertEqual(path, record.localPath)
    }

    func testMakeRetryItemSucceedsForUploadWhenLocalSourceExists() throws {
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-retry-\(UUID().uuidString)")
        try Data("payload".utf8).write(to: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }

        let record = TransferHistoryRecord(
            direction: .upload,
            alias: "prod",
            localPath: localURL.path,
            remotePath: "/srv/data.txt",
            isDirectory: false,
            transferProtocol: .scp,
            verifyChecksum: false,
            fileSize: nil,
            durationSeconds: nil,
            outcome: .failed,
            failureMessage: "network error"
        )

        let result = record.makeRetryItem()

        guard case .success = result else {
            return XCTFail("Expected success when the local upload source still exists")
        }
    }

    // MARK: - Partial file cleanup targeting

    func testUploadOffersRemotePartialFileTarget() {
        let record = TransferHistoryRecord(
            direction: .upload,
            alias: "prod",
            localPath: "/tmp/local.txt",
            remotePath: "/srv/remote.txt",
            isDirectory: false,
            transferProtocol: .scp,
            verifyChecksum: false,
            fileSize: nil,
            durationSeconds: nil,
            outcome: .cancelled
        )

        XCTAssertTrue(record.offersPartialFileCleanup)
        let target = record.partialFileTarget
        XCTAssertTrue(target.isRemote)
        XCTAssertEqual(target.path, "/srv/remote.txt")
    }

    func testDownloadOffersLocalPartialFileTarget() {
        let record = TransferHistoryRecord(
            direction: .download,
            alias: "prod",
            localPath: "/tmp/local.txt",
            remotePath: "/srv/remote.txt",
            isDirectory: false,
            transferProtocol: .scp,
            verifyChecksum: false,
            fileSize: nil,
            durationSeconds: nil,
            outcome: .failed,
            failureMessage: "disk full"
        )

        XCTAssertTrue(record.offersPartialFileCleanup)
        let target = record.partialFileTarget
        XCTAssertFalse(target.isRemote)
        XCTAssertEqual(target.path, "/tmp/local.txt")
    }

    func testDirectoryTransferNeverOffersPartialFileCleanup() {
        for outcome: TransferHistoryOutcome in [.cancelled, .failed, .completed] {
            let record = TransferHistoryRecord(
                direction: .upload,
                alias: "prod",
                localPath: "/tmp/folder",
                remotePath: "/srv/folder",
                isDirectory: true,
                transferProtocol: .scp,
                verifyChecksum: false,
                fileSize: nil,
                durationSeconds: nil,
                outcome: outcome
            )
            XCTAssertFalse(record.offersPartialFileCleanup, "directory transfers must never offer cleanup (outcome: \(outcome))")
        }
    }

    func testCompletedTransferNeverOffersPartialFileCleanup() {
        let record = TransferHistoryRecord(
            direction: .download,
            alias: "prod",
            localPath: "/tmp/local.txt",
            remotePath: "/srv/remote.txt",
            isDirectory: false,
            transferProtocol: .scp,
            verifyChecksum: false,
            fileSize: 10,
            durationSeconds: 1,
            outcome: .completed
        )

        XCTAssertFalse(record.offersPartialFileCleanup)
    }
}
