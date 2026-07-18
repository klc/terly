import Foundation
import XCTest
@testable import SSHConfigurator

/// Proves every git invocation is built as an explicit argv array handed
/// straight to `Process` — never a shell string — so there is no
/// concatenation-injection surface, and that `GIT_TERMINAL_PROMPT=0` is
/// always set (the headless-hang guard).
final class GitCommandRunnerArgvTests: XCTestCase {
    private var repoURL: URL!
    private var executor: FakeGitProcessExecutor!
    private var runner: GitCommandRunner!

    override func setUp() {
        super.setUp()
        repoURL = URL(fileURLWithPath: "/tmp/terly-sync-argv-test-\(UUID().uuidString)")
        executor = FakeGitProcessExecutor()
        runner = GitCommandRunner(
            repositoryURL: repoURL,
            processClient: executor,
            environment: GitCommandRunner.defaultEnvironment(base: ["PATH": "/usr/bin"])
        )
    }

    func testEveryRequestUsesSystemGitAndRepoWorkingDirectory() async throws {
        executor.responder = { _ in .success() }
        _ = try await runner.hasRemote()

        let request = try XCTUnwrap(executor.requests.first)
        XCTAssertEqual(request.executableURL.path, "/usr/bin/git")
        XCTAssertEqual(request.currentDirectoryURL, repoURL)
    }

    func testTerminalPromptIsAlwaysDisabled() async throws {
        executor.responder = { _ in .success() }
        _ = try await runner.hasRemote()

        let request = try XCTUnwrap(executor.requests.first)
        XCTAssertEqual(request.environment["GIT_TERMINAL_PROMPT"], "0")
    }

    func testInitializeIfNeededArgv() async throws {
        executor.responder = { _ in .success() }
        try await runner.initializeIfNeeded()

        let argv = executor.requests.map(\.arguments)
        XCTAssertEqual(argv[0], ["init", "--initial-branch=main", "."])
        XCTAssertEqual(argv[1], ["config", "user.email", "sync@terly.local"])
        XCTAssertEqual(argv[2], ["config", "user.name", "Terly Sync"])
    }

