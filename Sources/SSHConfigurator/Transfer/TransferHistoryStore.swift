import Foundation

// MARK: - Outcome

/// Terminal outcome of a transfer, as recorded in history. Only ever written
/// once an item leaves the queue for good — waiting/active items are never
/// recorded, and a temporarily-failed item that is still auto-retrying isn't
/// either (see `TransferQueueEngine`).
enum TransferHistoryOutcome: String, Codable, Sendable {
    case completed
    case failed
    case cancelled
}

// MARK: - Record

struct TransferHistoryRecord: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let direction: SCPTransferDirection
    let alias: String
    /// Raw, unredacted local path. Redaction (for display only, see
    /// `TransferHistoryRedaction`) never touches this — "Yeniden aktar" needs the
    /// real path to rebuild a working `TransferItem`.
    let localPath: String
    /// Raw, unredacted remote path.
    let remotePath: String
    let isDirectory: Bool
    let transferProtocol: TransferProtocol
    let verifyChecksum: Bool
    let fileSize: Int64?
    let durationSeconds: Double?
    let outcome: TransferHistoryOutcome
    let failureMessage: String?
    let timestamp: Date

    init(
        id: UUID = UUID(),
        direction: SCPTransferDirection,
        alias: String,
        localPath: String,
        remotePath: String,
        isDirectory: Bool,
        transferProtocol: TransferProtocol,
        verifyChecksum: Bool,
        fileSize: Int64?,
        durationSeconds: Double?,
        outcome: TransferHistoryOutcome,
        failureMessage: String? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.direction = direction
        self.alias = alias
        self.localPath = localPath
        self.remotePath = remotePath
        self.isDirectory = isDirectory
        self.transferProtocol = transferProtocol
        self.verifyChecksum = verifyChecksum
        self.fileSize = fileSize
        self.durationSeconds = durationSeconds
        self.outcome = outcome
        self.failureMessage = failureMessage
        self.timestamp = timestamp
    }

    /// Builds a history record from a `TransferItem` that just reached a terminal
    /// state. Size is best-effort ("biliniyorsa"): for a file transfer it reads
    /// whatever currently sits at `localURL` — the source for an upload, the
    /// (possibly partial) destination for a download — and is `nil` for
    /// directories or if the path can't be stat'd (e.g. a failed download that
    /// never created a local file).
    init(item: TransferItem, outcome: TransferHistoryOutcome, failureMessage: String? = nil) {
        self.init(
            direction: item.direction,
            alias: item.alias,
            localPath: item.localURL.path,
            remotePath: item.remotePath,
            isDirectory: item.isDirectory,
            transferProtocol: item.transferProtocol,
            verifyChecksum: item.verifyChecksum,
            fileSize: Self.knownFileSize(item: item),
            durationSeconds: Self.duration(item: item),
            outcome: outcome,
            failureMessage: failureMessage
        )
    }

    private static func duration(item: TransferItem) -> Double? {
        guard let started = item.startedAt, let finished = item.finishedAt else { return nil }
        return finished.timeIntervalSince(started)
    }

    private static func knownFileSize(item: TransferItem) -> Int64? {
        guard !item.isDirectory else { return nil }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: item.localURL.path) else {
            return nil
        }
        return attributes[.size] as? Int64
    }
}

// MARK: - Retry

enum TransferHistoryRetryError: LocalizedError, Equatable {
    case missingLocalSource(path: String)

    var errorDescription: String? {
        switch self {
        case let .missingLocalSource(path):
            return "Yerel kaynak dosya artık mevcut değil: \(path)"
        }
    }
}

extension TransferHistoryRecord {
    /// Rebuilds a fresh, waiting `TransferItem` with this record's parameters, for
    /// the history list's "Yeniden aktar" action.
    ///
    /// Uploads are pre-checked: if the local source file is gone, this returns an
    /// upfront, actionable error instead of silently enqueuing a transfer that
    /// will fail with an opaque process error a moment later. Downloads can't be
    /// cheaply pre-validated — the source lives on the remote host — so they're
    /// always rebuilt and rely on the existing transfer error classification if
    /// the remote file is no longer there.
    func makeRetryItem(fileManager: FileManager = .default) -> Result<TransferItem, TransferHistoryRetryError> {
        if direction == .upload, !fileManager.fileExists(atPath: localPath) {
            return .failure(.missingLocalSource(path: localPath))
        }
        return .success(TransferItem(
            direction: direction,
            alias: alias,
            localURL: URL(fileURLWithPath: localPath),
            remotePath: remotePath,
            isDirectory: isDirectory,
            transferProtocol: transferProtocol,
            verifyChecksum: verifyChecksum
        ))
    }
}

