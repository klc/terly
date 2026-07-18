import Foundation
import XCTest
@testable import SSHConfigurator

final class ChecksumVerifierTests: XCTestCase {
    private let localDigest = "aaaa1111bbbb2222cccc3333dddd4444eeee5555ffff6666aaaa1111bbbb2222"

    func testMatchingDigestsReportVerified() async {
        let executor = FakeChecksumProcessExecutor(
            localOutput: "\(localDigest)  /local/report.txt\n",
            remoteOutput: "\(localDigest)  /remote/report.txt\n"
        )
        let verifier = TransferChecksumVerifier(processClient: executor)

        let state = await verifier.verify(
            localURL: URL(fileURLWithPath: "/local/report.txt"),
            alias: "prod-api",
            remotePath: "/remote/report.txt"
        )

        XCTAssertEqual(state, .verified)
    }

    func testDifferingDigestsReportMismatch() async {
        let executor = FakeChecksumProcessExecutor(
            localOutput: "\(localDigest)  /local/report.txt\n",
            remoteOutput: "0000000000000000000000000000000000000000000000000000000000000000  /remote/report.txt\n"
        )
        let verifier = TransferChecksumVerifier(processClient: executor)

        let state = await verifier.verify(
            localURL: URL(fileURLWithPath: "/local/report.txt"),
            alias: "prod-api",
            remotePath: "/remote/report.txt"
        )

        XCTAssertEqual(state, .mismatch)
    }

    func testMissingRemoteToolReportsUnavailableNotError() async {
        let executor = FakeChecksumProcessExecutor(
            localOutput: "\(localDigest)  /local/report.txt\n",
            remoteOutput: "SSHCFG_CHECKSUM_UNAVAILABLE\n"
        )
        let verifier = TransferChecksumVerifier(processClient: executor)

        let state = await verifier.verify(
            localURL: URL(fileURLWithPath: "/local/report.txt"),
            alias: "prod-api",
            remotePath: "/remote/report.txt"
        )

        guard case .unavailable = state else {
            XCTFail("Expected .unavailable, got \(state)")
            return
        }
    }

    func testRemoteConnectionFailureReportsUnavailableNotError() async {
        let executor = FakeChecksumProcessExecutor(
            localOutput: "\(localDigest)  /local/report.txt\n",
            remoteOutput: "",
            remoteExitStatus: 255
        )
        let verifier = TransferChecksumVerifier(processClient: executor)

        let state = await verifier.verify(
            localURL: URL(fileURLWithPath: "/local/report.txt"),
            alias: "prod-api",
            remotePath: "/remote/report.txt"
        )

        guard case .unavailable = state else {
            XCTFail("Expected .unavailable, got \(state)")
            return
        }
    }

    func testRemoteScriptSingleQuotesPathInsteadOfConcatenatingRawShellText() {
        let script = TransferChecksumVerifier.remoteScript(for: "/tmp/O'Brien's file.txt")

        // The path must appear inside a POSIX single-quoted literal with the
        // embedded quote escaped via '"'"' — never spliced in unescaped.
        XCTAssertTrue(script.contains("'/tmp/O'\"'\"'Brien'\"'\"'s file.txt'"))
        XCTAssertFalse(script.contains("/tmp/O'Brien's file.txt'\n"))
    }

    func testRemoteScriptTriesShasumThenSha256sumThenReportsMarker() {
        let script = TransferChecksumVerifier.remoteScript(for: "/tmp/report.txt")

        XCTAssertTrue(script.contains("command -v shasum"))
        XCTAssertTrue(script.contains("shasum -a 256"))
        XCTAssertTrue(script.contains("command -v sha256sum"))
        XCTAssertTrue(script.contains("sha256sum --"))
        XCTAssertTrue(script.contains("SSHCFG_CHECKSUM_UNAVAILABLE"))
    }

    func testRemotePathIsPassedAsSingleArgvElementNotJoinedIntoSSHArguments() async throws {
        let executor = FakeChecksumProcessExecutor(
            localOutput: "\(localDigest)  /local/report.txt\n",
            remoteOutput: "\(localDigest)  /remote/report.txt\n"
        )
        let verifier = TransferChecksumVerifier(processClient: executor)

        _ = await verifier.verify(
            localURL: URL(fileURLWithPath: "/local/report.txt"),
            alias: "prod-api",
            remotePath: "/remote/report.txt"
        )

        let sshRequest = try XCTUnwrap(executor.requests.first { $0.executableURL.lastPathComponent == "ssh" })
        // alias and the fully-built script are the last two argv elements —
        // ssh never receives raw unquoted path fragments as separate args.
        XCTAssertEqual(sshRequest.arguments.suffix(2).first, "prod-api")
        XCTAssertTrue(sshRequest.arguments.last?.contains("/remote/report.txt") ?? false)
    }
}

// MARK: - Fake

private final class FakeChecksumProcessExecutor: SSHProcessExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [SSHProcessRequest] = []
    private let localOutput: String
    private let remoteOutput: String
    private let remoteExitStatus: Int32

    var requests: [SSHProcessRequest] { lock.withLock { storedRequests } }

    init(localOutput: String, remoteOutput: String, remoteExitStatus: Int32 = 0) {
        self.localOutput = localOutput
        self.remoteOutput = remoteOutput
        self.remoteExitStatus = remoteExitStatus
    }

    func start(
        _ request: SSHProcessRequest,
        onOutput: @escaping @Sendable (SSHProcessStream, Data) -> Void,
        completion: @escaping @Sendable (Result<SSHProcessResult, SSHProcessClientError>) -> Void
    ) throws -> any SSHProcessTask {
        lock.withLock { storedRequests.append(request) }
        let result: SSHProcessResult
        switch request.executableURL.lastPathComponent {
        case "shasum":
            result = SSHProcessResult(
                terminationStatus: 0,
                standardOutput: localOutput,
                standardError: "",
                duration: 0.001
            )
        case "ssh":
            result = SSHProcessResult(
                terminationStatus: remoteExitStatus,
                standardOutput: remoteOutput,
                standardError: "",
                duration: 0.001
            )
        default:
            result = SSHProcessResult(terminationStatus: 1, standardOutput: "", standardError: "unexpected", duration: 0)
        }
        completion(.success(result))
        return FakeChecksumProcessTask()
    }
}

private final class FakeChecksumProcessTask: SSHProcessTask, @unchecked Sendable {
    func cancel() {}
}
