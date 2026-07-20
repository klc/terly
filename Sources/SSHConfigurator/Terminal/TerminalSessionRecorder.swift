import Combine
import Foundation

/// Records raw terminal output for one or more sessions to `.log` files.
///
/// Concurrency shape: all *decisions* (start/stop/is-recording/error surface)
/// live on `@MainActor`, matching the rest of the SwiftUI layer this is
/// driven from. Actual file I/O never happens on the main thread — it's
/// buffered and flushed on a single serial `writeQueue`. A serial queue (not
/// a Swift `actor`) is required because `stop(sessionID:)` is called from
/// synchronous `@MainActor` SwiftUI closures (`toggleRecording`, the
/// `onChange` session-closed handler) and must stay synchronous/non-async so
/// those call sites can rely on the file being fully written the moment
/// `stop` returns — an `actor` would force `stop` to become `async`.
///
/// `RecordingState` holds the mutable write-side state (file handle, buffer,
/// byte count) for one recording. It is intentionally *not* part of this
/// `@MainActor` class: every mutable field on it is only ever touched from a
/// closure running on `writeQueue`, which is the actual synchronization
/// mechanism — `@unchecked Sendable` is the documented escape hatch for
/// "confined to one queue," not "confined to one actor."
@MainActor
final class TerminalSessionRecorder: ObservableObject {
    @Published private(set) var activeSessionIDs: Set<TerminalSession.ID> = []
    @Published private(set) var errorMessage: String?

    /// Per-recording byte cap before it's stopped automatically. A `var`
    /// (not a fixed constant) so tests can dial it down instead of writing
    /// 100 MB of fixture data; production code never needs to change it.
    var sizeCapBytes: Int = 100 * 1024 * 1024

    /// Bytes buffered in memory before an append forces a flush to disk, so
    /// a chatty session doesn't dispatch one write per tiny output chunk.
    private nonisolated static let flushThresholdBytes = 64 * 1024

    private final class RecordingState: @unchecked Sendable {
        let sessionID: TerminalSession.ID
        let fileHandle: FileHandle
        let fileURL: URL
        var buffer = Data()
        var lastPaneID: TerminalPane.ID?
        var bytesWritten = 0
        var isClosed = false

        init(sessionID: TerminalSession.ID, fileHandle: FileHandle, fileURL: URL) {
            self.sessionID = sessionID
            self.fileHandle = fileHandle
            self.fileURL = fileURL
        }
    }

    private let writeQueue = DispatchQueue(label: "com.terly.session-recorder", qos: .utility)
    private var recordings: [TerminalSession.ID: RecordingState] = [:]
    /// Periodic per-recording flush timers, kept here (MainActor-only)
    /// rather than on `RecordingState` so creating/cancelling one never
    /// races the write queue — only the timer's *event handler* runs there.
    private var flushTimers: [TerminalSession.ID: DispatchSourceTimer] = [:]

    func isRecording(_ sessionID: TerminalSession.ID) -> Bool {
        activeSessionIDs.contains(sessionID)
    }

    func fileURL(for sessionID: TerminalSession.ID) -> URL? {
        recordings[sessionID]?.fileURL
    }

    @discardableResult
    func start(session: TerminalSession, fileURL: URL) -> Bool {
        errorMessage = nil
        stop(sessionID: session.id)

        let handle: FileHandle
        do {
            handle = try Self.prepareFile(at: fileURL)
        } catch {
            errorMessage = String(localized: "Session recording could not be started: \(error.localizedDescription)")
            return false
        }

        do {
            let aliases = session.panes.map(\.alias).joined(separator: ", ")
            let header = "Terly session recording\nSession: \(session.displayTitle)\nConnections: \(aliases)\nStarted: \(Self.timestamp())\n\n"
            try handle.write(contentsOf: Data(header.utf8))
        } catch {
            try? handle.close()
            errorMessage = String(localized: "Session recording could not be started: \(error.localizedDescription)")
            return false
        }

        let state = RecordingState(sessionID: session.id, fileHandle: handle, fileURL: fileURL)
        recordings[session.id] = state
        activeSessionIDs.insert(session.id)
        startFlushTimer(for: session.id, state: state)
        return true
    }

    func append(
        _ bytes: [UInt8],
        sessionID: TerminalSession.ID,
        paneID: TerminalPane.ID,
        alias: String
    ) {
        guard !bytes.isEmpty, let state = recordings[sessionID] else { return }
        let cap = sizeCapBytes

        writeQueue.async { [weak self] in
            guard let self, !state.isClosed else { return }

            if state.lastPaneID != paneID {
                let separator = "\n--- \(alias) · \(Self.timestamp()) ---\n"
                state.buffer.append(Data(separator.utf8))
                state.lastPaneID = paneID
            }
            state.buffer.append(Data(bytes))

            // Total *accepted* bytes (flushed + still-buffered), not just
            // flushed bytes — data sitting in the buffer already counts
            // against the cap, so a cap smaller than the flush threshold
            // (as tests use) is still enforced immediately.
            let totalAccepted = state.bytesWritten + state.buffer.count
            if totalAccepted >= cap {
                self.finishDueToCap(state, capBytes: cap)
            } else if state.buffer.count >= Self.flushThresholdBytes {
                self.performFlush(state)
            }
        }
    }

