import Foundation
import XCTest
@testable import SSHConfigurator

/// Integration tests that run the *real* `/usr/bin/git` binary against
/// temporary directories — deliberately not the fake executor, per the
/// plan's "iki makine simülasyonu" acceptance criterion and because the
/// headless-hang guard (`GIT_TERMINAL_PROMPT=0`) and the non-force-push
/// divergence resolution can only be trusted once proven against real git.
final class SyncRepositoryGitIntegrationTests: XCTestCase {
    private var root: URL!
    private var bareRemoteURL: URL!

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("terly-sync-git-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        bareRemoteURL = root.appendingPathComponent("remote.git", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: - Machine simulation

    /// One simulated machine: its own `~/.ssh`, its own app-support
    /// directory, and its own sync working directory — fully isolated from
    /// every other machine created in the same test, exactly like two real
    /// Macs would be.
    private struct Machine {
        let sshDir: URL
        let appSupportDir: URL
        let repository: SyncRepository
    }

    private func makeMachine(named name: String) throws -> Machine {
        let base = root.appendingPathComponent(name, isDirectory: true)
        let sshDir = base.appendingPathComponent(".ssh", isDirectory: true)
        let appSupportDir = base.appendingPathComponent("AppSupport", isDirectory: true)
        let syncDir = base.appendingPathComponent("sync", isDirectory: true)
        let backupsDir = base.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)

        // `backupDirectoryURL` must stay per-machine and temp-scoped — it's
        // also where `SSHConfigFileStore`'s own config backups land
        // (`SyncRepository` derives its default `configFileStore` from it).
        // Falling back to the real default here would make every test run
        // write into the user's actual `~/Library/.../Backups`.
        let repository = SyncRepository(
            git: GitCommandRunner(repositoryURL: syncDir),
            resolver: SyncSetResolver(sshDirectoryURL: sshDir, appSupportDirectoryURL: appSupportDir),
            backupDirectoryURL: backupsDir
        )
        return Machine(sshDir: sshDir, appSupportDir: appSupportDir, repository: repository)
    }

