import Combine
import Foundation

enum SyncStatus: Equatable {
    case idle
    case pendingCommit
    case syncing
    case pendingApply
    case diverged
    case error(String)
}

/// Drives WP10's git sync from the UI: debounces local commits after a
/// change, exposes manual push/pull, and surfaces divergence so the caller
/// can present the three-way choice — this type never resolves a divergence
/// on its own. Not itself security-sensitive; all the real invariants
/// (secret exclusion, ff-only pull, no force-push, backup-before-apply)
/// live in `SyncRepository`/`GitCommandRunner` and are proven there.
@MainActor
final class SyncCoordinator: ObservableObject {
    @Published private(set) var status: SyncStatus = .idle
    @Published private(set) var remoteURL: String?
    @Published private(set) var autoPushEnabled: Bool
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var aheadBehind: GitAheadBehind?
    @Published private(set) var lastWarnings: [SyncSetWarning] = []
    @Published private(set) var pendingDiff: [SyncFileDiff] = []
    @Published private(set) var pendingMissingIdentityFiles: [String] = []

    private let repository: SyncRepository
    private let settingsStore: any SyncSettingsPersisting
    private let debounceInterval: TimeInterval
    private var debounceTask: Task<Void, Never>?

    var isConfigured: Bool { remoteURL?.isEmpty == false }

    init(
        repository: SyncRepository = .makeDefault(),
        settingsStore: any SyncSettingsPersisting = SyncSettingsStore(),
        debounceInterval: TimeInterval = 30
    ) {
        self.repository = repository
        self.settingsStore = settingsStore
        self.debounceInterval = debounceInterval

        let settings = (try? settingsStore.load()) ?? SyncSettings()
        remoteURL = settings.remoteURL
        autoPushEnabled = settings.autoPushEnabled
        lastSyncedAt = settings.lastSyncedAt
    }

    // MARK: - Change notification → debounced local commit

    /// Called by editors/stores after a successful save. Resets a
    /// `debounceInterval`-second timer; only the *last* call in a burst of
    /// edits actually triggers a commit. A no-op when no remote is
    /// configured yet.
    func noteChange() {
        guard isConfigured else { return }
        debounceTask?.cancel()
        status = .pendingCommit
        let interval = debounceInterval
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, interval) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.commitPendingChanges()
        }
    }

    private func commitPendingChanges() async {
        guard isConfigured else { return }
        status = .syncing
        do {
            let syncSet = try repository.exportSyncSetToRepo()
            lastWarnings = syncSet.warnings
            let committed = try await repository.commitIfDirty(message: Self.commitMessage())
            if committed, autoPushEnabled {
                try await repository.push()
            }
            status = .idle
            await refreshAheadBehind()
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    // MARK: - Manual actions

    /// "Şimdi senkronize et": export + commit (if dirty) + push, regardless
    /// of `autoPushEnabled`. Surfaces `.diverged` instead of throwing so the
    /// UI can present the three-way choice.
    func syncNow() async {
        guard isConfigured else { return }
        debounceTask?.cancel()
        status = .syncing
        do {
            let syncSet = try repository.exportSyncSetToRepo()
            lastWarnings = syncSet.warnings
            try await repository.commitIfDirty(message: Self.commitMessage())
            try await repository.push()
            markSynced()
            status = .idle
            await refreshAheadBehind()
        } catch let error as GitSyncError where error == .diverged {
            status = .diverged
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    /// App-launch + manual pull. Fast-forward only on the *sync repo* — this
    /// never touches real files on its own. If applying would change
    /// anything, `pendingDiff` is populated and `status` becomes
    /// `.pendingApply`; the caller must review and call
    /// `applyPendingChanges()` explicitly. `.diverged` means nothing was
    /// changed anywhere; the caller must resolve explicitly.
    func pull() async {
        guard isConfigured else { return }
        status = .syncing
        do {
            try await repository.pull()
            let diff = try repository.pendingApplyDiff()
            if diff.isEmpty {
                status = .idle
                pendingMissingIdentityFiles = []
            } else {
                pendingDiff = diff
                status = .pendingApply
                if let configDiff = diff.first(where: { $0.relativePath == "ssh/config" }) {
                    pendingMissingIdentityFiles = SyncRepository.missingIdentityFilePaths(inConfigSource: configDiff.incomingContent)
                } else {
                    pendingMissingIdentityFiles = []
                }
            }
            await refreshAheadBehind()
        } catch let error as GitSyncError where error == .diverged {
            status = .diverged
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    /// Applies `pendingDiff` to the real files — the only place real files
    /// get overwritten from a pull, and only after this has been called
    /// explicitly (from the restore/pull confirmation UI).
    func applyPendingChanges() async {
        guard case .pendingApply = status else { return }
        status = .syncing
        do {
            _ = try repository.applyRepoToRealLocations()
            pendingDiff = []
            pendingMissingIdentityFiles = []
            markSynced()
            status = .idle
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    /// Leaves the real files untouched and drops the pending review.
    func dismissPendingChanges() {
        guard case .pendingApply = status else { return }
        pendingDiff = []
        pendingMissingIdentityFiles = []
        status = .idle
    }

    /// Applies one of the three explicit divergence choices. `.cancel`
    /// deliberately leaves `status` at `.diverged` — nothing was resolved.
    func resolveDivergence(_ choice: SyncApplyChoice) async {
        guard choice != .cancel else { return }
        status = .syncing
        do {
            _ = try await repository.resolveDivergence(choice, commitMessage: Self.commitMessage())
            markSynced()
            status = .idle
            await refreshAheadBehind()
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    // MARK: - Settings

    func setRemoteURL(_ url: String?) async {
        let trimmed = url?.trimmingCharacters(in: .whitespacesAndNewlines)
        remoteURL = (trimmed?.isEmpty ?? true) ? nil : trimmed
        persistSettings()
        guard let remoteURL else { return }
        do {
            try await repository.setRemote(url: remoteURL)
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    func setAutoPushEnabled(_ enabled: Bool) {
        autoPushEnabled = enabled
        persistSettings()
    }

    private func markSynced() {
        lastSyncedAt = Date()
        persistSettings()
    }

    private func persistSettings() {
        try? settingsStore.save(SyncSettings(remoteURL: remoteURL, autoPushEnabled: autoPushEnabled, lastSyncedAt: lastSyncedAt))
    }

    private func refreshAheadBehind() async {
        aheadBehind = try? await repository.git.aheadBehindRemote()
    }

    private static func commitMessage() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM HH:mm"
        formatter.locale = Locale(identifier: "tr_TR")
        return String(localized: "Sync: \(formatter.string(from: Date()))")
    }
}
