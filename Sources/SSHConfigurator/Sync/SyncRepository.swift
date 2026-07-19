import Foundation
import SSHConfigCore

enum SyncRepositoryError: LocalizedError, Equatable {
    case unexpectedRepoLayout(String)

    var errorDescription: String? {
        switch self {
        case let .unexpectedRepoLayout(path):
            return String(localized: "Unexpected file path in the sync repository: \(path)")
        }
    }
}

/// The three explicit choices offered when local and remote history have
/// diverged. There is no silent-merge path — `resolveDivergence` only ever
/// runs after one of these has been picked by the user.
enum SyncApplyChoice: Equatable, Sendable {
    case backupLocalAndTakeRemote
    case overwriteRemoteWithLocal
    case cancel
}

struct SyncBackupResult: Equatable, Sendable {
    let backupDirectoryURL: URL
    let fileCount: Int
}

/// One file that would change if `applyRepoToRealLocations` ran right now —
/// the unit the restore/pull confirmation UI presents for review.
struct SyncFileDiff: Equatable, Sendable, Identifiable {
    enum Kind: Equatable, Sendable {
        case new
        case modified
    }

    let relativePath: String
    let kind: Kind
    let currentContent: String
    let incomingContent: String

    var id: String { relativePath }
}

/// Orchestrates the sync repo: exporting the app's real state into it,
/// committing, pushing/pulling (fast-forward-only), and — on divergence —
/// applying one of the three explicit `SyncApplyChoice`s. Every apply path
/// backs up the current sync set first (`backupCurrentSyncSet`), matching
/// the app's existing "never overwrite silently" invariant for `~/.ssh/config`.
struct SyncRepository: Sendable {
    let git: GitCommandRunner
    let resolver: SyncSetResolver
    let backupDirectoryURL: URL
    let configFileStore: SSHConfigFileStore

    var repositoryURL: URL { git.repositoryURL }

    /// `~/.ssh/config`'s real location, in lockstep with whatever
    /// `resolver` was built against — this is the single source of truth
    /// every method here uses, so an injected test resolver can never be
    /// silently bypassed by a method falling back to the *real* `~/.ssh`.
    private var sshDirectoryURL: URL { resolver.sshDirectoryURL }

    init(
        git: GitCommandRunner,
        resolver: SyncSetResolver = SyncSetResolver(),
        backupDirectoryURL: URL = SSHConfigFileStore().backupDirectory,
        configFileStore: SSHConfigFileStore? = nil
    ) {
        self.git = git
        self.resolver = resolver
        self.backupDirectoryURL = backupDirectoryURL
        self.configFileStore = configFileStore ?? SSHConfigFileStore(backupDirectory: backupDirectoryURL)
    }

