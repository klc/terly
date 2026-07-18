import Foundation
import XCTest
@testable import SSHConfigurator

// MARK: - RunbookCommandComposer

final class RunbookCommandComposerTests: XCTestCase {
    func testComposeSubstitutesKnownPlaceholders() throws {
        let step = RunbookStep(command: "deploy --version={{version}} --env={{env}}")

        let composed = try RunbookCommandComposer.compose(
            step: step,
            values: ["version": "1.2.3", "env": "prod"]
        )

        XCTAssertEqual(composed, "deploy --version='1.2.3' --env='prod'")
    }

    func testComposeLeavesCommandsWithoutPlaceholdersUntouched() throws {
        let step = RunbookStep(command: "systemctl status nginx")

        let composed = try RunbookCommandComposer.compose(step: step, values: [:])

        XCTAssertEqual(composed, "systemctl status nginx")
    }

    func testComposeThrowsOnUnknownPlaceholder() {
        let step = RunbookStep(command: "echo {{missing}}")

        XCTAssertThrowsError(try RunbookCommandComposer.compose(step: step, values: [:])) { error in
            guard case let RunbookCommandComposerError.unknownPlaceholder(name) = error else {
                XCTFail("expected unknownPlaceholder, got \(error)")
                return
            }
            XCTAssertEqual(name, "missing")
        }
    }

    /// The most important guarantee of the composer: whatever a parameter
    /// value contains — spaces, single quotes, `;`, `$(...)`, backticks — it
    /// must round-trip through the shell as one opaque literal, never as
    /// executable shell syntax. Verified by actually running the composed
    /// command through `/bin/sh` and checking the interpreted value is
    /// byte-for-byte identical to what was supplied, with no side effects
    /// from anything that would have run if injection had succeeded.
    func testComposedValuesCannotInjectShellSyntax() throws {
        let markerA = FileManager.default.temporaryDirectory.appendingPathComponent("runbook_inject_a_\(UUID().uuidString)")
        let markerB = FileManager.default.temporaryDirectory.appendingPathComponent("runbook_inject_b_\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: markerA)
            try? FileManager.default.removeItem(at: markerB)
        }

        let dangerousValues = [
            "hello world",
            "it's a test",
            "a; touch \(markerA.path)",
            "$(touch \(markerB.path))",
            "`echo pwned`",
            "line1\nline2",
        ]

        let step = RunbookStep(command: "printf '%s' {{value}}")

        for value in dangerousValues {
            let composed = try RunbookCommandComposer.compose(step: step, values: ["value": value])

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", composed]
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()

            let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTAssertEqual(output, value, "value should round-trip unchanged for input: \(value)")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: markerA.path), "unquoted `;` must not execute a second command")
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerB.path), "unquoted $(...) must not be evaluated")
    }
}

// MARK: - RunbookDangerDetector

final class RunbookDangerDetectorTests: XCTestCase {
    func testDetectsKnownDangerousPatterns() {
        XCTAssertTrue(RunbookDangerDetector.isDangerous("sudo rm -rf /var/data"))
        XCTAssertTrue(RunbookDangerDetector.isDangerous("kill -9 1234"))
        XCTAssertTrue(RunbookDangerDetector.isDangerous("shutdown -h now"))
        XCTAssertFalse(RunbookDangerDetector.isDangerous("echo hello"))
    }
}

// MARK: - RunbookStore

final class RunbookStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testMissingStoreLoadsAsEmpty() throws {
        let store = RunbookStore(fileURL: root.appendingPathComponent("runbooks.json"))
        XCTAssertEqual(try store.load(), [])
    }

    func testSaveAndLoadRoundTrips() throws {
        let store = RunbookStore(fileURL: root.appendingPathComponent("runbooks.json"))
        let runbooks = [
            Runbook(
                name: "Deploy",
                description: "Rolling deploy",
                steps: [
                    RunbookStep(command: "cd /srv/app", continueOnError: false),
                    RunbookStep(command: "git pull", continueOnError: true),
                ],
                parameters: [RunbookParameter(name: "version", defaultValue: "latest")],
                isDangerous: false
            ),
        ]

        try store.save(runbooks)

        XCTAssertEqual(try store.load(), runbooks)
    }

    func testStoreFilePermissionsAre0600() throws {
        let fileURL = root.appendingPathComponent("runbooks.json")
        let store = RunbookStore(fileURL: fileURL)
        try store.save([Runbook(name: "Test")])

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let permissions = attributes[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.int16Value, 0o600)
    }
}

// MARK: - RunbookExecutionEngine

