import Combine
import Foundation

/// Records each pane's terminal output for one or more sessions as
/// asciinema cast v2 files (https://docs.asciinema.org/manual/asciicast/v2/)
/// — one `.cast` file per pane, inside one folder per recording.
///
/// Concurrency shape: all *decisions* (start/stop/is-recording/error surface)
/// live on `@MainActor`, matching the rest of the SwiftUI layer this is
/// driven from. Actual file I/O never happens on the main thread — it's
/// buffered and flushed on a single serial `writeQueue`. A serial queue (not
/// a Swift `actor`) is required because `stop(sessionID:)` is called from
/// synchronous `@MainActor` SwiftUI closures (`toggleRecording`, the
/// `onChange` session-closed handler) and must stay synchronous/non-async so
/// those call sites can rely on every pane's file being fully written the
/// moment `stop` returns — an `actor` would force `stop` to become `async`.
///
/// `RecordingState` holds the mutable write-side state for one recording
/// (folder), including a `PaneRecordingState` per pane opened so far. Neither
/// class is part of this `@MainActor` class: every mutable field on them is
/// only ever touched from a closure running on `writeQueue`, which is the
/// actual synchronization mechanism — `@unchecked Sendable` is the
/// documented escape hatch for "confined to one queue," not "confined to one
/// actor."
@MainActor
final class TerminalSessionRecorder: ObservableObject {
    @Published private(set) var activeSessionIDs: Set<TerminalSession.ID> = []
    @Published private(set) var errorMessage: String?

    /// Per-recording byte cap (summed across every pane's file) before it's
    /// stopped automatically. A `var` (not a fixed constant) so tests can
    /// dial it down instead of writing 100 MB of fixture data; production
    /// code never needs to change it.
    var sizeCapBytes: Int = 100 * 1024 * 1024

    /// Bytes buffered in memory (per pane) before an append forces a flush
    /// to disk, so a chatty session doesn't dispatch one write per tiny
    /// output chunk.
    private nonisolated static let flushThresholdBytes = 64 * 1024

    /// Write-side state for a single pane's `.cast` file.
    private final class PaneRecordingState: @unchecked Sendable {
        let paneID: TerminalPane.ID
        let fileHandle: FileHandle
        let fileURL: URL
        /// Wall-clock time the file was opened; every event's elapsed time
        /// is measured relative to this, per the cast v2 event format.
        let openedAt: Date
        var buffer = Data()
        var bytesWritten = 0
        var isClosed = false
        /// Bytes held back from the previous `append` because they were the
        /// start of a multi-byte UTF-8 sequence that hadn't fully arrived
        /// yet. Prepended to the next chunk before decoding.
        var utf8Carry: [UInt8] = []

        init(paneID: TerminalPane.ID, fileHandle: FileHandle, fileURL: URL, openedAt: Date) {
            self.paneID = paneID
            self.fileHandle = fileHandle
            self.fileURL = fileURL
            self.openedAt = openedAt
        }
    }

    /// Write-side state for one recording (one folder, any number of panes).
    private final class RecordingState: @unchecked Sendable {
        let sessionID: TerminalSession.ID
        let sessionTitle: String
        let folderURL: URL
        var panes: [TerminalPane.ID: PaneRecordingState] = [:]
        /// Sanitized alias -> next 1-based index to assign, so two panes
        /// sharing an alias (e.g. after a split) get `alias-1.cast` and
        /// `alias-2.cast` instead of colliding.
        var aliasCounts: [String: Int] = [:]
        var isClosed = false

