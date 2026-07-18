import Foundation
import XCTest
@testable import SSHConfigurator

final class SyncSettingsStoreTests: XCTestCase {
    func testRoundTripsAndUsesOwnerOnlyPermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("nested/sync-settings.json")
        let store = SyncSettingsStore(fileURL: fileURL)

        // ISO 8601 encoding is whole-seconds; round the input the same way
        // so the round-trip comparison isn't comparing away sub-second noise.
        let lastSyncedAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let settings = SyncSettings(remoteURL: "git@github.com:example/dotfiles.git", autoPushEnabled: true, lastSyncedAt: lastSyncedAt)
        try store.save(settings)

        XCTAssertEqual(try store.load(), settings)
        let permissions = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.uint16Value, 0o600)
    }

    func testMissingFileLoadsAsDefaults() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("sync-settings.json")
        let store = SyncSettingsStore(fileURL: fileURL)

        let settings = try store.load()
        XCTAssertNil(settings.remoteURL)
        XCTAssertFalse(settings.autoPushEnabled)
        XCTAssertNil(settings.lastSyncedAt)
    }

    /// The settings file holds only a remote address and a toggle — never a
    /// token, password, or credential. This is the file most likely to be
    /// glanced at while debugging, so the absence is worth pinning down.
    func testNeverPersistsAnythingResemblingACredential() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("sync-settings.json")
        let store = SyncSettingsStore(fileURL: fileURL)
        try store.save(SyncSettings(remoteURL: "https://example.com/dotfiles.git", autoPushEnabled: true, lastSyncedAt: Date()))

        let data = try Data(contentsOf: fileURL)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["remoteURL", "autoPushEnabled", "lastSyncedAt"]))
    }
}