    static var defaultRepositoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Terly", isDirectory: true)
            .appendingPathComponent("sync", isDirectory: true)
    }

    static func makeDefault() -> SyncRepository {
        SyncRepository(git: GitCommandRunner(repositoryURL: defaultRepositoryURL))
    }

    // MARK: - Export (real locations → repo)

    /// Copies the current sync set from its real locations into the repo
    /// working tree, and removes any repo-tracked file that's no longer
    /// part of the set (so a later `git add -A` records the deletion too).
    /// Does not touch git itself — call `commitIfDirty` after.
    @discardableResult
    func exportSyncSetToRepo() throws -> SyncSet {
        let syncSet = resolver.resolve()
        for file in syncSet.files {
            let destination = repositoryURL.appendingPathComponent(file.relativePath)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try Data(contentsOf: file.sourceURL)
            try data.write(to: destination, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
        try pruneOrphanedRepoFiles(keeping: syncSet)
        return syncSet
    }

    private func pruneOrphanedRepoFiles(keeping syncSet: SyncSet) throws {
        let keep = Set(syncSet.files.map(\.relativePath))
        for url in try trackedFileURLs() {
            let relative = relativePath(of: url)
            if !keep.contains(relative) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Git plumbing

    func setRemote(url: String) async throws {
        try await git.initializeIfNeeded()
        try await git.setRemote(url: url)
    }

    /// Stages and commits everything currently in the repo working tree.
    /// Returns `false` (no-op) when there was nothing to commit. Debouncing
    /// how often this is called is the caller's responsibility.
    @discardableResult
    func commitIfDirty(message: String) async throws -> Bool {
        try await git.initializeIfNeeded()
        try await git.addAll()
        guard try await git.hasStagedChanges() else { return false }
        try await git.commit(message: message)
        return true
    }

    /// Fetches first and throws `GitSyncError.diverged` if the remote has
    /// moved somewhere local hasn't — the same "surface it, never guess"
    /// contract as `pull()`. Without this pre-check, a plain `git push`
    /// against a diverged remote would still just fail, but as a raw
    /// `commandFailed` the caller can't distinguish from any other push
    /// error, which is exactly the ambiguity `SyncApplyChoice` exists to
    /// resolve.
    func push() async throws {
        try await git.fetch()
        guard try await git.isPushFastForward() else { throw GitSyncError.diverged }
        try await git.push()
    }

    /// Fast-forward-only pull. Throws `GitSyncError.diverged` the moment a
    /// real merge would be needed — callers must present the three-way
    /// choice and call `resolveDivergence` explicitly; this never merges on
    /// its own.
    func pull() async throws {
        try await git.initializeIfNeeded()
        try await git.pullFastForwardOnly()
    }

    // MARK: - Divergence resolution

    @discardableResult
    func resolveDivergence(_ choice: SyncApplyChoice, commitMessage: String) async throws -> SyncBackupResult? {
        switch choice {
        case .cancel:
            return nil

        case .backupLocalAndTakeRemote:
            try await git.fetch()
            try await git.resetHardToRemote()
            // `applyRepoToRealLocations` backs up the real sync set itself
            // (structurally — see its doc comment), so there's no separate
            // backup call needed here.
            return try applyRepoToRealLocations().backup

        case .overwriteRemoteWithLocal:
            let backup = try backupCurrentSyncSet()
            // Re-fetch first: the caller may be resolving a divergence that
            // was detected earlier, and the remote could have moved again
            // since — merging against a stale `origin/main` would produce a
            // commit that isn't actually a descendant of the real tip, and
            // the push below would be rejected as non-fast-forward.
            try await git.fetch()
            try await git.mergeKeepingLocal(message: commitMessage)
            try await git.push()
            return backup
        }
    }

    // MARK: - Backup (runs before every applied choice)

    @discardableResult
    func backupCurrentSyncSet() throws -> SyncBackupResult {
        let syncSet = resolver.resolve()
        let backupRoot = backupDirectoryURL.appendingPathComponent("sync-\(Self.backupStamp())", isDirectory: true)
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        var count = 0
        for file in syncSet.files {
            let destination = backupRoot.appendingPathComponent(file.relativePath)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            if (try? FileManager.default.copyItem(at: file.sourceURL, to: destination)) != nil {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                count += 1
            }
        }
        return SyncBackupResult(backupDirectoryURL: backupRoot, fileCount: count)
    }

    private static func backupStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date()) + "-" + UUID().uuidString.prefix(8)
    }

    // MARK: - Import (repo → real locations)

    struct ApplyResult: Equatable, Sendable {
        let backup: SyncBackupResult
        let appliedCount: Int
    }

    /// Copies every file currently in the repo working tree back to its
    /// real location. Always backs up the *current* real sync set first —
    /// structurally, so no caller can accidentally skip it the way the
    /// six JSON stores used to (only `~/.ssh/config` had a backup path,
    /// via `SSHConfigFileStore`, before this). `~/.ssh/config` still goes
    /// through `SSHConfigFileStore` too, for its symlink rejection and
    /// atomic-write invariants; everything else (Include files, app JSON
    /// stores) is written atomically with 0600 permissions.
    @discardableResult
    func applyRepoToRealLocations() throws -> ApplyResult {
        let backup = try backupCurrentSyncSet()
        var applied = 0
        for url in try trackedFileURLs() {
            let relative = relativePath(of: url)

            if relative == "ssh/config" {
                let source = try String(contentsOf: url, encoding: .utf8)
                let document = SSHConfigDocument(source: source)
                let configURL = sshDirectoryURL.appendingPathComponent("config", isDirectory: false)
                let expectedSnapshot = try configFileStore.snapshot(at: configURL)
                _ = try configFileStore.save(document, expectedSnapshot: expectedSnapshot)
                applied += 1
                continue
            }

            let destination = try realLocation(forRelativePath: relative)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try Data(contentsOf: url)
            try data.write(to: destination, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            applied += 1
        }
        return ApplyResult(backup: backup, appliedCount: applied)
    }

    /// What `applyRepoToRealLocations` *would* change, without changing
    /// anything — the data behind the restore/pull confirmation UI. Only
    /// files that differ from what's already on disk are included, so an
    /// empty result means nothing is pending.
    func pendingApplyDiff() throws -> [SyncFileDiff] {
        var diffs: [SyncFileDiff] = []
        for url in try trackedFileURLs() {
            let relative = relativePath(of: url)
            guard let destination = try? realLocation(forRelativePath: relative) else { continue }
            let incoming = (try? String(contentsOf: url, encoding: .utf8)) ?? ""

            guard FileManager.default.fileExists(atPath: destination.path) else {
                diffs.append(SyncFileDiff(relativePath: relative, kind: .new, currentContent: "", incomingContent: incoming))
                continue
            }
            let current = (try? String(contentsOf: destination, encoding: .utf8)) ?? ""
            if current != incoming {
                diffs.append(SyncFileDiff(relativePath: relative, kind: .modified, currentContent: current, incomingContent: incoming))
            }
        }
        return diffs
    }

    /// Best-effort scan of an incoming `~/.ssh/config` for `IdentityFile`
    /// paths that don't exist locally — literal paths only, no ssh_config
    /// token expansion (that needs a live per-host connection context, which
    /// `SSHConnectionDiagnostics` already covers when actually connecting).
    /// This is a restore-summary nudge, not a full diagnostic.
    static func missingIdentityFilePaths(
        inConfigSource source: String,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String] {
        let document = SSHConfigDocument(source: source)
        var rawPaths: Set<String> = []

        for directive in document.globalDirectives
            where directive.keyword.caseInsensitiveCompare("IdentityFile") == .orderedSame {
            rawPaths.insert(directive.value)
        }
        for host in document.hostBlocks {
            for line in document.lines where host.lineRange.contains(line.number) {
                guard case let .directive(keyword, value) = line.kind,
                      keyword.caseInsensitiveCompare("IdentityFile") == .orderedSame else { continue }
                rawPaths.insert(value)
            }
        }

        return rawPaths
            .filter { raw in
                guard !raw.contains("%") else { return false }
                let path = raw.hasPrefix("~/")
                    ? homeDirectoryURL.appendingPathComponent(String(raw.dropFirst(2))).path
                    : raw
                return !FileManager.default.fileExists(atPath: path)
            }
            .sorted()
    }

    private func realLocation(forRelativePath relative: String) throws -> URL {
        if relative.hasPrefix("ssh/") {
            return sshDirectoryURL.appendingPathComponent(String(relative.dropFirst("ssh/".count)))
        }
        if relative.hasPrefix("app/") {
            return resolver.appSupportDirectoryURL.appendingPathComponent(String(relative.dropFirst("app/".count)))
        }
        throw SyncRepositoryError.unexpectedRepoLayout(relative)
    }

    // MARK: - Repo tree walking

    private func trackedFileURLs() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: repositoryURL.path) else { return [] }
        guard let enumerator = FileManager.default.enumerator(
            at: repositoryURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        var results: [URL] = []
        for case let url as URL in enumerator {
            if url.pathComponents.contains(".git") { continue }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard !isDirectory else { continue }
            results.append(url)
        }
        return results
    }

    /// `FileManager`'s enumerator resolves symlinks in the paths it returns
    /// (e.g. macOS's `/var` → `/private/var`) even when `repositoryURL`
    /// itself doesn't — resolving both sides before comparing is what keeps
    /// this from misdetecting every file as "orphaned" and deleting it right
    /// after `exportSyncSetToRepo` just wrote it.
    private func relativePath(of url: URL) -> String {
        let resolvedRoot = repositoryURL.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedURL.hasPrefix(resolvedRoot + "/") else { return url.lastPathComponent }
        return String(resolvedURL.dropFirst(resolvedRoot.count + 1))
    }
}
