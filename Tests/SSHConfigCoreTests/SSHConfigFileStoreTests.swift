import Foundation
import XCTest
@testable import SSHConfigCore

final class SSHConfigFileStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssh-configurator-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testSaveCreatesBackupAndRestrictsPermissions() throws {
        let configURL = root.appendingPathComponent("config")
        let backupDirectory = root.appendingPathComponent("backups", isDirectory: true)
        try "Host old\n  User deploy\n".write(to: configURL, atomically: true, encoding: .utf8)
        let store = SSHConfigFileStore(backupDirectory: backupDirectory)
        let snapshot = try store.snapshot(at: configURL)
        let edited = SSHConfigDocument(source: "Host new\n  User deploy\n")

        let result = try store.save(edited, expectedSnapshot: snapshot)

        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), edited.source)
        XCTAssertEqual(try String(contentsOf: try XCTUnwrap(result.backupURL), encoding: .utf8), snapshot.source)
        XCTAssertEqual(permissions(of: configURL), 0o600)
        XCTAssertEqual(permissions(of: try XCTUnwrap(result.backupURL)), 0o600)
    }

    func testSaveRejectsExternalChanges() throws {
        let configURL = root.appendingPathComponent("config")
        try "Host original\n".write(to: configURL, atomically: true, encoding: .utf8)
        let store = SSHConfigFileStore(backupDirectory: root.appendingPathComponent("backups"))
        let snapshot = try store.snapshot(at: configURL)
        try "Host external\n".write(to: configURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try store.save(SSHConfigDocument(source: "Host app\n"), expectedSnapshot: snapshot)
        ) { error in
            guard case let SSHConfigFileStoreError.fileChangedExternally(url) = error else {
                return XCTFail("Beklenen harici değişiklik hatası alınmadı: \(error)")
            }
            XCTAssertEqual(url, configURL)
        }
    }

    func testRestoreKeepsCurrentVersionAsANewBackup() throws {
        let configURL = root.appendingPathComponent("config")
        let backupDirectory = root.appendingPathComponent("backups", isDirectory: true)
        let store = SSHConfigFileStore(backupDirectory: backupDirectory)
        let original = "Host original\n  User first\n"
        let current = "Host current\n  User second\n"
        try original.write(to: configURL, atomically: true, encoding: .utf8)

        let originalSnapshot = try store.snapshot(at: configURL)
        _ = try store.save(SSHConfigDocument(source: current), expectedSnapshot: originalSnapshot)
        let originalBackup = try XCTUnwrap(try store.backups().first)
        let currentSnapshot = try store.snapshot(at: configURL)

        let result = try store.restore(originalBackup, expectedSnapshot: currentSnapshot)

        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), original)
        XCTAssertEqual(try String(contentsOf: try XCTUnwrap(result.backupURL), encoding: .utf8), current)
        XCTAssertEqual(try store.backups().count, 2)
    }

    func testBackupsArePrunedToRetentionLimit() throws {
        let configURL = root.appendingPathComponent("config")
        let backupDirectory = root.appendingPathComponent("backups", isDirectory: true)
        let store = SSHConfigFileStore(backupDirectory: backupDirectory, retentionLimit: 3)
        try "Host revision-0\n".write(to: configURL, atomically: true, encoding: .utf8)

        for revision in 1...5 {
            let snapshot = try store.snapshot(at: configURL)
            _ = try store.save(SSHConfigDocument(source: "Host revision-\(revision)\n"), expectedSnapshot: snapshot)
        }

        let backups = try store.backups()
        XCTAssertEqual(backups.count, 3)
        let retained = try backups.map { try String(contentsOf: $0.url, encoding: .utf8) }
        XCTAssertEqual(retained, ["Host revision-4\n", "Host revision-3\n", "Host revision-2\n"])
    }

    func testIdenticalContentDoesNotCreateDuplicateBackup() throws {
        let configURL = root.appendingPathComponent("config")
        let backupDirectory = root.appendingPathComponent("backups", isDirectory: true)
        let store = SSHConfigFileStore(backupDirectory: backupDirectory)
        try "Host original\n".write(to: configURL, atomically: true, encoding: .utf8)

        let first = try store.snapshot(at: configURL)
        _ = try store.save(SSHConfigDocument(source: "Host edited\n"), expectedSnapshot: first)
        XCTAssertEqual(try store.backups().count, 1)

        // Aynı içeriği geri yazmak yedeklenecek yeni bir sürüm üretmez.
        try "Host original\n".write(to: configURL, atomically: true, encoding: .utf8)
        let second = try store.snapshot(at: configURL)
        let result = try store.save(SSHConfigDocument(source: "Host edited\n"), expectedSnapshot: second)

        XCTAssertNil(result.backupURL)
        XCTAssertEqual(try store.backups().count, 1)
    }

    private func permissions(of url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let rawPermissions = (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? 0
        return Int(rawPermissions) & 0o777
    }
}