@MainActor
final class RunbookExecutionEngineTests: XCTestCase {
    func testStepsRunSequentiallyInOrder() async throws {
        let executor = FakeRunbookProcessExecutor()
        let engine = RunbookExecutionEngine(processExecuting: executor)

        let runbook = Runbook(name: "Seq", steps: [
            RunbookStep(command: "echo one"),
            RunbookStep(command: "echo two"),
            RunbookStep(command: "echo three"),
        ])

        engine.run(runbook: runbook, values: [:], targets: ["host-a"], concurrencyLimit: 1)
        await waitUntilFinished(engine)

        let commands = executor.requests.map { RunbookTestSupport.command(in: $0) }
        XCTAssertEqual(commands, ["echo one", "echo two", "echo three"])
        XCTAssertEqual(engine.results["host-a"]?.status, .succeeded)
    }

    func testContinueOnErrorFalseStopsRemainingStepsOnFailure() async throws {
        let executor = FakeRunbookProcessExecutor()
        executor.responder = { request in
            let command = RunbookTestSupport.command(in: request)
            if command == "fail-step" {
                return .success(exitCode: 1, output: "boom")
            }
            return .success(exitCode: 0, output: "")
        }

        let runbook = Runbook(name: "Stop", steps: [
            RunbookStep(command: "fail-step", continueOnError: false),
            RunbookStep(command: "never-runs", continueOnError: false),
        ])
        let engine = RunbookExecutionEngine(processExecuting: executor)

        engine.run(runbook: runbook, values: [:], targets: ["host-a"])
        await waitUntilFinished(engine)

        let commands = executor.requests.map { RunbookTestSupport.command(in: $0) }
        XCTAssertEqual(commands, ["fail-step"])
        guard case let .failed(message)? = engine.results["host-a"]?.status else {
            return XCTFail("expected failed status")
        }
        XCTAssertTrue(message.contains("1"))
    }

    func testContinueOnErrorTrueRunsRemainingSteps() async throws {
        let executor = FakeRunbookProcessExecutor()
        executor.responder = { request in
            let command = RunbookTestSupport.command(in: request)
            if command == "fail-step" {
                return .success(exitCode: 1, output: "boom")
            }
            return .success(exitCode: 0, output: "")
        }

        let runbook = Runbook(name: "Continue", steps: [
            RunbookStep(command: "fail-step", continueOnError: true),
            RunbookStep(command: "still-runs", continueOnError: false),
        ])
        let engine = RunbookExecutionEngine(processExecuting: executor)

        engine.run(runbook: runbook, values: [:], targets: ["host-a"])
        await waitUntilFinished(engine)

        let commands = executor.requests.map { RunbookTestSupport.command(in: $0) }
        XCTAssertEqual(commands, ["fail-step", "still-runs"])
        XCTAssertEqual(engine.results["host-a"]?.status, .succeeded)
    }

    func testOneHostFailingDoesNotAffectAnother() async throws {
        let executor = FakeRunbookProcessExecutor()
        executor.responder = { request in
            let alias = RunbookTestSupport.alias(in: request)
            if alias == "bad-host" {
                return .success(exitCode: 1, output: "boom")
            }
            return .success(exitCode: 0, output: "ok")
        }

        let runbook = Runbook(name: "Isolation", steps: [RunbookStep(command: "run-thing", continueOnError: false)])
        let engine = RunbookExecutionEngine(processExecuting: executor)

        engine.run(runbook: runbook, values: [:], targets: ["bad-host", "good-host"])
        await waitUntilFinished(engine)

        guard case .failed? = engine.results["bad-host"]?.status else {
            return XCTFail("expected bad-host to fail")
        }
        XCTAssertEqual(engine.results["good-host"]?.status, .succeeded)
    }

    func testConcurrencyLimitIsNeverExceeded() async throws {
        let executor = FakeRunbookProcessExecutor()
        executor.responder = { _ in .success(exitCode: 0, output: "", delay: 0.05) }

        let runbook = Runbook(name: "Fanout", steps: [RunbookStep(command: "work")])
        let engine = RunbookExecutionEngine(processExecuting: executor)

        let targets = (0 ..< 8).map { "host-\($0)" }
        engine.run(runbook: runbook, values: [:], targets: targets, concurrencyLimit: 2)
        await waitUntilFinished(engine)

        XCTAssertLessThanOrEqual(executor.observedMaxInFlight, 2)
        XCTAssertEqual(executor.requests.count, targets.count)
        for target in targets {
            XCTAssertEqual(engine.results[target]?.status, .succeeded)
        }
    }

    func testCancelStopsInFlightHostsAndMarksThemFailed() async throws {
        let executor = FakeRunbookProcessExecutor()
        executor.responder = { _ in .success(exitCode: 0, output: "", delay: 2.0) }

        let runbook = Runbook(name: "Cancel", steps: [RunbookStep(command: "long-running")])
        let engine = RunbookExecutionEngine(processExecuting: executor)

        engine.run(runbook: runbook, values: [:], targets: ["host-a", "host-b"], concurrencyLimit: 2)

        // Give the run a moment to actually start both hosts before cancelling.
        try await Task.sleep(nanoseconds: 100_000_000)
        engine.cancel()

        XCTAssertFalse(engine.isRunning)
        for alias in ["host-a", "host-b"] {
            guard case .failed? = engine.results[alias]?.status else {
                return XCTFail("expected \(alias) to be marked failed after cancel")
            }
        }
    }

