import Combine
import Foundation
import XCTest
@testable import SSHConfigurator

final class TerminalSessionRecorderTests: XCTestCase {
    @MainActor
    func testRecordsEachPaneAsItsOwnCastFileWithOwnerOnlyPermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstPane = makePane(alias: "prod-api")
        let secondPane = makePane(alias: "prod-db")
        let session = TerminalSession(
            hostID: 1,
            alias: "Production",
            groupID: UUID(),
            layout: .split(
                id: UUID(),
                axis: .vertical,
                ratio: 0.5,
                first: .pane(firstPane),
                second: .pane(secondPane)
            ),
            activePaneID: firstPane.id
        )
        let recorder = TerminalSessionRecorder()

        XCTAssertTrue(recorder.start(session: session, folderURL: directory))
        recorder.append(
            Array("api ready\n".utf8),
            sessionID: session.id,
            paneID: firstPane.id,
            alias: firstPane.alias
        )
        recorder.append(
            Array("db ready\n".utf8),
            sessionID: session.id,
            paneID: secondPane.id,
            alias: secondPane.alias
        )
        recorder.stop(sessionID: session.id)

        let apiFile = directory.appendingPathComponent("prod-api-1.cast")
        let dbFile = directory.appendingPathComponent("prod-db-1.cast")

        let apiEvent = try lastEvent(in: apiFile)
        XCTAssertEqual(apiEvent[2] as? String, "api ready\n")
        let dbEvent = try lastEvent(in: dbFile)
        XCTAssertEqual(dbEvent[2] as? String, "db ready\n")

        // Each pane's file contains only its own output.
        XCTAssertFalse(try String(contentsOf: apiFile, encoding: .utf8).contains("db ready"))
        XCTAssertFalse(try String(contentsOf: dbFile, encoding: .utf8).contains("api ready"))

        let folderAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((folderAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)

        for fileURL in [apiFile, dbFile] {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }

    @MainActor
    func testCastHeaderIsFirstLineValidJSONWithVersion2AndExpectedTitle() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let pane = makePane(alias: "prod-api")
        let session = TerminalSession(hostID: 1, alias: "Production", layout: .pane(pane), activePaneID: pane.id)
        let recorder = TerminalSessionRecorder()

        XCTAssertTrue(recorder.start(session: session, folderURL: directory))
        recorder.append(Array("hi\n".utf8), sessionID: session.id, paneID: pane.id, alias: pane.alias)
        recorder.stop(sessionID: session.id)

        let lines = try castLines(at: directory.appendingPathComponent("prod-api-1.cast"))
        XCTAssertEqual(lines.count, 2, "expected a header line and exactly one event line")

        let header = try parseObject(lines[0])
        XCTAssertEqual(header["version"] as? Int, 2)
        XCTAssertEqual(header["width"] as? Int, 80)
        XCTAssertEqual(header["height"] as? Int, 24)
        XCTAssertNotNil(header["timestamp"] as? Int)
        XCTAssertEqual(header["title"] as? String, "Production — prod-api")
    }

    @MainActor
    func testEventsRoundTripExactBytesFedInThroughJSONSerialization() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let pane = makePane(alias: "prod")
        let session = TerminalSession(hostID: 1, alias: "prod", layout: .pane(pane), activePaneID: pane.id)
        let recorder = TerminalSessionRecorder()

        // ESC bytes, control characters, quotes, and backslashes — exactly
        // the content that would corrupt a hand-rolled JSON escaper.
        let raw = "\u{1B}[31mHello \"World\"\\end\u{1B}[0m\ttab\n"

        XCTAssertTrue(recorder.start(session: session, folderURL: directory))
        recorder.append(Array(raw.utf8), sessionID: session.id, paneID: pane.id, alias: pane.alias)
        recorder.stop(sessionID: session.id)

