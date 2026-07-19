import Foundation
import XCTest
@testable import SSHConfigurator

final class SCPTransferWorkspaceModelTests: XCTestCase {
    @MainActor
    func testTransferSheetReturnsRememberedRemoteDirectoryForDroppedUploads() {
        let alias = "drop-test-\(UUID().uuidString)"
        let key = "scp.lastRemoteDirectory.\(alias)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.set("/srv/uploads", forKey: key)

        XCTAssertEqual(
            SCPTransferSheet.rememberedRemoteDirectory(alias: alias),
            "/srv/uploads"
        )
    }

    @MainActor
    func testUnsavedConfigPreventsStartingTransfer() {
        let executor = FakeSCPTransferExecutor()
        let model = SCPTransferWorkspaceModel(executor: executor)

        XCTAssertFalse(model.start(downloadRequest(), hasUnsavedChanges: true))
        XCTAssertNil(executor.plan)
        XCTAssertEqual(model.errorMessage, SCPTransferError.unsavedChanges.localizedDescription)
    }

    @MainActor
    func testTracksSuccessAndPreventsConcurrentTransfer() async {
        let executor = FakeSCPTransferExecutor()
        let model = SCPTransferWorkspaceModel(executor: executor)

        XCTAssertTrue(model.start(downloadRequest(), hasUnsavedChanges: false))
        XCTAssertTrue(model.isTransferring)
        XCTAssertNotNil(executor.plan)
        XCTAssertFalse(model.start(downloadRequest(), hasUnsavedChanges: false))
        XCTAssertEqual(model.errorMessage, SCPTransferError.transferAlreadyInProgress.localizedDescription)

        executor.reportProgress(SCPTransferProgressUpdate(fraction: 0.42, transferRate: "1.8MB/s"))
        await Task.yield()
        XCTAssertEqual(model.progress, 0.42)
        XCTAssertEqual(model.transferRate, "1.8MB/s")

        executor.complete(.succeeded(SCPTransferOutput(standardOutput: "", standardError: "")))
        await Task.yield()

        XCTAssertEqual(model.state, .succeeded(SCPTransferOutput(standardOutput: "", standardError: "")))
        XCTAssertEqual(model.progress, 1)
        XCTAssertFalse(model.isTransferring)
    }

    @MainActor
    func testCancellingTransferCancelsProcessAndIgnoresLaterCompletion() async {
        let executor = FakeSCPTransferExecutor()
        let model = SCPTransferWorkspaceModel(executor: executor)

        XCTAssertTrue(model.start(downloadRequest(), hasUnsavedChanges: false))
        model.cancel()
        executor.complete(.succeeded(SCPTransferOutput(standardOutput: "", standardError: "")))
        await Task.yield()

        XCTAssertTrue(executor.handle.didCancel)
        XCTAssertEqual(model.state, .cancelled)
    }

    private func downloadRequest() -> SCPTransferRequest {
        SCPTransferRequest(
            direction: .download,
            alias: "prod-api",
            localURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("scp-transfer-\(UUID().uuidString).txt"),
            remotePath: "/srv/reports/today.txt"
        )
    }
}

private final class FakeSCPTransferExecutor: SCPTransferExecuting {
    private(set) var plan: SCPTransferPlan?
    let handle = FakeSCPTransferProcess()
    private var onProgress: (@Sendable (SCPTransferProgressUpdate) -> Void)?
    private var completion: (@Sendable (SCPTransferCompletion) -> Void)?

    func start(
        plan: SCPTransferPlan,
        onProgress: @escaping @Sendable (SCPTransferProgressUpdate) -> Void,
        completion: @escaping @Sendable (SCPTransferCompletion) -> Void
    ) throws -> any SCPTransferProcess {
        self.plan = plan
        self.onProgress = onProgress
        self.completion = completion
        return handle
    }

    func reportProgress(_ update: SCPTransferProgressUpdate) {
        onProgress?(update)
    }

    func complete(_ result: SCPTransferCompletion) {
        completion?(result)
    }
}

private final class FakeSCPTransferProcess: SCPTransferProcess {
    private(set) var didCancel = false

    func cancel() {
        didCancel = true
    }
}