    func testInitializeIfNeededSkipsInitWhenGitDirAlreadyExists() async throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: repoURL.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: repoURL) }

        executor.responder = { _ in .success() }
        try await runner.initializeIfNeeded()

        XCTAssertTrue(executor.requests.isEmpty)
    }

    func testSetRemoteAddsWhenNoOriginExists() async throws {
        executor.responder = { request in
            request.arguments == ["remote"] ? .success(output: "") : .success()
        }
        try await runner.setRemote(url: "git@github.com:example/dotfiles.git")

        let argv = executor.requests.map(\.arguments)
        XCTAssertEqual(argv, [["remote"], ["remote", "add", "origin", "git@github.com:example/dotfiles.git"]])
    }

    func testSetRemoteUpdatesWhenOriginAlreadyExists() async throws {
        executor.responder = { request in
            request.arguments == ["remote"] ? .success(output: "origin\n") : .success()
        }
        try await runner.setRemote(url: "https://example.com/dotfiles.git")

        let argv = executor.requests.map(\.arguments)
        XCTAssertEqual(argv, [["remote"], ["remote", "set-url", "origin", "https://example.com/dotfiles.git"]])
    }

    func testAddAllArgv() async throws {
        executor.responder = { _ in .success() }
        try await runner.addAll()
        XCTAssertEqual(executor.requests.first?.arguments, ["add", "-A", "."])
    }

    func testCommitMessageIsOneAtomicArgument() async throws {
        executor.responder = { _ in .success() }
        let message = "Sync: $(rm -rf ~) && echo pwned; touch /tmp/x"
        try await runner.commit(message: message)

        XCTAssertEqual(executor.requests.first?.arguments, ["commit", "-m", message])
    }

    func testPushArgv() async throws {
        executor.responder = { request in
            request.arguments == ["remote"] ? .success(output: "origin\n") : .success()
        }
        try await runner.push()
        XCTAssertEqual(executor.requests.last?.arguments, ["push", "origin", "HEAD:main"])
    }

    func testPushWithoutRemoteThrowsBeforeShellingOut() async throws {
        executor.responder = { request in
            request.arguments == ["remote"] ? .success(output: "") : .success()
        }
        do {
            try await runner.push()
            XCTFail("expected .noRemoteConfigured")
        } catch let error as GitSyncError {
            XCTAssertEqual(error, .noRemoteConfigured)
        }
        XCTAssertEqual(executor.requests.map(\.arguments), [["remote"]])
    }

    func testMergeKeepingLocalUsesOursStrategyNotRecursiveOption() async throws {
        executor.responder = { _ in .success() }
        try await runner.mergeKeepingLocal(message: "keep local")

        XCTAssertEqual(
            executor.requests.first?.arguments,
            ["merge", "-s", "ours", "--no-edit", "-m", "keep local", "origin/main"]
        )
    }

    func testResetHardToRemoteArgv() async throws {
        executor.responder = { _ in .success() }
        try await runner.resetHardToRemote()
        XCTAssertEqual(executor.requests.first?.arguments, ["reset", "--hard", "origin/main"])
    }

    func testPullFastForwardOnlyStopsAtDivergenceWithoutMerging() async throws {
        executor.responder = { request in
            switch request.arguments {
            case ["remote"]: return .success(output: "origin\n")
            case ["fetch", "origin"]: return .success()
            case ["rev-parse", "--verify", "-q", "HEAD"]: return .success(output: "aaaa\n")
            case ["rev-parse", "--verify", "-q", "origin/main"]: return .success(output: "bbbb\n")
            case ["merge-base", "--is-ancestor", "aaaa", "bbbb"]: return .failure(status: 1, error: "")
            default: XCTFail("unexpected argv \(request.arguments)"); return .success()
            }
        }

        do {
            try await runner.pullFastForwardOnly()
            XCTFail("expected .diverged")
        } catch let error as GitSyncError {
            XCTAssertEqual(error, .diverged)
        }

        XCTAssertFalse(executor.requests.contains { $0.arguments.first == "merge" })
    }

    func testPullFastForwardOnlyMergesWhenAncestor() async throws {
        executor.responder = { request in
            switch request.arguments {
            case ["remote"]: return .success(output: "origin\n")
            case ["fetch", "origin"]: return .success()
            case ["rev-parse", "--verify", "-q", "HEAD"]: return .success(output: "aaaa\n")
            case ["rev-parse", "--verify", "-q", "origin/main"]: return .success(output: "bbbb\n")
            case ["merge-base", "--is-ancestor", "aaaa", "bbbb"]: return .success()
            case ["merge", "--ff-only", "origin/main"]: return .success()
            default: XCTFail("unexpected argv \(request.arguments)"); return .success()
            }
        }

        try await runner.pullFastForwardOnly()
        XCTAssertTrue(executor.requests.contains { $0.arguments == ["merge", "--ff-only", "origin/main"] })
    }
}

// MARK: - Fake

enum FakeGitResponse {
    case success(output: String = "")
    case failure(status: Int32, error: String)
}

final class FakeGitProcessExecutor: SSHProcessExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [SSHProcessRequest] = []

    var responder: (@Sendable (SSHProcessRequest) -> FakeGitResponse)?

    var requests: [SSHProcessRequest] { lock.withLock { storedRequests } }

    func start(
        _ request: SSHProcessRequest,
        onOutput: @escaping @Sendable (SSHProcessStream, Data) -> Void,
        completion: @escaping @Sendable (Result<SSHProcessResult, SSHProcessClientError>) -> Void
    ) throws -> any SSHProcessTask {
        lock.withLock { storedRequests.append(request) }
        switch responder?(request) ?? .success() {
        case let .success(output):
            completion(.success(SSHProcessResult(terminationStatus: 0, standardOutput: output, standardError: "", duration: 0.01)))
        case let .failure(status, error):
            completion(.success(SSHProcessResult(terminationStatus: status, standardOutput: "", standardError: error, duration: 0.01)))
        }
        return FakeGitProcessTask()
    }
}

final class FakeGitProcessTask: SSHProcessTask, @unchecked Sendable {
    func cancel() {}
}