    /// Stops the recording for one session. Synchronous by design: by the
    /// time this returns, all buffered bytes have been flushed BEFORE the
    /// footer was written (ordering is explicit in `writeQueue.sync` below),
    /// and the file has been synchronized and closed — no polling required
    /// to observe a complete file afterward.
    func stop(sessionID: TerminalSession.ID) {
        guard let state = recordings.removeValue(forKey: sessionID) else { return }
        activeSessionIDs.remove(sessionID)
        cancelFlushTimer(for: sessionID)

        writeQueue.sync {
            self.performFlush(state)
            self.closeWithFooter(state, note: nil)
        }
    }

    func stopIfSessionClosed(remainingSessionIDs: Set<TerminalSession.ID>) {
        // Snapshot first: `stop(sessionID:)` mutates `activeSessionIDs`, so
        // iterating that set directly while stopping would mutate it
        // mid-iteration.
        let staleSessionIDs = activeSessionIDs.subtracting(remainingSessionIDs)
        for sessionID in staleSessionIDs {
            stop(sessionID: sessionID)
        }
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

    // MARK: - Write-queue-confined (nonisolated)

    /// Runs on `writeQueue`. Writes the buffer, in order, and clears it. This
    /// is the only place bytes reach disk, and it is always called before
    /// `closeWithFooter` on every termination path (stop/cap/error), which
    /// is what guarantees the footer is never written ahead of buffered body
    /// bytes.
    nonisolated private func performFlush(_ state: RecordingState) {
        guard !state.isClosed, !state.buffer.isEmpty else { return }
        do {
            try state.fileHandle.write(contentsOf: state.buffer)
            state.bytesWritten += state.buffer.count
            state.buffer.removeAll(keepingCapacity: true)
        } catch {
            state.buffer.removeAll(keepingCapacity: true)
            finishDueToWriteError(state, error: error)
        }
    }

    /// Runs on `writeQueue`. Writes the footer (plus an optional note) and
    /// closes the handle. Idempotent via `isClosed`, so a late timer tick or
    /// an append that was already queued behind a cap/error close can't
    /// write to an already-closed handle.
    nonisolated private func closeWithFooter(_ state: RecordingState, note: String?) {
        guard !state.isClosed else { return }
        state.isClosed = true
        do {
            var footer = "\n\nRecording ended: \(Self.timestamp())\n"
            if let note {
                footer += note
            }
            try state.fileHandle.write(contentsOf: Data(footer.utf8))
            try state.fileHandle.synchronize()
        } catch {
            // The recording is ending regardless; nothing further to
            // usefully report here without risking recursing into another
            // error path.
        }
        try? state.fileHandle.close()
    }

    /// Runs on `writeQueue`. Cap reached mid-append: flush whatever's
    /// buffered (bypassing the normal flush threshold — the cap can be
    /// crossed by data that's still only in memory), write a footer noting
    /// why, close, then hop to the main actor to update published state.
    nonisolated private func finishDueToCap(_ state: RecordingState, capBytes: Int) {
        guard !state.isClosed else { return }
        performFlush(state)
        closeWithFooter(state, note: "Stopped automatically: recording reached the \(capBytes)-byte size limit.\n")

        let message = String(localized: "Session recording stopped because it reached the size limit.")
        Task { @MainActor [weak self] in
            self?.finishOnMainActor(state: state, errorMessage: message)
        }
    }

    /// Runs on `writeQueue`. A write failed (either the threshold flush or
    /// the periodic timer flush): close what we can and hop to the main
    /// actor to surface the error and drop the recording.
    nonisolated private func finishDueToWriteError(_ state: RecordingState, error: Error) {
        guard !state.isClosed else { return }
        let message = String(localized: "Session recording stopped because the file could not be written: \(error.localizedDescription)")
        closeWithFooter(state, note: nil)

        Task { @MainActor [weak self] in
            self?.finishOnMainActor(state: state, errorMessage: message)
        }
    }

    nonisolated private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    // MARK: - Main-actor bookkeeping

    private func startFlushTimer(for sessionID: TerminalSession.ID, state: RecordingState) {
        let timer = DispatchSource.makeTimerSource(queue: writeQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self, weak state] in
            guard let self, let state, !state.isClosed else { return }
            self.performFlush(state)
        }
        timer.resume()
        flushTimers[sessionID] = timer
    }

    private func cancelFlushTimer(for sessionID: TerminalSession.ID) {
        flushTimers.removeValue(forKey: sessionID)?.cancel()
    }

    /// Called (via a `Task { @MainActor in }` hop) after a background-thread
    /// termination — cap reached or write failure. A concurrent user-driven
    /// `stop(sessionID:)` may have already removed this session by the time
    /// the hop runs; the guard makes that a no-op instead of clobbering a
    /// newer recording that reused the same session id.
    private func finishOnMainActor(state: RecordingState, errorMessage message: String) {
        // Identity, not just presence: between the background close and this
        // hop the user may have stopped and restarted recording for the same
        // session, in which case `recordings[sessionID]` is a *different*,
        // healthy state that must not be torn down here.
        guard recordings[state.sessionID] === state else { return }
        recordings.removeValue(forKey: state.sessionID)
        activeSessionIDs.remove(state.sessionID)
        cancelFlushTimer(for: state.sessionID)
        errorMessage = message
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
}
