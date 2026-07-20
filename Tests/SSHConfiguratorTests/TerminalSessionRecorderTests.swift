import Combine
import Foundation
import XCTest
@testable import SSHConfigurator

final class TerminalSessionRecorderTests: XCTestCase {
    @MainActor
    func testRecordsVisibleOutputFromAllPanesAndUsesOwnerOnlyPermissions() throws {
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
        let fileURL = directory.appendingPathComponent("session.log")
        let recorder = TerminalSessionRecorder()

        XCTAssertTrue(recorder.start(session: session, fileURL: fileURL))
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

        let output = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(output.contains("Session: Production"))
        XCTAssertTrue(output.contains("--- prod-api"))
        XCTAssertTrue(output.contains("api ready"))
        XCTAssertTrue(output.contains("--- prod-db"))
        XCTAssertTrue(output.contains("db ready"))
        XCTAssertTrue(output.contains("Recording ended:"))

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    @MainActor
    func testIgnoresOutputFromAnotherSession() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let pane = makePane(alias: "prod")
        let session = TerminalSession(hostID: 1, alias: "prod", layout: .pane(pane), activePaneID: pane.id)
        let fileURL = directory.appendingPathComponent("session.log")
        let recorder = TerminalSessionRecorder()

        XCTAssertTrue(recorder.start(session: session, fileURL: fileURL))
        recorder.append(
            Array("must not appear".utf8),
            sessionID: UUID(),
            paneID: pane.id,
            alias: pane.alias
        )
        recorder.stop(sessionID: session.id)

        let output = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(output.contains("must not appear"))
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

        XCTAssertTrue(recorder.start(session: session, fileURL: directory.appendingPathComponent("session.log")))
        recorder.stopIfSessionClosed(remainingSessionIDs: [])

        XCTAssertFalse(recorder.isRecording(session.id))
        XCTAssertNil(recorder.fileURL(for: session.id))
    }

    @MainActor
    func testOverwritingAnExistingLogTruncatesItAndRestrictsPermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("session.log")
        try Data("old sensitive output".utf8).write(to: fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)

        let pane = makePane(alias: "prod")
        let session = TerminalSession(hostID: 1, alias: "prod", layout: .pane(pane), activePaneID: pane.id)
        let recorder = TerminalSessionRecorder()

        XCTAssertTrue(recorder.start(session: session, fileURL: fileURL))
        recorder.stop(sessionID: session.id)

        let output = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(output.contains("old sensitive output"))
        XCTAssertTrue(output.contains("Terly session recording"))
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    @MainActor
    func testSuggestedFilenameRemovesUnsafeCharacters() {
        let date = Date(timeIntervalSince1970: 0)
        let filename = TerminalSessionRecorder.suggestedFilename(for: " Prod / DB ", date: date)

        XCTAssertTrue(filename.hasPrefix("Terly-Prod-DB-"))
        XCTAssertTrue(filename.hasSuffix(".log"))
        XCTAssertFalse(filename.contains("/"))
        XCTAssertFalse(filename.contains(" "))
    }

    // MARK: - 1.4 Multiple concurrent recordings

    @MainActor
    func testTwoSessionsRecordingConcurrentlyEachFileGetsOnlyItsOwnBytes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let paneA = makePane(alias: "alpha")
        let paneB = makePane(alias: "beta")
        let sessionA = TerminalSession(hostID: 1, alias: "A", layout: .pane(paneA), activePaneID: paneA.id)
        let sessionB = TerminalSession(hostID: 2, alias: "B", layout: .pane(paneB), activePaneID: paneB.id)
        let fileA = directory.appendingPathComponent("a.log")
        let fileB = directory.appendingPathComponent("b.log")
        let recorder = TerminalSessionRecorder()

        XCTAssertTrue(recorder.start(session: sessionA, fileURL: fileA))
        XCTAssertTrue(recorder.start(session: sessionB, fileURL: fileB))
        XCTAssertTrue(recorder.isRecording(sessionA.id))
        XCTAssertTrue(recorder.isRecording(sessionB.id))

        // Interleaved appends across both sessions — starting the second
        // recording must not stop the first (the old single-`activeSessionID`
        // bug), and each session's bytes must land only in its own file.
        recorder.append(Array("alpha-1\n".utf8), sessionID: sessionA.id, paneID: paneA.id, alias: paneA.alias)
        recorder.append(Array("beta-1\n".utf8), sessionID: sessionB.id, paneID: paneB.id, alias: paneB.alias)
        recorder.append(Array("alpha-2\n".utf8), sessionID: sessionA.id, paneID: paneA.id, alias: paneA.alias)
        recorder.append(Array("beta-2\n".utf8), sessionID: sessionB.id, paneID: paneB.id, alias: paneB.alias)

        recorder.stop(sessionID: sessionA.id)
        recorder.stop(sessionID: sessionB.id)

        XCTAssertFalse(recorder.isRecording(sessionA.id))
        XCTAssertFalse(recorder.isRecording(sessionB.id))

        let outputA = try String(contentsOf: fileA, encoding: .utf8)
        let outputB = try String(contentsOf: fileB, encoding: .utf8)

        XCTAssertTrue(outputA.contains("alpha-1"))
        XCTAssertTrue(outputA.contains("alpha-2"))
        XCTAssertFalse(outputA.contains("beta"))

        XCTAssertTrue(outputB.contains("beta-1"))
        XCTAssertTrue(outputB.contains("beta-2"))
        XCTAssertFalse(outputB.contains("alpha"))
    }

    // MARK: - 1.1 Ordering trap: buffer must flush before the footer

    @MainActor
    func testStopFlushesAllBufferedBytesInOrderBeforeTheFooterSynchronously() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let pane = makePane(alias: "prod")
        let session = TerminalSession(hostID: 1, alias: "prod", layout: .pane(pane), activePaneID: pane.id)
        let fileURL = directory.appendingPathComponent("session.log")
        let recorder = TerminalSessionRecorder()

        XCTAssertTrue(recorder.start(session: session, fileURL: fileURL))

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
        let output = try String(contentsOf: fileURL, encoding: .utf8)

        guard let footerRange = output.range(of: "Recording ended:") else {
            XCTFail("footer missing")
            return
        }

        var previousUpperBound = output.startIndex
        for index in 0..<lineCount {
            guard let lineRange = output.range(of: "line-\(index)\n") else {
                XCTFail("line-\(index) missing from recording")
                continue
            }
            // In order relative to the previous line...
            XCTAssertTrue(lineRange.lowerBound >= previousUpperBound, "line-\(index) out of order")
            // ...and entirely before the footer.
            XCTAssertTrue(lineRange.upperBound <= footerRange.lowerBound, "line-\(index) appears after the footer")
            previousUpperBound = lineRange.upperBound
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
        let fileURL = directory.appendingPathComponent("session.log")
        let recorder = TerminalSessionRecorder()
        recorder.sizeCapBytes = 64 // well under the 64 KB flush threshold

        XCTAssertTrue(recorder.start(session: session, fileURL: fileURL))

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
        XCTAssertFalse(recorder.isRecording(session.id))

        // The file itself was flushed, footer-written, and closed on the
        // write queue as part of the very same cap-hit step that preceded
        // the errorMessage hop, so it's already complete by now.
        let output = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(output.contains("size limit"))
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
}
