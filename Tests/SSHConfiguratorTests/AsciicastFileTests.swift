import XCTest
@testable import SSHConfigurator

final class AsciicastFileTests: XCTestCase {
    func testRoundTripAndEscapedOutput() throws {
        let url = temporaryCastURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let output = "\u{1B}[31m\"quoted\"\\path\n"
        try writeCast(url: url, events: [[0.25, "o", output], [1.5, "i", "ignored"]])

        let cast = try AsciicastFile.load(url: url)
        XCTAssertEqual(cast.header.version, 2)
        XCTAssertEqual(cast.header.width, 80)
        XCTAssertEqual(cast.events[0], AsciicastEvent(time: 0.25, kind: "o", data: output))
        XCTAssertEqual(cast.duration, 1.5)
    }

    func testTruncatedFinalEventIsIgnoredAndTimesAreMonotonic() throws {
        let url = temporaryCastURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try writeCast(url: url, events: [[2.0, "o", "first"], [1.0, "o", "second"]], trailing: "[3.0,\"o\",\"cut")

        let cast = try AsciicastFile.load(url: url)
        XCTAssertEqual(cast.events.map(\.time), [2, 2])
        XCTAssertEqual(cast.events.map(\.data), ["first", "second"])
    }

    func testQuickDurationForSmallAndLargeFiles() throws {
        for paddingSize in [0, 70 * 1024] {
            let url = temporaryCastURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let padding = String(repeating: "x", count: paddingSize)
            try writeCast(url: url, events: [[1.0, "o", padding], [42.5, "o", "last"]])
            XCTAssertEqual(AsciicastFile.quickDuration(url: url), 42.5)
        }
    }

    func testUnsupportedAndGarbageHeadersThrow() throws {
        let url = temporaryCastURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try writeCast(url: url, version: 3, events: [])
        XCTAssertThrowsError(try AsciicastFile.load(url: url)) { error in
            XCTAssertEqual(error as? AsciicastFile.ParseError, .unsupportedVersion(3))
        }

        try Data("garbage\n".utf8).write(to: url)
        XCTAssertThrowsError(try AsciicastFile.load(url: url)) { error in
            XCTAssertEqual(error as? AsciicastFile.ParseError, .invalidHeader)
        }
    }

    func testOversizeThrowsBeforeReading() throws {
        let url = temporaryCastURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(AsciicastFile.maximumFileSize + 1))
        try handle.close()

        XCTAssertThrowsError(try AsciicastFile.load(url: url)) { error in
            XCTAssertEqual(error as? AsciicastFile.ParseError, .fileTooLarge)
        }
    }

    private func temporaryCastURL() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("test.cast")
    }

    private func writeCast(url: URL, version: Int = 2, events: [[Any]], trailing: String? = nil) throws {
        let header: [String: Any] = ["version": version, "width": 80, "height": 24, "timestamp": 123, "title": "Test"]
        var data = try JSONSerialization.data(withJSONObject: header)
        data.append(0x0A)
        for event in events {
            data.append(try JSONSerialization.data(withJSONObject: event))
            data.append(0x0A)
        }
        if let trailing { data.append(Data(trailing.utf8)) }
        try data.write(to: url)
    }
}
