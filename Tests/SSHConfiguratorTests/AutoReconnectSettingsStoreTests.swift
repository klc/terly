import Foundation
import XCTest
@testable import SSHConfigurator

final class AutoReconnectSettingsStoreTests: XCTestCase {
    func testAtomicallySavesAndLoadsStateWithOwnerOnlyFileAndDirectoryPermissions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = root.appendingPathComponent("nested", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: directory.path
        )
        let fileURL = directory.appendingPathComponent("auto-reconnect.json")
        let store = AutoReconnectSettingsStore(fileURL: fileURL)
        let state = AutoReconnectSettingsState(enabledAliases: ["prod-api", "prod-db"])

        try store.save(state)

        XCTAssertEqual(try store.load(), state)
        XCTAssertEqual(try permissions(at: fileURL), 0o600)
        XCTAssertEqual(try permissions(at: directory), 0o700)
    }

    func testMissingFileLoadsAsEmptyState() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("auto-reconnect.json")

        XCTAssertEqual(try AutoReconnectSettingsStore(fileURL: fileURL).load(), AutoReconnectSettingsState())
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let posix = attributes[.posixPermissions] as? NSNumber
        return posix?.intValue ?? -1
    }
}
