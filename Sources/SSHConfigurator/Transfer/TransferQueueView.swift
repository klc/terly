import SwiftUI

/// Shows all items currently in the transfer queue.
/// Active items show a progress bar; terminal items show status + optional retry.
struct TransferQueueView: View {
    @ObservedObject var queue: TransferQueue
    let engine: TransferQueueEngine

    private enum Tab { case queue, history }
    @State private var selectedTab: Tab = .queue

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            switch selectedTab {
            case .queue:
                if queue.items.isEmpty {
                    emptyState
                } else {
                    itemList
                }
            case .history:
                TransferHistoryView(
                    historyLibrary: engine.historyLibrary,
                    engine: engine,
                    onRetryEnqueued: { selectedTab = .queue }
                )
            }
        }
        .frame(minWidth: 520, minHeight: 340)
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Transfer queue")
                    .font(.headline)
                if selectedTab == .queue {
                    Text(headerSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()

            Picker("Tab", selection: $selectedTab) {
                Text("Queue").tag(Tab.queue)
                Text(historyTabLabel).tag(Tab.history)
            }
            .pickerStyle(.segmented)
            .fixedSize()

            if selectedTab == .queue {
                if queue.hasActiveOrPending {
                    if let total = queue.totalProgress {
                        ProgressView(value: total, total: 1)
                            .frame(width: 90)
                    }
                    Button("Cancel all", role: .destructive) {
                        engine.cancelAll()
                    }
                    .controlSize(.small)
                } else {
                    Button("Clear list") {
                        engine.clearFinished()
                    }
                    .controlSize(.small)
                    .disabled(queue.items.isEmpty)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var historyTabLabel: String {
        let count = engine.historyLibrary.records.count
        return count == 0 ? String(localized: "History") : String(localized: "History (\(count))")
    }

    private var headerSubtitle: String {
        let active = queue.activeCount
        let waiting = queue.waitingCount
        let total = queue.items.count
        if total == 0 { return String(localized: "Queue is empty") }
        // TODO(plural)
        if active == 0 && waiting == 0 { return String(localized: "\(total) transfers completed") }
        var parts: [String] = []
        // TODO(plural)
        if active > 0 { parts.append(String(localized: "\(active) transferring")) }
        // TODO(plural)
        if waiting > 0 { parts.append(String(localized: "\(waiting) waiting")) }
        return parts.joined(separator: ", ")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("No transfers in queue")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var itemList: some View {
        List(queue.items) { item in
            TransferItemRow(item: item, engine: engine)
                .listRowSeparator(.visible)
        }
        .listStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: queue.items.map(\.id))
    }
}

// MARK: - Row

private struct TransferItemRow: View {
    let item: TransferItem
    let engine: TransferQueueEngine

    var body: some View {
        HStack(spacing: 10) {
            // Direction + type icon
            Image(systemName: iconName)
                .font(.title3)
                .foregroundStyle(iconColor)
                .frame(width: 28)

            // Name + path + progress
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.displayName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    stateLabel
                }

                Text(item.localURL.deletingLastPathComponent().path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if item.state == .active {
                    progressRow
                }
            }

            // Action buttons
            actions
        }
        .padding(.vertical, 4)
    }

    private var iconName: String {
        let isDir = item.isDirectory
        switch item.direction {
        case .upload: return isDir ? "folder.fill.badge.plus" : "arrow.up.doc.fill"
        case .download: return isDir ? "folder.badge.arrow.down" : "arrow.down.doc.fill"
        }
    }

    private var iconColor: Color {
        switch item.state {
        case .waiting: return .secondary
        case .active: return .accentColor
        case .succeeded: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }

    @ViewBuilder
    private var stateLabel: some View {
        switch item.state {
        case .waiting:
            Text("Waiting")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .active:
            HStack(spacing: 4) {
                if let rate = item.transferRate {
                    Text(rate)
                        .font(.caption.monospacedDigit())
                }
                if let eta = item.estimatedTimeRemaining, !eta.isEmpty {
                    Text("· \(eta)")
                        .font(.caption)
                }
            }
            .foregroundStyle(.secondary)
        case .succeeded:
            HStack(spacing: 6) {
                Label("Completed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if let checksumState = item.checksumState {
                    ChecksumStatusLabel(state: checksumState)
                }
            }
            .font(.caption)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
                .help(message)
        case .cancelled:
            Text("Cancelled")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var progressRow: some View {
        if let progress = item.progress {
            ProgressView(value: progress, total: 1)
        } else {
            ProgressView()
                .controlSize(.mini)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch item.state {
        case .active, .waiting:
            Button(role: .destructive) {
                engine.cancel(itemID: item.id)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .help("Cancel transfer")
            .accessibilityLabel("Cancel \(item.displayName) transfer")
        case .failed, .cancelled:
            Button {
                engine.retry(itemID: item.id)
            } label: {
                Image(systemName: "arrow.clockwise.circle")
            }
            .buttonStyle(.borderless)
            .help("Retry")
            .accessibilityLabel("Retry \(item.displayName) transfer")
        case .succeeded:
            EmptyView()
        }
    }
}

// MARK: - Checksum status badge (shared by TransferQueueView and SCPTransferSheet)

/// Shows the outcome of an optional post-transfer checksum comparison:
/// verified (✓), mismatch (✗, styled as an error), or unavailable (neutral —
/// e.g. the remote host has neither `shasum` nor `sha256sum`).
struct ChecksumStatusLabel: View {
    let state: ChecksumVerificationState

    var body: some View {
        switch state {
        case .verifying:
            Label("Verifying checksum", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
        case .verified:
            Label("Checksum verified", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        case .mismatch:
            Label("Checksum mismatch", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case let .unavailable(reason):
            Label("Checksum could not be verified", systemImage: "questionmark.circle")
                .foregroundStyle(.secondary)
                .help(reason ?? "")
        }
    }
}
