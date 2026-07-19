import Foundation
import XCTest
@testable import SSHConfigurator

@MainActor
final class SyncCoordinatorTests: XCTestCase {
    nonisolated(unsafe) private var root: URL!

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("terly-sync-coordinator-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func initBareRemote() throws -> URL {
        let bareRemote = root.appendingPathComponent("remote.git", isDirectory: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["init", "--bare", "--initial-branch=main", bareRemote.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return bareRemote
    }

    private func makeCoordinator(name: String, debounceInterval: TimeInterval = 30) -> (SyncCoordinator, URL) {
        let base = root.appendingPathComponent(name, isDirectory: true)
        let sshDir = base.appendingPathComponent(".ssh", isDirectory: true)
        let appSupportDir = base.appendingPathComponent("AppSupport", isDirectory: true)
        try? FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)

        let repository = SyncRepository(
            git: GitCommandRunner(repositoryURL: base.appendingPathComponent("sync", isDirectory: true)),
            resolver: SyncSetResolver(sshDirectoryURL: sshDir, appSupportDirectoryURL: appSupportDir),
            backupDirectoryURL: base.appendingPathComponent("Backups", isDirectory: true)
        )
        let settingsStore = SyncSettingsStore(fileURL: base.appendingPathComponent("sync-settings.json"))
        let coordinator = SyncCoordinator(repository: repository, settingsStore: settingsStore, debounceInterval: debounceInterval)
        return (coordinator, sshDir)
    }

    func testNoteChangeIsANoOpWithoutAConfiguredRemote() async {
        let (coordinator, _) = makeCoordinator(name: "solo", debounceInterval: 0.05)
        coordinator.noteChange()
        XCTAssertEqual(coordinator.status, .idle)
    }

    func testNoteChangeDebouncesThenCommits() async throws {
        let bareRemote = try initBareRemote()
        let (coordinator, sshDir) = makeCoordinator(name: "A", debounceInterval: 0.05)
        await coordinator.setRemoteURL(bareRemote.path)

        try "Host x\n  HostName x.example.com\n".write(to: sshDir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        coordinator.noteChange()
        XCTAssertEqual(coordinator.status, .pendingCommit)

        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(coordinator.status, .idle)
    }

    func testNoteChangeBurstOnlyCommitsOnce() async throws {
        let bareRemote = try initBareRemote()
        let (coordinator, sshDir) = makeCoordinator(name: "A", debounceInterval: 0.05)
        await coordinator.setRemoteURL(bareRemote.path)
        let configURL = sshDir.appendingPathComponent("config")

        for index in 0 ..< 5 {
            try "Host x\(index)\n  HostName x\(index).example.com\n".write(to: configURL, atomically: true, encoding: .utf8)
            coordinator.noteChange()
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(coordinator.status, .idle)
    }

    func testPullDoesNotTouchRealFilesUntilApplyPendingChangesIsConfirmed() async throws {
        let bareRemote = try initBareRemote()
        let (coordinatorA, sshA) = makeCoordinator(name: "A")
        await coordinatorA.setRemoteURL(bareRemote.path)
        try "Host prod\n  HostName prod.example.com\n".write(to: sshA.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        await coordinatorA.syncNow()

        let (coordinatorB, sshB) = makeCoordinator(name: "B")
        await coordinatorB.setRemoteURL(bareRemote.path)
        await coordinatorB.pull()

        XCTAssertEqual(coordinatorB.status, .pendingApply)
        XCTAssertFalse(coordinatorB.pendingDiff.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sshB.appendingPathComponent("config").path))

        await coordinatorB.applyPendingChanges()

        XCTAssertEqual(coordinatorB.status, .idle)
        XCTAssertTrue(coordinatorB.pendingDiff.isEmpty)
        let applied = try String(contentsOf: sshB.appendingPathComponent("config"), encoding: .utf8)
        XCTAssertTrue(applied.contains("prod.example.com"))
    }

    func testDismissPendingChangesLeavesRealFilesUntouched() async throws {
        let bareRemote = try initBareRemote()
        let (coordinatorA, sshA) = makeCoordinator(name: "A")
        await coordinatorA.setRemoteURL(bareRemote.path)
        try "Host prod\n  HostName prod.example.com\n".write(to: sshA.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        await coordinatorA.syncNow()

        let (coordinatorB, sshB) = makeCoordinator(name: "B")
        await coordinatorB.setRemoteURL(bareRemote.path)
        await coordinatorB.pull()
        XCTAssertEqual(coordinatorB.status, .pendingApply)

        coordinatorB.dismissPendingChanges()

        XCTAssertEqual(coordinatorB.status, .idle)
        XCTAssertTrue(coordinatorB.pendingDiff.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sshB.appendingPathComponent("config").path))
    }

    func testSyncNowSurfacesDivergedWithoutThrowing() async throws {
        let bareRemote = try initBareRemote()
        let (coordinatorA, sshA) = makeCoordinator(name: "A")
        await coordinatorA.setRemoteURL(bareRemote.path)
        try "Host base\n  HostName base.example.com\n".write(to: sshA.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        await coordinatorA.syncNow()
        XCTAssertEqual(coordinatorA.status, .idle)

        let (coordinatorB, sshB) = makeCoordinator(name: "B")
        await coordinatorB.setRemoteURL(bareRemote.path)
        await coordinatorB.pull()

        try "Host base\n  HostName base.example.com\nHost added-by-a\n  HostName a.example.com\n".write(to: sshA.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        await coordinatorA.syncNow()

        try "Host base\n  HostName base.example.com\nHost added-by-b\n  HostName b.example.com\n".write(to: sshB.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        await coordinatorB.syncNow()

        XCTAssertEqual(coordinatorB.status, .diverged)
    }

    func testResolveDivergenceCancelLeavesStatusDiverged() async throws {
        let bareRemote = try initBareRemote()
        let (coordinatorA, sshA) = makeCoordinator(name: "A")
        await coordinatorA.setRemoteURL(bareRemote.path)
        try "Host base\n  HostName base.example.com\n".write(to: sshA.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        await coordinatorA.syncNow()

        let (coordinatorB, sshB) = makeCoordinator(name: "B")
        await coordinatorB.setRemoteURL(bareRemote.path)
        await coordinatorB.pull()

        try "Host base\n  HostName base.example.com\nHost added-by-a\n  HostName a.example.com\n".write(to: sshA.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        await coordinatorA.syncNow()

        try "Host base\n  HostName base.example.com\nHost added-by-b\n  HostName b.example.com\n".write(to: sshB.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        await coordinatorB.syncNow()
        XCTAssertEqual(coordinatorB.status, .diverged)

        await coordinatorB.resolveDivergence(.cancel)
        XCTAssertEqual(coordinatorB.status, .diverged)

        let stillLocal = try String(contentsOf: sshB.appendingPathComponent("config"), encoding: .utf8)
        XCTAssertTrue(stillLocal.contains("added-by-b"))
    }

    func testSetRemoteURLPersistsAcrossCoordinatorInstances() async throws {
        let bareRemote = try initBareRemote()
        let base = root.appendingPathComponent("persist-check", isDirectory: true)
        let sshDir = base.appendingPathComponent(".ssh", isDirectory: true)
        let appSupportDir = base.appendingPathComponent("AppSupport", isDirectory: true)
        try FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        let settingsFileURL = base.appendingPathComponent("sync-settings.json")

        func makeRepository() -> SyncRepository {
            SyncRepository(
                git: GitCommandRunner(repositoryURL: base.appendingPathComponent("sync", isDirectory: true)),
                resolver: SyncSetResolver(sshDirectoryURL: sshDir, appSupportDirectoryURL: appSupportDir),
                backupDirectoryURL: base.appendingPathComponent("Backups", isDirectory: true)
            )
        }

        let first = SyncCoordinator(repository: makeRepository(), settingsStore: SyncSettingsStore(fileURL: settingsFileURL))
        await first.setRemoteURL(bareRemote.path)

        let second = SyncCoordinator(repository: makeRepository(), settingsStore: SyncSettingsStore(fileURL: settingsFileURL))
        XCTAssertEqual(second.remoteURL, bareRemote.path)
        XCTAssertTrue(second.isConfigured)
    }
}