        let event = try lastEvent(in: directory.appendingPathComponent("prod-1.cast"))
        XCTAssertEqual(event[1] as? String, "o")
        XCTAssertEqual(event[2] as? String, raw)
        XCTAssertNotNil(event[0] as? Double)
    }

    @MainActor
    func testMultiByteUTF8CharacterSplitAcrossTwoAppendsArrivesIntact() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let pane = makePane(alias: "prod")
        let session = TerminalSession(hostID: 1, alias: "prod", layout: .pane(pane), activePaneID: pane.id)
        let recorder = TerminalSessionRecorder()

        // "ğ" (U+011F) is a 2-byte UTF-8 sequence: 0xC4 0x9F. Split it across
        // two `append` calls, exactly as a PTY chunk boundary would.
        let character = "ğ"
        let bytes = Array(character.utf8)
        XCTAssertEqual(bytes.count, 2)

        XCTAssertTrue(recorder.start(session: session, folderURL: directory))
        recorder.append([bytes[0]], sessionID: session.id, paneID: pane.id, alias: pane.alias)
        recorder.append([bytes[1]], sessionID: session.id, paneID: pane.id, alias: pane.alias)
        recorder.stop(sessionID: session.id)

        let fileURL = directory.appendingPathComponent("prod-1.cast")
        let lines = try castLines(at: fileURL)
        // Header + exactly one event: the first (incomplete) chunk must not
        // have produced a garbled event on its own.
        XCTAssertEqual(lines.count, 2)

        let event = try parseArray(lines[1])
        XCTAssertEqual(event[2] as? String, character)
    }

    @MainActor
    func testIgnoresOutputFromAnotherSession() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let pane = makePane(alias: "prod")
        let session = TerminalSession(hostID: 1, alias: "prod", layout: .pane(pane), activePaneID: pane.id)
        let recorder = TerminalSessionRecorder()

        XCTAssertTrue(recorder.start(session: session, folderURL: directory))
        recorder.append(
            Array("must not appear".utf8),
            sessionID: UUID(),
            paneID: pane.id,
            alias: pane.alias
        )
        recorder.stop(sessionID: session.id)

        // The mismatched session ID means `append` never resolved a
        // recording to write into, so no pane file was ever opened.
        let castFiles = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".cast") }
        XCTAssertTrue(castFiles.isEmpty)
    }

    @MainActor
    func testStopsWhenRecordedSessionCloses() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let pane = makePane(alias: "prod")
        let session = TerminalSession(hostID: 1, alias: "prod", layout: .pane(pane), activePaneID: pane.id)
        let recorder = TerminalSessionRecorder()

        XCTAssertTrue(recorder.start(session: session, folderURL: directory))
        recorder.stopIfSessionClosed(remainingSessionIDs: [])

        XCTAssertFalse(recorder.isRecording(session.id))
        XCTAssertNil(recorder.fileURL(for: session.id))
    }

    @MainActor
    func testOverwritingAnExistingCastFileTruncatesItAndRestrictsPermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // A stale file at the exact path the pane's file will be opened at.
        let fileURL = directory.appendingPathComponent("prod-1.cast")
        try Data("old sensitive output".utf8).write(to: fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)

        let pane = makePane(alias: "prod")
        let session = TerminalSession(hostID: 1, alias: "prod", layout: .pane(pane), activePaneID: pane.id)
        let recorder = TerminalSessionRecorder()

        XCTAssertTrue(recorder.start(session: session, folderURL: directory))
        recorder.append(Array("fresh output\n".utf8), sessionID: session.id, paneID: pane.id, alias: pane.alias)
        recorder.stop(sessionID: session.id)

        let output = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(output.contains("old sensitive output"))

        let lines = try castLines(at: fileURL)
        let header = try parseObject(lines[0])
        XCTAssertEqual(header["version"] as? Int, 2)

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    @MainActor
    func testSuggestedFolderNameRemovesUnsafeCharacters() {
        let date = Date(timeIntervalSince1970: 0)
        let name = TerminalSessionRecorder.suggestedFolderName(for: " Prod / DB ", date: date)

        XCTAssertTrue(name.hasPrefix("Terly-Prod-DB-"))
        XCTAssertFalse(name.hasSuffix(".log"))
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(" "))
    }

    // MARK: - 1.4 Multiple concurrent recordings

    @MainActor
    func testTwoSessionsRecordingConcurrentlyEachFolderGetsOnlyItsOwnFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let paneA = makePane(alias: "alpha")
        let paneB = makePane(alias: "beta")
        let sessionA = TerminalSession(hostID: 1, alias: "A", layout: .pane(paneA), activePaneID: paneA.id)
        let sessionB = TerminalSession(hostID: 2, alias: "B", layout: .pane(paneB), activePaneID: paneB.id)
        // Folders don't exist yet — `start` must create them.
        let folderA = directory.appendingPathComponent("recording-a", isDirectory: true)
        let folderB = directory.appendingPathComponent("recording-b", isDirectory: true)
        let recorder = TerminalSessionRecorder()

        XCTAssertTrue(recorder.start(session: sessionA, folderURL: folderA))
        XCTAssertTrue(recorder.start(session: sessionB, folderURL: folderB))
        XCTAssertTrue(recorder.isRecording(sessionA.id))
        XCTAssertTrue(recorder.isRecording(sessionB.id))

        // Interleaved appends across both sessions — starting the second
        // recording must not stop the first (the old single-`activeSessionID`
        // bug), and each session's bytes must land only in its own folder.
        recorder.append(Array("alpha-1\n".utf8), sessionID: sessionA.id, paneID: paneA.id, alias: paneA.alias)
        recorder.append(Array("beta-1\n".utf8), sessionID: sessionB.id, paneID: paneB.id, alias: paneB.alias)
        recorder.append(Array("alpha-2\n".utf8), sessionID: sessionA.id, paneID: paneA.id, alias: paneA.alias)
        recorder.append(Array("beta-2\n".utf8), sessionID: sessionB.id, paneID: paneB.id, alias: paneB.alias)

        recorder.stop(sessionID: sessionA.id)
        recorder.stop(sessionID: sessionB.id)

        XCTAssertFalse(recorder.isRecording(sessionA.id))
        XCTAssertFalse(recorder.isRecording(sessionB.id))

        let filesA = try FileManager.default.contentsOfDirectory(atPath: folderA.path)
        let filesB = try FileManager.default.contentsOfDirectory(atPath: folderB.path)
        XCTAssertEqual(filesA, ["alpha-1.cast"])
        XCTAssertEqual(filesB, ["beta-1.cast"])

        let outputA = try String(contentsOf: folderA.appendingPathComponent("alpha-1.cast"), encoding: .utf8)
        let outputB = try String(contentsOf: folderB.appendingPathComponent("beta-1.cast"), encoding: .utf8)

        XCTAssertTrue(outputA.contains("alpha-1"))
        XCTAssertTrue(outputA.contains("alpha-2"))
        XCTAssertFalse(outputA.contains("beta"))

        XCTAssertTrue(outputB.contains("beta-1"))
        XCTAssertTrue(outputB.contains("beta-2"))
        XCTAssertFalse(outputB.contains("alpha"))
    }

    // MARK: - 1.1 Ordering trap: buffer must flush before close, synchronously

    @MainActor
    func testStopFlushesAllBufferedEventsInOrderSynchronously() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let pane = makePane(alias: "prod")
        let session = TerminalSession(hostID: 1, alias: "prod", layout: .pane(pane), activePaneID: pane.id)
        let recorder = TerminalSessionRecorder()

        XCTAssertTrue(recorder.start(session: session, folderURL: directory))

        // Many small chunks, well under the 64 KB flush threshold both
        // individually and cumulatively, so none of this has reached disk
        // yet — it's all still sitting in the in-memory buffer.
        let lineCount = 50
        for index in 0..<lineCount {
            recorder.append(
                Array("line-\(index)\n".utf8),
                sessionID: session.id,
                paneID: pane.id,
                alias: pane.alias
            )
        }

        recorder.stop(sessionID: session.id)

        // No wait/poll here: `stop()` is synchronous, so the file must
        // already be complete and readable the instant this call returns.
        let lines = try castLines(at: directory.appendingPathComponent("prod-1.cast"))
        XCTAssertEqual(lines.count, lineCount + 1, "header + one event per append")

        for index in 0..<lineCount {
            let event = try parseArray(lines[index + 1])
            XCTAssertEqual(event[2] as? String, "line-\(index)\n", "line-\(index) missing or out of order")
        }
    }

    // MARK: - 1.5 Size cap

    @MainActor
    func testSizeCapStopsTheRecordingAndSetsErrorMessage() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let pane = makePane(alias: "prod")
        let session = TerminalSession(hostID: 1, alias: "prod", layout: .pane(pane), activePaneID: pane.id)
        let recorder = TerminalSessionRecorder()
        recorder.sizeCapBytes = 64 // well under the 64 KB flush threshold

        XCTAssertTrue(recorder.start(session: session, folderURL: directory))

        let expectation = expectation(description: "cap-triggered errorMessage")
        let cancellable = recorder.$errorMessage
            .dropFirst()
            .sink { message in
                if message != nil {
                    expectation.fulfill()
                }
            }

        recorder.append(
            Array(repeating: UInt8(ascii: "x"), count: 200),
            sessionID: session.id,
            paneID: pane.id,
            alias: pane.alias
        )

        await fulfillment(of: [expectation], timeout: 2)
        cancellable.cancel()

        XCTAssertNotNil(recorder.errorMessage)
        XCTAssertTrue(recorder.errorMessage?.contains("size limit") ?? false)
        XCTAssertFalse(recorder.isRecording(session.id))

        // The pane file was flushed and closed on the write queue as part of
        // the very same cap-hit step that preceded the errorMessage hop, so
        // it's already complete (and structurally valid) by now.
        let lines = try castLines(at: directory.appendingPathComponent("prod-1.cast"))
        XCTAssertEqual(lines.count, 2)
        let event = try parseArray(lines[1])
        XCTAssertEqual((event[2] as? String)?.count, 200)
    }

    private func makePane(alias: String) -> TerminalPane {
        TerminalPane(
            alias: alias,
            process: TerminalProcessConfiguration(
                executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
                arguments: ["--", alias],
                environment: [:],
                currentDirectoryURL: nil
            )
        )
    }

    // MARK: - Cast v2 test helpers

    private func castLines(at fileURL: URL) throws -> [String] {
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        return content
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private func parseObject(_ line: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8), options: [])
        return try XCTUnwrap(object as? [String: Any])
    }

    private func parseArray(_ line: String) throws -> [Any] {
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8), options: [])
        return try XCTUnwrap(object as? [Any])
    }

    /// Reads the last event line of a `.cast` file (the header is line 1).
    private func lastEvent(in fileURL: URL) throws -> [Any] {
        let lines = try castLines(at: fileURL)
        let lastLine = try XCTUnwrap(lines.last)
        return try parseArray(lastLine)
    }
}