        init(sessionID: TerminalSession.ID, sessionTitle: String, folderURL: URL) {
            self.sessionID = sessionID
            self.sessionTitle = sessionTitle
            self.folderURL = folderURL
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

    /// The folder this recording's `.cast` files live in.
    func fileURL(for sessionID: TerminalSession.ID) -> URL? {
        recordings[sessionID]?.folderURL
    }

    @discardableResult
    func start(session: TerminalSession, folderURL: URL) -> Bool {
        errorMessage = nil
        stop(sessionID: session.id)

        do {
            try Self.prepareFolder(at: folderURL)
        } catch {
            errorMessage = String(localized: "Session recording could not be started: \(error.localizedDescription)")
            return false
        }

        let state = RecordingState(sessionID: session.id, sessionTitle: session.displayTitle, folderURL: folderURL)
        recordings[session.id] = state
        activeSessionIDs.insert(session.id)
        startFlushTimer(for: session.id, state: state)
        return true
    }

    /// Appends one output chunk for one pane. Panes are created lazily: the
    /// pane's `.cast` file (and its header line) is opened the first time
    /// output actually arrives for it, not upfront — a session's pane set
    /// changes as the user splits panes mid-recording.
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

            let paneState: PaneRecordingState
            if let existing = state.panes[paneID] {
                paneState = existing
            } else {
                do {
                    paneState = try self.openPane(paneID: paneID, alias: alias, state: state)
                } catch {
                    self.finishDueToWriteError(state, error: error)
                    return
                }
            }
            guard !paneState.isClosed else { return }

            // UTF-8 sequences arrive as arbitrary byte chunks straight off
            // the PTY and can be cut in half at a chunk boundary (e.g. a
            // Turkish "ğ" or an emoji). Prepend whatever was held back last
            // time, decode as much as is complete, and carry the rest.
            var pending = paneState.utf8Carry
            pending.append(contentsOf: bytes)
            let (complete, carry) = Self.splitTrailingIncompleteUTF8(pending)
            paneState.utf8Carry = Array(carry)

            if !complete.isEmpty {
                let text = String(decoding: complete, as: UTF8.self)
                self.appendEvent(text, to: paneState)
            }

            let totalAccepted = self.totalAcceptedBytes(state)
            if totalAccepted >= cap {
                self.finishDueToCap(state, capBytes: cap)
            } else if paneState.buffer.count >= Self.flushThresholdBytes {
                self.flushPane(paneState, in: state)
            }
        }
    }