// MARK: - Partial file cleanup targeting

extension TransferHistoryRecord {
    /// True only for cancelled/failed **file** transfers — the only cases where a
    /// stray partial file may be sitting at this transfer's own destination.
    /// Folder transfers never offer cleanup: a partial folder tree would need a
    /// recursive delete, which this app deliberately never performs (too easy to
    /// trigger by accident on a remote host, or wipe more than intended locally).
    var offersPartialFileCleanup: Bool {
        guard !isDirectory else { return false }
        switch outcome {
        case .cancelled, .failed: return true
        case .completed: return false
        }
    }

    /// The transfer's own destination: local for a download, remote for an
    /// upload. Partial-file cleanup only ever targets this path — never the
    /// source side.
    var partialFileTarget: (isRemote: Bool, path: String) {
        direction == .download ? (false, localPath) : (true, remotePath)
    }
}

// MARK: - Redaction (display-only)

/// Masks paths for on-screen display when the user turns on "geçmişte yolları
/// maskele". This never touches what's written to `transfer-history.json` —
/// only the strings handed to SwiftUI `Text` — because "Yeniden aktar" needs
/// the real path to rebuild a working transfer.
enum TransferHistoryRedaction {
    static func redact(
        _ path: String,
        homeDirectory: String = NSHomeDirectory(),
        userName: String = NSUserName()
    ) -> String {
        var result = path
        if !homeDirectory.isEmpty, result.hasPrefix(homeDirectory) {
            result = "~" + result.dropFirst(homeDirectory.count)
        }
        guard !userName.isEmpty else { return result }
        let maskedComponents = result.split(separator: "/", omittingEmptySubsequences: false).map {
            component -> Substring in
            component == Substring(userName) ? "•••" : component
        }
        return maskedComponents.joined(separator: "/")
    }
}

// MARK: - Persistence

struct TransferHistoryState: Codable, Equatable, Sendable {
    var records: [TransferHistoryRecord] = []
}

protocol TransferHistoryPersisting {
    func load() throws -> TransferHistoryState
    func save(_ state: TransferHistoryState) throws
}

struct TransferHistoryStore: TransferHistoryPersisting {
    let fileURL: URL

    init(fileURL: URL = Self.defaultFileURL) {
        self.fileURL = fileURL
    }

    func load() throws -> TransferHistoryState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return TransferHistoryState()
        }
        return try JSONDecoder().decode(TransferHistoryState.self, from: Data(contentsOf: fileURL))
    }

    func save(_ state: TransferHistoryState) throws {
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: directory.path
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: fileURL.path
        )
    }

    static var defaultFileURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        return applicationSupport
            .appendingPathComponent("Terly", isDirectory: true)
            .appendingPathComponent("transfer-history.json", isDirectory: false)
    }
}

// MARK: - Library

@MainActor
final class TransferHistoryLibrary: ObservableObject {
    /// Oldest records are dropped once the list exceeds this many entries.
    static let maxRecords = 200

    /// Newest first.
    @Published private(set) var records: [TransferHistoryRecord] = []
    @Published private(set) var errorMessage: String?

    private let store: any TransferHistoryPersisting

    init(store: any TransferHistoryPersisting = TransferHistoryStore()) {
        self.store = store
    }

    func load() {
        do {
            records = try store.load().records
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Appends a record for an item that just reached a terminal state. Called
    /// only by `TransferQueueEngine`, exactly once per item, the moment it
    /// becomes `.succeeded`, permanently `.failed`, or `.cancelled`.
    func recordTerminal(_ record: TransferHistoryRecord) {
        var updated = records
        updated.insert(record, at: 0)
        if updated.count > Self.maxRecords {
            updated.removeLast(updated.count - Self.maxRecords)
        }
        persist(updated)
    }

    func clear() {
        persist([])
    }

    private func persist(_ updated: [TransferHistoryRecord]) {
        do {
            try store.save(TransferHistoryState(records: updated))
            records = updated
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
