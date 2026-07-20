import Combine
import Foundation

@MainActor
final class TerminalSessionRecorder: ObservableObject {
    @Published private(set) var activeSessionID: TerminalSession.ID?
    @Published private(set) var fileURL: URL?
    @Published private(set) var errorMessage: String?

    private var fileHandle: FileHandle?
    private var lastPaneID: TerminalPane.ID?

    func isRecording(_ sessionID: TerminalSession.ID) -> Bool {
        activeSessionID == sessionID
    }

    @discardableResult
    func start(session: TerminalSession, fileURL: URL) -> Bool {
        errorMessage = nil
        stop()

        do {
            let handle = try Self.prepareFile(at: fileURL)
            fileHandle = handle
            activeSessionID = session.id
            self.fileURL = fileURL
            lastPaneID = nil

            let aliases = session.panes.map(\.alias).joined(separator: ", ")
            let header = "Terly session recording\nSession: \(session.displayTitle)\nConnections: \(aliases)\nStarted: \(Self.timestamp())\n\n"
            try handle.write(contentsOf: Data(header.utf8))
            return true
        } catch {
            try? fileHandle?.close()
            resetState()
            errorMessage = String(localized: "Session recording could not be started: \(error.localizedDescription)")
            return false
        }
    }

    func append(
        _ bytes: [UInt8],
        sessionID: TerminalSession.ID,
        paneID: TerminalPane.ID,
        alias: String
    ) {
        guard !bytes.isEmpty,
              activeSessionID == sessionID,
              let fileHandle else { return }

        do {
            if lastPaneID != paneID {
                let separator = "\n--- \(alias) · \(Self.timestamp()) ---\n"
                try fileHandle.write(contentsOf: Data(separator.utf8))
                lastPaneID = paneID
            }
            try fileHandle.write(contentsOf: Data(bytes))
        } catch {
            let message = String(localized: "Session recording stopped because the file could not be written: \(error.localizedDescription)")
            stop()
            errorMessage = message
        }
    }

    func stop() {
        guard let fileHandle else {
            resetState()
            return
        }

        var stopError: Error?
        do {
            let footer = "\n\nRecording ended: \(Self.timestamp())\n"
            try fileHandle.write(contentsOf: Data(footer.utf8))
            try fileHandle.synchronize()
            try fileHandle.close()
        } catch {
            stopError = error
            try? fileHandle.close()
        }
        resetState()
        if let stopError {
            errorMessage = String(localized: "Session recording stopped because the file could not be written: \(stopError.localizedDescription)")
        }
    }

    func stopIfSessionClosed(remainingSessionIDs: Set<TerminalSession.ID>) {
        guard let activeSessionID, !remainingSessionIDs.contains(activeSessionID) else { return }
        stop()
    }

    func dismissError() {
        errorMessage = nil
    }

    static func suggestedFilename(for sessionTitle: String, date: Date = Date()) -> String {
        let safeTitle = sessionTitle
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .map { character -> Character in
                character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-"
            }
        let collapsedTitle = String(safeTitle)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let title = collapsedTitle.isEmpty ? "session" : collapsedTitle
        return "Terly-\(title)-\(formatter.string(from: date)).log"
    }

    private static func prepareFile(at fileURL: URL) throws -> FileHandle {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.truncate(atOffset: 0)
            return handle
        }

        guard fileManager.createFile(
            atPath: fileURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return try FileHandle(forWritingTo: fileURL)
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private func resetState() {
        fileHandle = nil
        activeSessionID = nil
        fileURL = nil
        lastPaneID = nil
    }
}