    func testRetryFailedHostsOnlyRetriesFailedOnes() async throws {
        let executor = FakeRunbookProcessExecutor()
        executor.responder = { request in
            let alias = RunbookTestSupport.alias(in: request)
            let attempt = executor.incrementAttempt(for: alias)
            if alias == "bad-host", attempt == 1 {
                return .success(exitCode: 1, output: "boom")
            }
            return .success(exitCode: 0, output: "ok")
        }

        let runbook = Runbook(name: "Retry", steps: [RunbookStep(command: "run-thing")])
        let engine = RunbookExecutionEngine(processExecuting: executor)

        engine.run(runbook: runbook, values: [:], targets: ["bad-host", "good-host"])
        await waitUntilFinished(engine)

        guard case .failed? = engine.results["bad-host"]?.status else {
            return XCTFail("expected bad-host to fail on first attempt")
        }
        XCTAssertEqual(engine.results["good-host"]?.status, .succeeded)

        engine.retryFailedHosts()
        await waitUntilFinished(engine)

        XCTAssertEqual(engine.results["bad-host"]?.status, .succeeded)
        XCTAssertEqual(engine.results["good-host"]?.status, .succeeded)
        // good-host should not have been re-run.
        XCTAssertEqual(executor.attemptCount(for: "good-host"), 1)
        XCTAssertEqual(executor.attemptCount(for: "bad-host"), 2)
    }

    // MARK: - Helpers

    private func waitUntilFinished(_ engine: RunbookExecutionEngine, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while engine.isRunning, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

// MARK: - Fakes

private enum RunbookTestSupport {
    static func alias(in request: SSHProcessRequest) -> String? {
        // arguments: -o BatchMode=yes -o ConnectTimeout=15 -- <alias> <command>
        guard let dashDashIndex = request.arguments.firstIndex(of: "--") else { return nil }
        let aliasIndex = request.arguments.index(after: dashDashIndex)
        return request.arguments.indices.contains(aliasIndex) ? request.arguments[aliasIndex] : nil
    }

    static func command(in request: SSHProcessRequest) -> String? {
        guard let dashDashIndex = request.arguments.firstIndex(of: "--") else { return nil }
        let commandIndex = request.arguments.index(dashDashIndex, offsetBy: 2)
        return request.arguments.indices.contains(commandIndex) ? request.arguments[commandIndex] : nil
    }
}

private struct RunbookFakeResponse {
    enum Kind {
        case result(exitCode: Int32, output: String)
    }

    let kind: Kind
    let delay: TimeInterval

    static func success(exitCode: Int32 = 0, output: String = "", delay: TimeInterval = 0) -> RunbookFakeResponse {
        RunbookFakeResponse(kind: .result(exitCode: exitCode, output: output), delay: delay)
    }
}

private final class FakeRunbookProcessExecutor: SSHProcessExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [SSHProcessRequest] = []
    private var currentInFlight = 0
    private var maxInFlight = 0
    private var attemptCounts: [String: Int] = [:]

    var responder: (@Sendable (SSHProcessRequest) -> RunbookFakeResponse)?

    var requests: [SSHProcessRequest] { lock.withLock { storedRequests } }
    var observedMaxInFlight: Int { lock.withLock { maxInFlight } }

    func incrementAttempt(for alias: String?) -> Int {
        lock.withLock {
            let next = (attemptCounts[alias ?? ""] ?? 0) + 1
            attemptCounts[alias ?? ""] = next
            return next
        }
    }

    func attemptCount(for alias: String) -> Int {
        lock.withLock { attemptCounts[alias] ?? 0 }
    }

    func start(
        _ request: SSHProcessRequest,
        onOutput: @escaping @Sendable (SSHProcessStream, Data) -> Void,
        completion: @escaping @Sendable (Result<SSHProcessResult, SSHProcessClientError>) -> Void
    ) throws -> any SSHProcessTask {
        lock.withLock {
            storedRequests.append(request)
            currentInFlight += 1
            maxInFlight = max(maxInFlight, currentInFlight)
        }

        let task = FakeRunbookTask()
        let response = responder?(request) ?? .success()

        DispatchQueue.global().asyncAfter(deadline: .now() + response.delay) { [weak self] in
            self?.lock.withLock { self?.currentInFlight -= 1 }
            guard !task.isCancelled else {
                completion(.failure(.cancelled))
                return
            }
            switch response.kind {
            case let .result(exitCode, output):
                completion(.success(SSHProcessResult(
                    terminationStatus: exitCode,
                    standardOutput: output,
                    standardError: "",
                    duration: response.delay
                )))
            }
        }
        return task
    }
}

private final class FakeRunbookTask: SSHProcessTask, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}
