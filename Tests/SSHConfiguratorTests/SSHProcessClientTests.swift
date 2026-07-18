import Foundation
import XCTest
@testable import SSHConfigurator

final class SSHProcessClientTests: XCTestCase {
    func testCollectsStandardOutputWithoutShellComposition() async throws {
        let client = SSHProcessClient()
        let result = try await client.execute(SSHProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/cat"),
            arguments: [],
            environment: SSHProcessEnvironment.tool(base: [:]),
            currentDirectoryURL: nil,
            standardInput: Data("output".utf8),
            timeout: 2
        ))

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.standardOutput, "output")
        XCTAssertEqual(result.standardError, "")
        XCTAssertEqual(result.combinedOutput, "output")
    }

    func testTimesOutLongRunningProcess() async {
        let client = SSHProcessClient()

        do {
            _ = try await client.execute(SSHProcessRequest(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["2"],
                currentDirectoryURL: nil,
                timeout: 0.05
            ))
            XCTFail("Zaman aşımı bekleniyordu")
        } catch {
            XCTAssertEqual(error as? SSHProcessClientError, .timedOut(0.05))
        }
    }

    func testCancellingBeforeExecuteDoesNotStartProcess() async {
        let client = StartRecordingProcessExecutor()
        let request = SSHProcessRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [],
            currentDirectoryURL: nil
        )

        let task = Task { () -> SSHProcessClientError? in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await client.execute(request)
                return nil
            } catch {
                return error as? SSHProcessClientError
            }
        }

        let error = await task.value
        XCTAssertEqual(error, .cancelled)
        XCTAssertEqual(client.startCount, 0)
    }

    func testCancellingSwiftTaskTerminatesProcess() async {
        let client = SSHProcessClient()
        let task = Task {
            try await client.execute(SSHProcessRequest(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["2"],
                currentDirectoryURL: nil
            ))
        }
        try? await Task.sleep(for: .milliseconds(30))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("İptal hatası bekleniyordu")
        } catch {
            XCTAssertEqual(error as? SSHProcessClientError, .cancelled)
        }
    }

    func testStandardOutputIsBoundedWithoutChangingSuccessfulResultBehavior() async throws {
        let client = SSHProcessClient()
        let result = try await client.execute(SSHProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "yes x | head -c 2097152"],
            currentDirectoryURL: nil,
            timeout: 2
        ))

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.standardOutput.utf8.count, SSHProcessClient.maximumCapturedOutputBytes)
        XCTAssertEqual(result.standardError, "")
    }

    func testStandardErrorIsBoundedWithoutChangingSuccessfulResultBehavior() async throws {
        let client = SSHProcessClient()
        let result = try await client.execute(SSHProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "yes x | head -c 2097152 >&2"],
            currentDirectoryURL: nil,
            timeout: 2
        ))

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.standardOutput, "")
        XCTAssertEqual(result.standardError.utf8.count, SSHProcessClient.maximumCapturedOutputBytes)
    }

    func testAddsStableLocaleAndFallbackPath() {
        let environment = SSHProcessEnvironment.tool(base: [:])

        XCTAssertEqual(environment["LC_ALL"], "C")
        XCTAssertEqual(environment["PATH"], SSHProcessEnvironment.fallbackPath)
    }

    func testInteractiveEnvironmentPreservesUserLocale() {
        let environment = SSHProcessEnvironment.interactive(base: [
            "LANG": "tr_TR.UTF-8",
            "LC_ALL": "tr_TR.UTF-8",
            "PATH": "/custom/bin",
        ])

        XCTAssertEqual(environment["LANG"], "tr_TR.UTF-8")
        XCTAssertEqual(environment["LC_ALL"], "tr_TR.UTF-8")
        XCTAssertEqual(environment["PATH"], "/custom/bin")
    }

    func testFastProcessesWithTimeoutAlwaysFinishSuccessfully() async throws {
        let client = SSHProcessClient()

        for _ in 0 ..< 25 {
            let result = try await client.execute(SSHProcessRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                arguments: [],
                currentDirectoryURL: nil,
                timeout: 1
            ))
            XCTAssertEqual(result.terminationStatus, 0)
        }
    }

    // MARK: - Interactive-auth (SSH_ASKPASS) environment

    func testInteractiveAuthSetsAskpassEnvironmentWhenHelperIsFound() {
        let helperURL = URL(fileURLWithPath: "/Applications/Terly.app/Contents/Resources/terly-askpass.sh")

        let environment = SSHProcessEnvironment.interactiveAuth(
            base: ["PATH": "/usr/bin:/bin"],
            askpassURL: helperURL
        )

        XCTAssertEqual(environment["SSH_ASKPASS"], helperURL.path)
        XCTAssertEqual(environment["SSH_ASKPASS_REQUIRE"], "force")
        XCTAssertEqual(environment["DISPLAY"], ":0")
    }

    func testInteractiveAuthOmitsAskpassVariablesWhenHelperIsMissing() {
        let environment = SSHProcessEnvironment.interactiveAuth(
            base: ["PATH": "/usr/bin:/bin"],
            askpassURL: nil
        )

        XCTAssertNil(environment["SSH_ASKPASS"])
        XCTAssertNil(environment["SSH_ASKPASS_REQUIRE"])
        XCTAssertNil(environment["DISPLAY"])
    }

    func testInteractiveAuthNeverSetsBatchMode() {
        // interactiveAuth is a drop-in replacement for BatchMode=yes call
        // sites — nothing about it should re-introduce BatchMode.
        let environment = SSHProcessEnvironment.interactiveAuth(base: [:], askpassURL: nil)
        XCTAssertNil(environment["BatchMode"])
    }
}

private final class StartRecordingProcessExecutor: SSHProcessExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var startCount = 0

    @discardableResult
    func start(
        _: SSHProcessRequest,
        onOutput _: @escaping @Sendable (SSHProcessStream, Data) -> Void,
        completion _: @escaping @Sendable (Result<SSHProcessResult, SSHProcessClientError>) -> Void
    ) throws -> any SSHProcessTask {
        lock.withLock { startCount += 1 }
        return NoOpProcessTask()
    }
}

private final class NoOpProcessTask: SSHProcessTask, @unchecked Sendable {
    func cancel() {}
}
