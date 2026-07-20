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
        recorder.stop()

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
        recorder.stop()

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

        XCTAssertNil(recorder.activeSessionID)
        XCTAssertNil(recorder.fileURL)
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
        recorder.stop()

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