    /// Stops the recording for one session. Synchronous by design: by the
    /// time this returns, every pane's buffered bytes have been flushed and
    /// every pane's file handle has been closed — no polling required to
    /// observe complete files afterward.
    func stop(sessionID: TerminalSession.ID) {
        guard let state = recordings.removeValue(forKey: sessionID) else { return }
        activeSessionIDs.remove(sessionID)
        cancelFlushTimer(for: sessionID)

        writeQueue.sync {
            self.flushAllPanes(state)
            self.closeAllPanes(state)
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

    /// Suggested name for the folder a new recording is saved into, e.g.
    /// `Terly-Production-2026-07-20-153000`. No extension: the recording is
    /// a directory, not a file.
    nonisolated static func suggestedFolderName(for sessionTitle: String, date: Date = Date()) -> String {
        let collapsedTitle = sanitizedComponent(sessionTitle)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let title = collapsedTitle.isEmpty ? "session" : collapsedTitle
        return "Terly-\(title)-\(formatter.string(from: date))"
    }

    /// Strips everything but letters/numbers/`-`/`_`, collapsing the rest to
    /// single hyphens. Shared by folder names (from the session title) and
    /// per-pane `.cast` file names (from the pane's alias) so both sanitize
    /// identically.
    nonisolated private static func sanitizedComponent(_ raw: String) -> String {
        let safe = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .map { character -> Character in
                character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-"
            }
        return String(safe)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
    }

    // MARK: - Write-queue-confined (nonisolated)

    /// Runs on `writeQueue`. Opens the `.cast` file for a pane the first
    /// time output arrives for it: picks a collision-free `alias-N.cast`
    /// name, creates the file with owner-only permissions, and writes the
    /// cast v2 header as line 1.
    nonisolated private func openPane(
        paneID: TerminalPane.ID,
        alias: String,
        state: RecordingState
    ) throws -> PaneRecordingState {
        let safeAlias = Self.sanitizedComponent(alias)
        let base = safeAlias.isEmpty ? "pane" : safeAlias
        let index = (state.aliasCounts[base] ?? 0) + 1
        state.aliasCounts[base] = index

        let fileURL = state.folderURL.appendingPathComponent("\(base)-\(index).cast")
        let handle = try Self.prepareFile(at: fileURL)
        let openedAt = Date()

        // `TerminalPane` carries no cols/rows and the recorder has no access
        // to the SwiftTerm view, so width/height are hardcoded to a common
        // default. Players tolerate this because the stream's own resize
        // escape sequences drive the actual displayed geometry.
        let header: [String: Any] = [
            "version": 2,
            "width": 80,
            "height": 24,
            "timestamp": Int(openedAt.timeIntervalSince1970),
            "title": "\(state.sessionTitle) — \(alias)",
        ]
        let headerData = try JSONSerialization.data(withJSONObject: header, options: [])
        try handle.write(contentsOf: headerData)
        try handle.write(contentsOf: Data("\n".utf8))

        let paneState = PaneRecordingState(paneID: paneID, fileHandle: handle, fileURL: fileURL, openedAt: openedAt)
        state.panes[paneID] = paneState
        return paneState
    }

    /// Runs on `writeQueue`. Encodes one `"o"` (output) event through
    /// `JSONSerialization` — never hand-rolled string escaping, since
    /// terminal output is full of ESC bytes, control characters, quotes,
    /// and backslashes that only a real JSON encoder escapes correctly —
    /// and appends the line (plus newline) to the pane's buffer.
    nonisolated private func appendEvent(_ text: String, to paneState: PaneRecordingState) {
        let elapsed = Date().timeIntervalSince(paneState.openedAt)
        let event: [Any] = [elapsed, "o", text]
        guard var data = try? JSONSerialization.data(withJSONObject: event, options: []) else {
            // A String/Double/String array should never fail to encode; if
            // it somehow does, drop this event rather than corrupt the
            // stream or block the recording.
            return
        }
        data.append(0x0A)
        paneState.buffer.append(data)
    }

    /// Runs on `writeQueue`. Flushes one pane's buffer to disk. A write
    /// failure ends the whole recording (all panes), matching the cap/error
    /// handling that already existed for the single-file design.
    nonisolated private func flushPane(_ paneState: PaneRecordingState, in state: RecordingState) {
        guard !paneState.isClosed, !paneState.buffer.isEmpty else { return }
        do {
            try paneState.fileHandle.write(contentsOf: paneState.buffer)
            paneState.bytesWritten += paneState.buffer.count
            paneState.buffer.removeAll(keepingCapacity: true)
        } catch {
            paneState.buffer.removeAll(keepingCapacity: true)
            finishDueToWriteError(state, error: error)
        }
    }

    /// Runs on `writeQueue`. Flushes every pane of a recording, in a stable
    /// order, bailing out early if a mid-loop failure already closed the
    /// whole recording.
    nonisolated private func flushAllPanes(_ state: RecordingState) {
        for paneState in state.panes.values {
            guard !state.isClosed else { return }
            flushPane(paneState, in: state)
        }
    }

    /// Runs on `writeQueue`. Closes one pane's file: any incomplete UTF-8
    /// bytes left over from a chunk boundary are flushed now, using Unicode
    /// replacement (U+FFFD) rather than being silently dropped, then the
    /// buffer is written and the handle synchronized and closed. Idempotent
    /// via `isClosed`.
    nonisolated private func closePane(_ paneState: PaneRecordingState) {
        guard !paneState.isClosed else { return }

        if !paneState.utf8Carry.isEmpty {
            let replaced = String(decoding: paneState.utf8Carry, as: UTF8.self)
            paneState.utf8Carry.removeAll()
            if !replaced.isEmpty {
                appendEvent(replaced, to: paneState)
            }
        }

        if !paneState.buffer.isEmpty {
            try? paneState.fileHandle.write(contentsOf: paneState.buffer)
            paneState.buffer.removeAll(keepingCapacity: true)
        }

        paneState.isClosed = true
        try? paneState.fileHandle.synchronize()
        try? paneState.fileHandle.close()
    }

    /// Runs on `writeQueue`. Closes every pane of a recording. Idempotent
    /// via `state.isClosed`, so a late timer tick or an append already
    /// queued behind a cap/error close can't reopen or write to an
    /// already-closed recording.
    nonisolated private func closeAllPanes(_ state: RecordingState) {
        guard !state.isClosed else { return }
        state.isClosed = true
        for paneState in state.panes.values {
            closePane(paneState)
        }
    }

    /// Runs on `writeQueue`. Total *accepted* bytes (flushed + still
    /// buffered) across every pane, not just flushed bytes — data sitting
    /// in a buffer already counts against the cap, so a cap smaller than
    /// the flush threshold (as tests use) is still enforced immediately.
    nonisolated private func totalAcceptedBytes(_ state: RecordingState) -> Int {
        state.panes.values.reduce(0) { $0 + $1.bytesWritten + $1.buffer.count }
    }

    /// Runs on `writeQueue`. Cap reached mid-append: flush and close every
    /// pane, then hop to the main actor to update published state.
    nonisolated private func finishDueToCap(_ state: RecordingState, capBytes: Int) {
        guard !state.isClosed else { return }
        flushAllPanes(state)
        closeAllPanes(state)

        let message = String(localized: "Session recording stopped because it reached the size limit.")
        Task { @MainActor [weak self] in
            self?.finishOnMainActor(state: state, errorMessage: message)
        }
    }

    /// Runs on `writeQueue`. A write failed for some pane: close every pane
    /// of the recording and hop to the main actor to surface the error and
    /// drop the recording.
    nonisolated private func finishDueToWriteError(_ state: RecordingState, error: Error) {
        guard !state.isClosed else { return }
        let message = String(localized: "Session recording stopped because the file could not be written: \(error.localizedDescription)")
        closeAllPanes(state)

        Task { @MainActor [weak self] in
            self?.finishOnMainActor(state: state, errorMessage: message)
        }
    }

    /// Finds the end of the buffer's trailing (possibly incomplete)
    /// multi-byte UTF-8 sequence and splits it off as `carry`. Scans
    /// backward over continuation bytes (`10xxxxxx`) to find the sequence's
    /// lead byte, then compares how many bytes that lead byte declares
    /// against how many are actually present in the buffer.
    nonisolated private static func splitTrailingIncompleteUTF8(
        _ bytes: [UInt8]
    ) -> (complete: ArraySlice<UInt8>, carry: ArraySlice<UInt8>) {
        guard !bytes.isEmpty else { return (bytes[...], bytes[bytes.endIndex...]) }

        let maxLookback = min(4, bytes.count)
        for lookback in 1...maxLookback {
            let leadIndex = bytes.count - lookback
            let byte = bytes[leadIndex]
            let isContinuation = (byte & 0b1100_0000) == 0b1000_0000
            if isContinuation {
                continue
            }

            let expectedLength: Int
            if byte & 0b1000_0000 == 0 {
                expectedLength = 1
            } else if byte & 0b1110_0000 == 0b1100_0000 {
                expectedLength = 2
            } else if byte & 0b1111_0000 == 0b1110_0000 {
                expectedLength = 3
            } else if byte & 0b1111_1000 == 0b1111_0000 {
                expectedLength = 4
            } else {
                // Not a valid UTF-8 lead byte at all; nothing to carry.
                expectedLength = 1
            }

            if expectedLength > lookback {
                // The sequence starting at `leadIndex` needs more
                // continuation bytes than are present — hold it back.
                return (bytes[0..<leadIndex], bytes[leadIndex...])
            }
            return (bytes[0...], bytes[bytes.endIndex...])
        }

        // More than `maxLookback` continuation bytes in a row with no lead
        // byte found: not a valid UTF-8 tail in any case, so there is
        // nothing sensible to carry — let lossy decoding replace it.
        return (bytes[0...], bytes[bytes.endIndex...])
    }

    // MARK: - Main-actor bookkeeping

    private func startFlushTimer(for sessionID: TerminalSession.ID, state: RecordingState) {
        let timer = DispatchSource.makeTimerSource(queue: writeQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self, weak state] in
            guard let self, let state, !state.isClosed else { return }
            self.flushAllPanes(state)
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

    /// Creates the recording folder (owner-only, `0700`) if it doesn't
    /// already exist, or corrects its permissions if it does — mirroring
    /// `prepareFile`'s dual-mode handling for per-pane files below.
    nonisolated private static func prepareFolder(at folderURL: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: folderURL.path) {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folderURL.path)
        } else {
            try fileManager.createDirectory(
                at: folderURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    nonisolated private static func prepareFile(at fileURL: URL) throws -> FileHandle {
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
