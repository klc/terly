import Foundation

// MARK: - Protocol

enum TransferProtocol: String, CaseIterable, Identifiable, Codable, Sendable {
    case scp
    case sftp

    var id: String { rawValue }

    var label: String {
        switch self {
        case .scp: return "SCP"
        case .sftp: return "SFTP"
        }
    }

    /// SFTP requires the sftp-server subsystem to be enabled on the remote host.
    var requiresSubsystem: Bool { self == .sftp }
}

// MARK: - Item state

enum TransferItemState: Equatable, Sendable {
    case waiting
    case active
    case succeeded
    case failed(String)
    case cancelled
}

// MARK: - Checksum verification

/// Result of an optional post-transfer SHA-256 comparison. Only computed for
/// single-file transfers that opted in; folder transfers never populate this.
enum ChecksumVerificationState: Equatable, Sendable {
    case verifying
    case verified
    case mismatch
    /// Neutral, non-error outcome — e.g. neither `shasum` nor `sha256sum`
    /// exists on the remote host, or the digest couldn't be computed.
    case unavailable(reason: String?)
}

// MARK: - Item

struct TransferItem: Identifiable, Sendable {
    let id: UUID
    let direction: SCPTransferDirection
    let alias: String
    let localURL: URL
    let remotePath: String
    /// True when the local URL (upload) or the remote path (download) is a directory.
    let isDirectory: Bool
    let transferProtocol: TransferProtocol
    /// Whether a SHA-256 comparison should run once the transfer succeeds.
    /// Ignored for directories — folder transfers never verify checksums.
    let verifyChecksum: Bool

    private(set) var state: TransferItemState = .waiting
    private(set) var progress: Double?
    private(set) var transferRate: String?
    private(set) var estimatedTimeRemaining: String?
    private(set) var transferredBytes: Int64 = 0
    private(set) var fileSize: Int64?
    private(set) var startedAt: Date?
    private(set) var finishedAt: Date?
    private(set) var retryCount: Int = 0
    private(set) var checksumState: ChecksumVerificationState?

    init(
        id: UUID = UUID(),
        direction: SCPTransferDirection,
        alias: String,
        localURL: URL,
        remotePath: String,
        isDirectory: Bool,
        transferProtocol: TransferProtocol,
        verifyChecksum: Bool = false
    ) {
        self.id = id
        self.direction = direction
        self.alias = alias
        self.localURL = localURL
        self.remotePath = remotePath
        self.isDirectory = isDirectory
        self.transferProtocol = transferProtocol
        self.verifyChecksum = verifyChecksum
    }

    // MARK: Derived

    var displayName: String { localURL.lastPathComponent }

    var isTerminal: Bool {
        switch state {
        case .succeeded, .failed, .cancelled: return true
        case .waiting, .active: return false
        }
    }

    var stateLabel: String {
        switch state {
        case .waiting: return String(localized: "Waiting")
        case .active: return String(localized: "Transferring")
        case .succeeded: return String(localized: "Completed")
        case .failed: return String(localized: "Failed")
        case .cancelled: return String(localized: "Cancelled")
        }
    }

    // MARK: Mutating helpers (called by TransferQueueEngine on @MainActor)

    mutating func markActive() {
        state = .active
        startedAt = Date()
        progress = nil
        transferRate = nil
        estimatedTimeRemaining = nil
    }

    mutating func updateProgress(fraction: Double, rate: String?, etaSeconds: TimeInterval?) {
        progress = min(max(fraction, 0), 1)
        transferRate = rate
        if let eta = etaSeconds {
            estimatedTimeRemaining = formatETA(eta)
        }
    }

    mutating func markSucceeded() {
        state = .succeeded
        progress = 1
        transferRate = nil
        estimatedTimeRemaining = nil
        finishedAt = Date()
    }

    mutating func markFailed(_ message: String) {
        state = .failed(message)
        progress = nil
        transferRate = nil
        estimatedTimeRemaining = nil
        finishedAt = Date()
    }

    mutating func markCancelled() {
        state = .cancelled
        progress = nil
        transferRate = nil
        estimatedTimeRemaining = nil
        finishedAt = Date()
    }

    mutating func incrementRetryCount() {
        retryCount += 1
    }

    mutating func updateChecksumState(_ state: ChecksumVerificationState?) {
        checksumState = state
    }

    mutating func resetForRetry() {
        state = .waiting
        progress = nil
        transferRate = nil
        estimatedTimeRemaining = nil
        startedAt = nil
        finishedAt = nil
    }

    private func formatETA(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        let total = Int(seconds.rounded())
        if total < 60 { return String(localized: "\(total)s remaining") }
        let minutes = total / 60
        let secs = total % 60
        return String(localized: "\(minutes)m \(secs)s remaining")
    }
}

// MARK: - Queue

@MainActor
final class TransferQueue: ObservableObject {
    @Published private(set) var items: [TransferItem] = []

    /// Maximum number of items that may be in `.active` state simultaneously. Range: 1–5.
    @Published var concurrencyLimit: Int = 3

    var activeCount: Int { items.filter { $0.state == .active }.count }
    var waitingCount: Int { items.filter { $0.state == .waiting }.count }

    var totalProgress: Double? {
        let active = items.filter { $0.state == .active || $0.state == .succeeded }
        guard !active.isEmpty else { return nil }
        let sum = active.compactMap(\.progress).reduce(0, +)
        return sum / Double(active.count)
    }

    var hasActiveOrPending: Bool {
        items.contains { $0.state == .active || $0.state == .waiting }
    }

    // MARK: Mutations

    func enqueue(_ item: TransferItem) {
        items.append(item)
    }

    func enqueue(contentsOf newItems: [TransferItem]) {
        items.append(contentsOf: newItems)
    }

    func update(_ item: TransferItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = item
    }

    func nextWaitingItem(excluding excludedItemIDs: Set<UUID> = []) -> TransferItem? {
        items.first { $0.state == .waiting && !excludedItemIDs.contains($0.id) }
    }

    func clearTerminated() {
        items.removeAll { $0.isTerminal }
    }
}

// MARK: - Progress update (sent from background)

struct TransferProgressUpdate: Sendable {
    let itemID: UUID
    let fraction: Double
    let rate: String?
    let etaSeconds: TimeInterval?
}