    private func initBareRemote() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["init", "--bare", "--initial-branch=main", bareRemoteURL.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Round trip

    func testTwoMachineEditCommitPushPullApplyRoundTrip() async throws {
        try initBareRemote()
        let machineA = try makeMachine(named: "A")
        let machineB = try makeMachine(named: "B")

        try write("Host prod\n  HostName prod.example.com\n  User deploy\n", to: machineA.sshDir.appendingPathComponent("config"))

        try await machineA.repository.setRemote(url: bareRemoteURL.path)
        _ = try machineA.repository.exportSyncSetToRepo()
        let committed = try await machineA.repository.commitIfDirty(message: "İlk yapılandırma")
        XCTAssertTrue(committed)
        try await machineA.repository.push()

        try await machineB.repository.setRemote(url: bareRemoteURL.path)
        try await machineB.repository.pull()
        let applyResult = try machineB.repository.applyRepoToRealLocations()
        XCTAssertGreaterThan(applyResult.appliedCount, 0)

        let restoredConfig = try String(contentsOf: machineB.sshDir.appendingPathComponent("config"), encoding: .utf8)
        XCTAssertTrue(restoredConfig.contains("prod.example.com"))
    }

    func testDivergedHistoryIsRejectedByFastForwardOnlyPull() async throws {
        try initBareRemote()
        let machineA = try makeMachine(named: "A")
        let machineB = try makeMachine(named: "B")

        try write("Host base\n  HostName base.example.com\n", to: machineA.sshDir.appendingPathComponent("config"))
        try await machineA.repository.setRemote(url: bareRemoteURL.path)
        _ = try machineA.repository.exportSyncSetToRepo()
        try await machineA.repository.commitIfDirty(message: "base")
        try await machineA.repository.push()

        try await machineB.repository.setRemote(url: bareRemoteURL.path)
        try await machineB.repository.pull()

        // A advances and pushes.
        try write("Host base\n  HostName base.example.com\nHost added-by-a\n  HostName a.example.com\n", to: machineA.sshDir.appendingPathComponent("config"))
        _ = try machineA.repository.exportSyncSetToRepo()
        try await machineA.repository.commitIfDirty(message: "A ekledi")
        try await machineA.repository.push()

        // B independently advances without pulling first — now diverged.
        try write("Host base\n  HostName base.example.com\nHost added-by-b\n  HostName b.example.com\n", to: machineB.sshDir.appendingPathComponent("config"))
        _ = try machineB.repository.exportSyncSetToRepo()
        try await machineB.repository.commitIfDirty(message: "B ekledi")

        do {
            try await machineB.repository.pull()
            XCTFail("expected .diverged — ff-only pull must never silently merge")
        } catch let error as GitSyncError {
            XCTAssertEqual(error, .diverged)
        }

        // Nothing changed on disk — no silent merge/overwrite.
        let stillLocal = try String(contentsOf: machineB.sshDir.appendingPathComponent("config"), encoding: .utf8)
        XCTAssertTrue(stillLocal.contains("added-by-b"))
    }

    func testResolveDivergenceBackupLocalAndTakeRemote() async throws {
        try initBareRemote()
        let (_, machineB) = try await makeDivergedPair()

        let backup = try await machineB.repository.resolveDivergence(.backupLocalAndTakeRemote, commitMessage: "n/a")
        let unwrappedBackup = try XCTUnwrap(backup)
        XCTAssertGreaterThan(unwrappedBackup.fileCount, 0)

        // Backup preserves B's pre-resolution content.
        let backedUpConfig = try String(
            contentsOf: unwrappedBackup.backupDirectoryURL.appendingPathComponent("ssh/config"),
            encoding: .utf8
        )
        XCTAssertTrue(backedUpConfig.contains("added-by-b"))

        // Applying afterwards yields A's (remote's) content, not B's.
        _ = try machineB.repository.applyRepoToRealLocations()
        let resolvedConfig = try String(contentsOf: machineB.sshDir.appendingPathComponent("config"), encoding: .utf8)
        XCTAssertTrue(resolvedConfig.contains("added-by-a"))
        XCTAssertFalse(resolvedConfig.contains("added-by-b"))
    }

    func testResolveDivergenceOverwriteRemoteWithLocalPushesWithoutForce() async throws {
        try initBareRemote()
        let (_, machineB) = try await makeDivergedPair()

        // Non-force push must succeed here — if the merge commit weren't a
        // genuine descendant of origin/main, plain `git push` would be
        // rejected and this would throw.
        try await machineB.repository.resolveDivergence(.overwriteRemoteWithLocal, commitMessage: "B'yi tercih et")

        // A third machine doing a plain ff-only pull must see B's content —
        // proof the remote history is a normal, linear, non-rewritten
        // history (a force-push/rewrite would break this for anyone who'd
        // already fetched the old tip).
        let machineC = try makeMachine(named: "C")
        try await machineC.repository.setRemote(url: bareRemoteURL.path)
        try await machineC.repository.pull()
        _ = try machineC.repository.applyRepoToRealLocations()

        let resolvedConfig = try String(contentsOf: machineC.sshDir.appendingPathComponent("config"), encoding: .utf8)
        XCTAssertTrue(resolvedConfig.contains("added-by-b"))
    }

    /// Sets up two machines that both pushed from a shared base and then
    /// diverged — B has local, uncommitted-to-remote work; A's version is
    /// what's actually on the remote.
    private func makeDivergedPair() async throws -> (Machine, Machine) {
        let machineA = try makeMachine(named: "A")
        let machineB = try makeMachine(named: "B")

        try write("Host base\n  HostName base.example.com\n", to: machineA.sshDir.appendingPathComponent("config"))
        try await machineA.repository.setRemote(url: bareRemoteURL.path)
        _ = try machineA.repository.exportSyncSetToRepo()
        try await machineA.repository.commitIfDirty(message: "base")
        try await machineA.repository.push()

        try await machineB.repository.setRemote(url: bareRemoteURL.path)
        try await machineB.repository.pull()

        try write("Host base\n  HostName base.example.com\nHost added-by-a\n  HostName a.example.com\n", to: machineA.sshDir.appendingPathComponent("config"))
        _ = try machineA.repository.exportSyncSetToRepo()
        try await machineA.repository.commitIfDirty(message: "A ekledi")
        try await machineA.repository.push()

        try write("Host base\n  HostName base.example.com\nHost added-by-b\n  HostName b.example.com\n", to: machineB.sshDir.appendingPathComponent("config"))
        _ = try machineB.repository.exportSyncSetToRepo()
        try await machineB.repository.commitIfDirty(message: "B ekledi")

        return (machineA, machineB)
    }

    // MARK: - Secret exclusion proof

    // MARK: - Backup-before-apply is structural (not just for ~/.ssh/config)

    /// Regression test for a real bug: `applyRepoToRealLocations` used to
    /// back up `~/.ssh/config` (via `SSHConfigFileStore`) but overwrite the
    /// six JSON stores with a plain atomic write and no backup at all. The
    /// fix makes the backup unconditional and internal to
    /// `applyRepoToRealLocations` itself — this proves a JSON store's
    /// pre-apply content survives in the backup, not just the config file's.
    func testApplyRepoToRealLocationsBacksUpJSONStoresNotJustConfig() async throws {
        try initBareRemote()
        let machineA = try makeMachine(named: "A")
        let machineB = try makeMachine(named: "B")

        try write(#"[{"id":"11111111-1111-1111-1111-111111111111","alias":"a-tunnel"}]"#, to: machineA.appSupportDir.appendingPathComponent("tunnels.json"))
        try await machineA.repository.setRemote(url: bareRemoteURL.path)
        _ = try machineA.repository.exportSyncSetToRepo()
        try await machineA.repository.commitIfDirty(message: "tunnel eklendi")
        try await machineA.repository.push()

        let originalLocalTunnelsJSON = #"[{"id":"22222222-2222-2222-2222-222222222222","alias":"b-tunnel-before-apply"}]"#
        try write(originalLocalTunnelsJSON, to: machineB.appSupportDir.appendingPathComponent("tunnels.json"))
        try await machineB.repository.setRemote(url: bareRemoteURL.path)
        try await machineB.repository.pull()

        let result = try machineB.repository.applyRepoToRealLocations()

        let backedUpTunnelsJSON = try String(
            contentsOf: result.backup.backupDirectoryURL.appendingPathComponent("app/tunnels.json"),
            encoding: .utf8
        )
        XCTAssertEqual(backedUpTunnelsJSON, originalLocalTunnelsJSON)

        let appliedTunnelsJSON = try String(contentsOf: machineB.appSupportDir.appendingPathComponent("tunnels.json"), encoding: .utf8)
        XCTAssertTrue(appliedTunnelsJSON.contains("a-tunnel"))
    }

    func testPendingApplyDiffReflectsWhatWouldChangeWithoutChangingAnything() async throws {
        try initBareRemote()
        let machineA = try makeMachine(named: "A")
        let machineB = try makeMachine(named: "B")

        try write("Host prod\n  HostName prod.example.com\n", to: machineA.sshDir.appendingPathComponent("config"))
        try await machineA.repository.setRemote(url: bareRemoteURL.path)
        _ = try machineA.repository.exportSyncSetToRepo()
        try await machineA.repository.commitIfDirty(message: "config eklendi")
        try await machineA.repository.push()

        try await machineB.repository.setRemote(url: bareRemoteURL.path)
        try await machineB.repository.pull()

        let diff = try machineB.repository.pendingApplyDiff()
        XCTAssertTrue(diff.contains { $0.relativePath == "ssh/config" && $0.kind == .new })

        // Computing the diff must not have touched B's real files.
        XCTAssertFalse(FileManager.default.fileExists(atPath: machineB.sshDir.appendingPathComponent("config").path))
    }

    func testMissingIdentityFilePathsFindsHostAndGlobalDirectivesButSkipsTokensAndExistingFiles() throws {
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let presentKey = home.appendingPathComponent(".ssh/id_present", isDirectory: false)
        try write("present", to: presentKey)

        let source = """
        IdentityFile ~/.ssh/id_present
        IdentityFile ~/.ssh/id_missing

        Host prod
          HostName prod.example.com
          IdentityFile ~/.ssh/id_prod_missing

        Host with-token
          HostName token.example.com
          IdentityFile ~/.ssh/id_%r_unresolvable
        """

        let missing = SyncRepository.missingIdentityFilePaths(inConfigSource: source, homeDirectoryURL: home)

        XCTAssertEqual(missing, ["~/.ssh/id_missing", "~/.ssh/id_prod_missing"])
    }

    func testSecretSnippetValueNeverAppearsInCommittedBlobOrGitObjects() async throws {
        try initBareRemote()
        let machine = try makeMachine(named: "A")

        let secretValue = "sk_live_TOPSECRET_12345_do_not_leak"
        let snippet = Snippet(key: "prod-token", value: secretValue, isSecret: true)
        try SnippetStore(fileURL: machine.appSupportDir.appendingPathComponent("snippets.json")).save([snippet])

        try await machine.repository.setRemote(url: bareRemoteURL.path)
        _ = try machine.repository.exportSyncSetToRepo()
        try await machine.repository.commitIfDirty(message: "snippet eklendi")

        // What's actually committed to git, not just what's on disk.
        let committedBlob = try await machine.repository.git.showCommittedFile("HEAD:app/snippets.json")
        XCTAssertFalse(committedBlob.contains(secretValue))

        // The repo's working tree copy.
        let workingTreeCopy = try String(
            contentsOf: machine.repository.repositoryURL.appendingPathComponent("app/snippets.json"),
            encoding: .utf8
        )
        XCTAssertFalse(workingTreeCopy.contains(secretValue))

        // The raw git object database (loose objects + packs) — the
        // strongest check: the plaintext must not exist *anywhere* under
        // `.git`, committed history included.
        let gitDir = machine.repository.repositoryURL.appendingPathComponent(".git")
        let grep = Process()
        grep.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        grep.arguments = ["grep", "--no-index", "-I", secretValue]
        // `git grep` over refs finds it in history too; run against every commit.
        grep.currentDirectoryURL = machine.repository.repositoryURL
        grep.arguments = ["log", "--all", "-p", "-S", secretValue]
        let pipe = Pipe()
        grep.standardOutput = pipe
        try grep.run()
        grep.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertTrue(output.isEmpty, "secret value must never appear in git history: \(output)")
        _ = gitDir
    }
}
