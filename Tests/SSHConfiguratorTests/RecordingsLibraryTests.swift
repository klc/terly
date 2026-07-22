import XCTest
@testable import SSHConfigurator

@MainActor
final class RecordingsLibraryTests: XCTestCase {
    func testScanFiltersSortsAndCountsPanes() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let old = try makeRecording(root: root, name: "old", castNames: ["api-1"], date: Date(timeIntervalSince1970: 10))
        let new = try makeRecording(root: root, name: "renamed freely", castNames: ["db-1", "api-1"], date: Date(timeIntervalSince1970: 20))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("loose.cast"))

        let results = RecordingsLibrary.scan(root: root)
        XCTAssertEqual(results.map(\.name), [new.lastPathComponent, old.lastPathComponent])
        XCTAssertEqual(results.map(\.paneCount), [2, 1])
        XCTAssertEqual(results[0].casts.map(\.name), ["api-1", "db-1"])
        XCTAssertEqual(results[0].duration, 3)
    }

    func testRenameRejectsInvalidAndCollisionThenMovesValidName() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = try makeRecording(root: root, name: "source", castNames: ["pane-1"], date: Date())
        _ = try makeRecording(root: root, name: "taken", castNames: ["pane-1"], date: Date())
        let summary = try XCTUnwrap(RecordingsLibrary.scan(root: root).first { $0.name == source.lastPathComponent })
        let library = makeLibrary(root: root)

        library.rename(summary, to: "bad/name")
        XCTAssertNotNil(library.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        library.rename(summary, to: "taken")
        XCTAssertNotNil(library.errorMessage)
        library.rename(summary, to: "renamed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("renamed").path))
    }

    func testDeleteUsesInjectedTrashHandler() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let folder = try makeRecording(root: root, name: "delete-me", castNames: ["pane-1"], date: Date())
        var trashed: URL?
        let library = makeLibrary(root: root) { trashed = $0 }
        library.refresh()
        await waitUntil { !library.isLoading }
        let summary = try XCTUnwrap(library.recordings.first)

        library.delete(summary)
        XCTAssertEqual(trashed?.standardizedFileURL.path, folder.standardizedFileURL.path)
        XCTAssertTrue(library.recordings.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), "the test spy must never touch the real Trash")
    }

    private func makeLibrary(root: URL, trash: ((URL) throws -> Void)? = nil) -> RecordingsLibrary {
        let suite = "RecordingsLibraryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(root.path, forKey: "recordings.rootPath")
        let settings = RecordingSettings(defaults: defaults)
        return RecordingsLibrary(settings: settings, trashHandler: trash)
    }

    private func makeRecording(root: URL, name: String, castNames: [String], date: Date) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for castName in castNames {
            let url = folder.appendingPathComponent("\(castName).cast")
            let header: [String: Any] = ["version": 2, "width": 80, "height": 24]
            var data = try JSONSerialization.data(withJSONObject: header)
            data.append(0x0A)
            data.append(try JSONSerialization.data(withJSONObject: [3.0, "o", "ok"]))
            data.append(0x0A)
            try data.write(to: url)
        }
        try FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: folder.path)
        return folder
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<100 where !condition() { await Task.yield() }
    }
}
