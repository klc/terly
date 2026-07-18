import SwiftUI

/// Shared "Geçmiş" tab content for both `TransferQueueView` (the standalone queue
/// view) and `SCPTransferSheet` (the per-host transfer sheet). Lists every past
/// transfer that reached a terminal state (completed/failed/cancelled — waiting
/// and active items never appear here), offers "Yeniden aktar" and, for
/// cancelled/failed single-file transfers, "Kısmi dosyayı sil…".
struct TransferHistoryView: View {
    @ObservedObject var historyLibrary: TransferHistoryLibrary
    let engine: TransferQueueEngine
    /// Called after a record was successfully re-enqueued, so the caller can
    /// e.g. switch back to the live queue tab. No-op by default.
    var onRetryEnqueued: () -> Void = {}

    /// Display-only path redaction. Never touches what's persisted to
    /// `transfer-history.json` or the parameters used for "Yeniden aktar" —
    /// only what's rendered in `Text`.
    @AppStorage("transfer.redactHistoryPaths") private var redactPaths = false
    @State private var showingClearConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if historyLibrary.records.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .onAppear {
            if historyLibrary.records.isEmpty {
                historyLibrary.load()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Toggle("Yolları maskele", isOn: $redactPaths)
                .toggleStyle(.checkbox)
                .help("Bu listede ana dizini \"~\" ile kısaltır ve kullanıcı adını gizler. Yalnızca görünümü etkiler; \"Yeniden aktar\" gerçek yolu kullanmaya devam eder.")
            Spacer()
            Button("Geçmişi Temizle", role: .destructive) {
                showingClearConfirmation = true
            }
            .controlSize(.small)
            .disabled(historyLibrary.records.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .confirmationDialog(
            "Aktarım geçmişi temizlensin mi?",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Geçmişi Temizle", role: .destructive) {
                historyLibrary.clear()
            }
        } message: {
            Text("Bu yalnızca geçmiş kaydını siler; aktarılan veya kısmi kalan dosyalara dokunulmaz.")
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "Aktarım geçmişi boş",
            systemImage: "clock.arrow.circlepath"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List(historyLibrary.records) { record in
            TransferHistoryRow(record: record, redactPaths: redactPaths, onRetry: retry)
                .listRowSeparator(.visible)
        }
        .listStyle(.plain)
    }

    private func retry(_ record: TransferHistoryRecord) -> Result<Void, TransferHistoryRetryError> {
        switch record.makeRetryItem() {
        case let .success(item):
            engine.enqueue([item])
            onRetryEnqueued()
            return .success(())
        case let .failure(error):
            return .failure(error)
        }
    }
}

// MARK: - Row

private struct TransferHistoryRow: View {
    let record: TransferHistoryRecord
    let redactPaths: Bool
    let onRetry: (TransferHistoryRecord) -> Result<Void, TransferHistoryRetryError>

    @State private var retryErrorMessage: String?
    @State private var showingDeleteConfirmation = false
    @State private var isDeletingPartialFile = false
    @State private var partialFileDeleteError: String?
    @State private var partialFileDeleted = false

    private let fileDeletionService = SFTPDirectoryListingService()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: iconName)
                    .font(.title3)
                    .foregroundStyle(iconColor)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(record.alias)
                            .font(.callout.weight(.medium))
                        Spacer()
                        outcomeLabel
                    }

                    Text("Yerel: \(displayPath(record.localPath))")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("Uzak: \(displayPath(record.remotePath))")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 8) {
                        Text(record.timestamp, format: .dateTime.day().month().year().hour().minute())
                        if let size = record.fileSize {
                            Text("· " + ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        }
                        if let duration = record.durationSeconds,
                           let formatted = Self.durationFormatter.string(from: duration) {
                            Text("· \(formatted)")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                    if record.outcome == .failed, let message = record.failureMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 0)

                Button("Yeniden aktar") {
                    retryErrorMessage = nil
                    if case let .failure(error) = onRetry(record) {
                        retryErrorMessage = error.errorDescription
                    }
                }
                .controlSize(.small)
            }

            if let retryErrorMessage {
                Label(retryErrorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            partialFileSection
        }
        .padding(.vertical, 4)
    }

    // MARK: - Partial file cleanup

    @ViewBuilder
    private var partialFileSection: some View {
        if record.isDirectory, record.outcome != .completed {
            Text(
                "Klasör aktarımı \(record.outcome == .cancelled ? "iptal edildi" : "başarısız oldu"); " +
                "hedefte kalan kısmi dosyalar elle temizlenmeli (bu uygulama klasörleri özyinelemeli silmez)."
            )
            .font(.caption)
            .foregroundStyle(.orange)
        } else if record.offersPartialFileCleanup {
            if partialFileDeleted {
                Label("Kısmi dosya silindi", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        if isDeletingPartialFile {
                            ProgressView().controlSize(.mini)
                        } else {
                            Text("Kısmi dosyayı sil…")
                        }
                    }
                    .controlSize(.small)
                    .disabled(isDeletingPartialFile)

                    if let partialFileDeleteError {
                        Label(partialFileDeleteError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .confirmationDialog(
                    "Kısmi dosya silinsin mi?",
                    isPresented: $showingDeleteConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Sil", role: .destructive) { deletePartialFile() }
                } message: {
                    Text(partialFileConfirmationMessage)
                }
            }
        }
    }

    private var partialFileConfirmationMessage: String {
        let target = record.partialFileTarget
        let location = target.isRemote ? "\(record.alias) üzerinde uzak" : "Yerel"
        return "\(location) dosya kalıcı olarak silinecek:\n\(target.path)"
    }

    private func deletePartialFile() {
        let target = record.partialFileTarget
        isDeletingPartialFile = true
        partialFileDeleteError = nil
        Task {
            do {
                if target.isRemote {
                    try await fileDeletionService.delete(alias: record.alias, path: target.path, kind: .file)
                } else {
                    try FileManager.default.removeItem(atPath: target.path)
                }
                isDeletingPartialFile = false
                partialFileDeleted = true
            } catch {
                isDeletingPartialFile = false
                partialFileDeleteError = error.localizedDescription
            }
        }
    }

    // MARK: - Display helpers

    private func displayPath(_ path: String) -> String {
        redactPaths ? TransferHistoryRedaction.redact(path) : path
    }

    private var iconName: String {
        switch record.direction {
        case .upload: return record.isDirectory ? "folder.fill.badge.plus" : "arrow.up.doc.fill"
        case .download: return record.isDirectory ? "folder.badge.arrow.down" : "arrow.down.doc.fill"
        }
    }

    private var iconColor: Color {
        switch record.outcome {
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }

    private var outcomeLabel: some View {
        let (text, icon, color): (String, String, Color) = {
            switch record.outcome {
            case .completed: return ("Tamamlandı", "checkmark.circle.fill", .green)
            case .failed: return ("Başarısız", "exclamationmark.circle.fill", .red)
            case .cancelled: return ("İptal edildi", "xmark.circle", .secondary)
            }
        }()
        return Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(color)
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()
}
