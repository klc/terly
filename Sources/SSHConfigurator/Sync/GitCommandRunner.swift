import Foundation

/// Thin argv-only wrapper around the system `git` binary. No shell is ever
/// involved — every command is an explicit argument array passed straight to
/// `Process`/`SSHProcessExecuting`, so there is no string-concatenation
/// injection surface. The app never stores or supplies git credentials
/// itself: authentication is left entirely to the user's own SSH
/// key/credential helper, reached the same way WP2's SSH_ASKPASS bridge
/// reaches it for SCP/SFTP.
enum GitSyncError: LocalizedError, Equatable {
    case launchFailed(String)
    case commandFailed(command: String, exitCode: Int32, output: String)
    case diverged
    case noRemoteConfigured

    var errorDescription: String? {
        switch self {
        case let .launchFailed(message):
            return "git çalıştırılamadı: \(message)"
        case let .commandFailed(command, exitCode, output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return "git \(command) başarısız oldu (çıkış kodu \(exitCode))\(trimmed.isEmpty ? "" : ": \(trimmed)")"
        case .diverged:
            return "Yerel ve uzak geçmiş ayrıştı (diverged). Fast-forward pull uygulanamaz — bir çözüm seçilmeli."
        case .noRemoteConfigured:
            return "Senkronizasyon için önce bir uzak repo adresi ayarlanmalı."
        }
    }
}

struct GitAheadBehind: Equatable, Sendable {
    let ahead: Int
    let behind: Int
}

struct GitCommandRunner: Sendable {
    static let remoteName = "origin"
    static let branchName = "main"

    let repositoryURL: URL
    private let executableURL: URL
    private let processClient: any SSHProcessExecuting
    private let environment: [String: String]
    private let timeout: TimeInterval

    init(
        repositoryURL: URL,
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
        processClient: any SSHProcessExecuting = SSHProcessClient(),
        environment: [String: String] = GitCommandRunner.defaultEnvironment(),
        timeout: TimeInterval = 120
    ) {
        self.repositoryURL = repositoryURL
        self.executableURL = executableURL
        self.processClient = processClient
        self.environment = environment
        self.timeout = timeout
    }

    /// `GIT_TERMINAL_PROMPT=0` is the load-bearing setting here: without it,
    /// git run headless (no controlling terminal) *hangs* waiting for a
    /// username/password instead of failing — this turns that into an
    /// immediate, reportable error. SSH transport passphrase/host-key
    /// prompts still work because they go through `ssh`, which is routed to
    /// the bundled askpass helper by `interactiveAuth()`.
    static func defaultEnvironment(
        base: [String: String] = SSHProcessEnvironment.interactiveAuth()
    ) -> [String: String] {
        var environment = base
        environment["GIT_TERMINAL_PROMPT"] = "0"
        return environment
    }

    @discardableResult
    private func run(_ arguments: [String], timeout: TimeInterval? = nil) async throws -> SSHProcessResult {
        let request = SSHProcessRequest(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            currentDirectoryURL: repositoryURL,
            timeout: timeout ?? self.timeout
        )
        do {
            return try await processClient.execute(request)
        } catch let error as SSHProcessClientError {
            throw GitSyncError.launchFailed(error.localizedDescription)
        }
    }

    private func runChecked(_ arguments: [String], commandLabel: String, timeout: TimeInterval? = nil) async throws {
        let result = try await run(arguments, timeout: timeout)
        guard result.terminationStatus == 0 else {
            throw GitSyncError.commandFailed(command: commandLabel, exitCode: result.terminationStatus, output: result.combinedOutput)
        }
    }

