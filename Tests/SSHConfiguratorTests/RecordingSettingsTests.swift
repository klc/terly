import XCTest
@testable import SSHConfigurator

final class RecordingSettingsTests: XCTestCase {
    func testNilCustomPathUsesDefault() {
        let fileManager = FileManager.default
        XCTAssertEqual(
            RecordingSettings.resolveRootURL(customPath: nil, fileManager: fileManager),
            RecordingSettings.defaultRootURL(fileManager: fileManager)
        )
    }

    func testExistingDirectoryIsUsed() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertEqual(RecordingSettings.resolveRootURL(customPath: directory.path), directory)
    }

    func testMissingCustomPathFallsBackWithoutCreatingIt() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertEqual(RecordingSettings.resolveRootURL(customPath: directory.path), RecordingSettings.defaultRootURL())
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testFileCustomPathFallsBack() throws {
        let fileURL = temporaryDirectory()
        try Data("not a directory".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        XCTAssertEqual(RecordingSettings.resolveRootURL(customPath: fileURL.path), RecordingSettings.defaultRootURL())
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