    func initializeIfNeeded() async throws {
        try FileManager.default.createDirectory(
            at: repositoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let gitDir = repositoryURL.appendingPathComponent(".git", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: gitDir.path) else { return }
        try await runChecked(["init", "--initial-branch=\(Self.branchName)", "."], commandLabel: "init")
        // Repo-local (not global) committer identity — this never touches
        // the user's real git identity or credentials.
        try await runChecked(["config", "user.email", "sync@terly.local"], commandLabel: "config user.email")
        try await runChecked(["config", "user.name", "Terly Sync"], commandLabel: "config user.name")
    }

    func hasRemote() async throws -> Bool {
        let result = try await run(["remote"], timeout: 15)
        return result.standardOutput
            .split(separator: "\n")
            .map(String.init)
            .contains(Self.remoteName)
    }

    func setRemote(url: String) async throws {
        if try await hasRemote() {
            try await runChecked(["remote", "set-url", Self.remoteName, url], commandLabel: "remote set-url")
        } else {
            try await runChecked(["remote", "add", Self.remoteName, url], commandLabel: "remote add")
        }
    }

    func addAll() async throws {
        try await runChecked(["add", "-A", "."], commandLabel: "add")
    }

    /// `git diff --cached --quiet` exits 1 when there are staged
    /// differences, 0 when there are none — deliberately not run through
    /// `runChecked`, which would treat exit 1 as failure.
    func hasStagedChanges() async throws -> Bool {
        let result = try await run(["diff", "--cached", "--quiet"], timeout: 15)
        return result.terminationStatus == 1
    }

    func commit(message: String) async throws {
        try await runChecked(["commit", "-m", message], commandLabel: "commit")
    }

    /// Deliberately fetches *without* naming `main` explicitly: `git fetch
    /// origin main` fails outright ("couldn't find remote ref main") against
    /// a brand-new bare remote that has no branches yet — which is exactly
    /// the state of things before the very first push. `git fetch origin`
    /// fetches whatever the remote actually has (nothing, on a fresh repo)
    /// and succeeds either way.
    func fetch() async throws {
        guard try await hasRemote() else { throw GitSyncError.noRemoteConfigured }
        try await runChecked(["fetch", Self.remoteName], commandLabel: "fetch", timeout: 60)
    }

    func currentHead() async throws -> String? {
        let result = try await run(["rev-parse", "--verify", "-q", "HEAD"], timeout: 15)
        guard result.terminationStatus == 0 else { return nil }
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func remoteHead() async throws -> String? {
        let result = try await run(["rev-parse", "--verify", "-q", "\(Self.remoteName)/\(Self.branchName)"], timeout: 15)
        guard result.terminationStatus == 0 else { return nil }
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when local `HEAD` is an ancestor of (or equal to) the fetched
    /// remote branch — i.e. fast-forward is possible without discarding any
    /// local commit. `fetch()` must be called first.
    func isFastForwardable() async throws -> Bool {
        guard let local = try await currentHead() else { return true }
        guard let remote = try await remoteHead() else { return true }
        if local == remote { return true }
        let result = try await run(["merge-base", "--is-ancestor", local, remote], timeout: 15)
        return result.terminationStatus == 0
    }

    /// True when the fetched `origin/main` is an ancestor of (or equal to)
    /// local `HEAD` — i.e. pushing would be a fast-forward of the remote.
    /// The push-direction mirror of `isFastForwardable()`; `fetch()` must be
    /// called first.
    func isPushFastForward() async throws -> Bool {
        guard let local = try await currentHead() else { return false }
        guard let remote = try await remoteHead() else { return true }
        if local == remote { return true }
        let result = try await run(["merge-base", "--is-ancestor", remote, local], timeout: 15)
        return result.terminationStatus == 0
    }

    /// Fetches, then fast-forwards local `main` onto `origin/main`. Never
    /// merges, never loses data: throws `.diverged` the moment a real merge
    /// would be required, leaving both histories untouched for the caller to
    /// resolve explicitly.
    func pullFastForwardOnly() async throws {
        try await fetch()
        guard try await isFastForwardable() else { throw GitSyncError.diverged }
        try await runChecked(["merge", "--ff-only", "\(Self.remoteName)/\(Self.branchName)"], commandLabel: "merge --ff-only")
    }

    func push() async throws {
        guard try await hasRemote() else { throw GitSyncError.noRemoteConfigured }
        try await runChecked(["push", Self.remoteName, "HEAD:\(Self.branchName)"], commandLabel: "push", timeout: 60)
    }

    /// Conflict resolution (b) — "uzaktakini yerelle ez": uses the `ours`
    /// merge *strategy* (not the recursive `-X ours` option, which would
    /// still pull in non-conflicting remote changes) so the resulting tree
    /// is exactly the local tree, while recording `origin/main` as a second
    /// parent. That makes the new commit a genuine descendant of the remote
    /// branch, so a normal `push` — never `--force` — succeeds.
    func mergeKeepingLocal(message: String) async throws {
        try await runChecked(
            ["merge", "-s", "ours", "--no-edit", "-m", message, "\(Self.remoteName)/\(Self.branchName)"],
            commandLabel: "merge -s ours",
            timeout: 60
        )
    }

    /// Conflict resolution (a) — "yereli yedekle + uzaktakini al": resets
    /// the working tree to exactly `origin/main`. The caller must back up
    /// current local state through the app's existing backup mechanism
    /// *before* calling this — see `SyncRepository`.
    func resetHardToRemote() async throws {
        try await runChecked(["reset", "--hard", "\(Self.remoteName)/\(Self.branchName)"], commandLabel: "reset --hard", timeout: 30)
    }

    func aheadBehindRemote() async throws -> GitAheadBehind? {
        guard try await currentHead() != nil, try await remoteHead() != nil else { return nil }
        let result = try await run(
            ["rev-list", "--left-right", "--count", "HEAD...\(Self.remoteName)/\(Self.branchName)"],
            timeout: 15
        )
        guard result.terminationStatus == 0 else { return nil }
        let parts = result.standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t")
            .compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return GitAheadBehind(ahead: parts[0], behind: parts[1])
    }

    /// Contents of a committed file (e.g. `HEAD:snippets.json`) — used by the
    /// secret-exclusion proof test to check what actually landed in git,
    /// not just what's on disk in the working tree.
    func showCommittedFile(_ objectSpec: String) async throws -> String {
        let result = try await run(["show", objectSpec], timeout: 15)
        guard result.terminationStatus == 0 else {
            throw GitSyncError.commandFailed(command: "show \(objectSpec)", exitCode: result.terminationStatus, output: result.combinedOutput)
        }
        return result.standardOutput
    }
}
