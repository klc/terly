import Foundation
import SSHConfigCore
import XCTest
@testable import SSHConfigurator

final class SSHConnectionDiagnosticsTests: XCTestCase {
    func testResolvedConfigPreservesRepeatedValues() {
        let config = SSHResolvedConfig(output: """
        hostname prod.example.com
        port 2222
        identityfile ~/.ssh/id_ed25519
        identityfile ~/.ssh/id_rsa
        """)

        XCTAssertEqual(config.firstValue(for: "hostname"), "prod.example.com")
        XCTAssertEqual(config.values(for: "identityfile"), ["~/.ssh/id_ed25519", "~/.ssh/id_rsa"])
    }

    func testDiagnosticsUsesStrictHostCheckingAndReportsResolvedSource() async throws {
        let executor = FakeDiagnosticProcessExecutor()
        let diagnostics = SSHConnectionDiagnostics(
            processClient: executor,
            environment: ["PATH": "/usr/bin:/bin"],
            stepTimeout: 1
        )
        let document = SSHConfigDocument(source: """
        Host prod
          HostName prod.example.com
          User deploy
          Port 2222
        """)

        let report = await diagnostics.diagnose(alias: "prod", document: document)

        XCTAssertFalse(report.hasFailures)
        XCTAssertEqual(report.checks.first(where: { $0.id == "dns" })?.status, .passed)
        XCTAssertEqual(report.checks.first(where: { $0.id == "known-hosts" })?.status, .passed)
        XCTAssertEqual(report.checks.first(where: { $0.id == "connection" })?.status, .passed)
        XCTAssertEqual(
            report.resolvedSettings.first(where: { $0.key == "hostname" })?.source,
            "Host prod, satır 2"
        )

        let requests = executor.requests
        let connectionRequest = try XCTUnwrap(requests.first { request in
            request.executableURL.lastPathComponent == "ssh" && request.arguments.contains("-T")
        })
        XCTAssertTrue(connectionRequest.arguments.contains("StrictHostKeyChecking=yes"))
        XCTAssertTrue(connectionRequest.arguments.contains("PermitLocalCommand=no"))
        XCTAssertTrue(connectionRequest.arguments.contains("RemoteCommand=none"))
        XCTAssertTrue(connectionRequest.arguments.contains("ClearAllForwardings=yes"))
        XCTAssertTrue(connectionRequest.arguments.contains("KnownHostsCommand=none"))
        XCTAssertFalse(connectionRequest.arguments.contains("accept-new"))
        XCTAssertFalse(connectionRequest.arguments.contains("StrictHostKeyChecking=no"))
    }

    func testRedactedReportHidesUsersLocalPathsAndCommands() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let localUser = NSUserName()
        let report = SSHDiagnosticReport(
            alias: "prod",
            createdAt: Date(timeIntervalSince1970: 0),
            checks: [SSHDiagnosticCheck(
                id: "example",
                title: "Örnek",
                status: .failed,
                summary: "Yerel kullanıcı \(localUser)",
                detail: "\(home)/.ssh/config"
            )],
            resolvedSettings: [
                SSHResolvedSetting(id: "0-user", key: "user", value: "deploy", source: "Host prod, satır 2"),
                SSHResolvedSetting(id: "1-identity", key: "identityfile", value: "\(home)/.ssh/id_ed25519", source: "Host prod, satır 3"),
                SSHResolvedSetting(id: "2-proxy", key: "proxycommand", value: "ssh secret-jump -W %h:%p", source: "Host prod, satır 4"),
            ]
        )

        let text = report.redactedText

        XCTAssertFalse(text.contains(home))
        if !localUser.isEmpty { XCTAssertFalse(text.contains(localUser)) }
        XCTAssertFalse(text.contains("deploy"))
        XCTAssertFalse(text.contains("secret-jump"))
        XCTAssertTrue(text.contains("<yerel-yol>"))
        XCTAssertTrue(text.contains("<redakte>"))
    }

    func testResolvedSourceHonorsEarlierWildcardHostBlock() async {
        let executor = FakeDiagnosticProcessExecutor()
        let diagnostics = SSHConnectionDiagnostics(
            processClient: executor,
            environment: ["PATH": "/usr/bin:/bin"],
            stepTimeout: 1
        )
        let document = SSHConfigDocument(source: """
        Host *
          User common-user

        Host prod
          User deploy
        """)

        let report = await diagnostics.diagnose(alias: "prod", document: document)

        XCTAssertEqual(
            report.resolvedSettings.first(where: { $0.key == "user" })?.source,
            "Host *, satır 2"
        )
    }

    func testIncludeAndMatchExecRequireExplicitConfigEvaluationApproval() {
        let plain = SSHDiagnosticsExecutionPolicy(document: SSHConfigDocument(source: "Host prod\n  HostName example.com\n"))
        let included = SSHDiagnosticsExecutionPolicy(document: SSHConfigDocument(source: "Include ~/.ssh/conf.d/*\nHost prod\n"))
        let matchExec = SSHDiagnosticsExecutionPolicy(document: SSHConfigDocument(source: "Match exec \"test -f /tmp/ready\"\n  User deploy\n"))

        XCTAssertFalse(plain.requiresExplicitConfigEvaluationApproval)
        XCTAssertTrue(included.requiresExplicitConfigEvaluationApproval)
        XCTAssertTrue(included.riskDescription?.contains("Include") == true)
        XCTAssertTrue(matchExec.requiresExplicitConfigEvaluationApproval)
        XCTAssertTrue(matchExec.riskDescription?.contains("Match exec") == true)
    }

    func testProxyCommandSkipsAutomaticEndToEndConnection() async {
        let executor = FakeDiagnosticProcessExecutor(effectiveOutput: """
        hostname prod.example.com
        user deploy
        port 2222
        proxyjump none
        proxycommand /usr/local/bin/custom-proxy %h %p
        """)
        let diagnostics = SSHConnectionDiagnostics(
            processClient: executor,
            environment: ["PATH": "/usr/bin:/bin"],
            stepTimeout: 1
        )

        let report = await diagnostics.diagnose(
            alias: "prod",
            document: SSHConfigDocument(source: "Host prod\n  HostName prod.example.com\n")
        )

        XCTAssertFalse(executor.requests.contains { $0.executableURL.lastPathComponent == "ssh" && $0.arguments.contains("-T") })
        XCTAssertEqual(report.checks.first(where: { $0.id == "connection" })?.status, .warning)
        XCTAssertTrue(report.checks.first(where: { $0.id == "connection" })?.summary.contains("ProxyCommand") == true)
    }

    func testProxyJumpStillRunsHardenedEndToEndConnection() async throws {
        let executor = FakeDiagnosticProcessExecutor(effectiveOutput: """
        hostname prod.example.com
        user deploy
        port 2222
        proxyjump jump-host
        """)
        let diagnostics = SSHConnectionDiagnostics(processClient: executor, stepTimeout: 1)

        _ = await diagnostics.diagnose(
            alias: "prod",
            document: SSHConfigDocument(source: "Host prod\n  ProxyJump jump-host\n")
        )

        let request = try XCTUnwrap(executor.requests.first {
            $0.executableURL.lastPathComponent == "ssh" && $0.arguments.contains("-T")
        })
        XCTAssertTrue(request.arguments.contains("ClearAllForwardings=yes"))
    }

    func testCustomKnownHostsFilesArePassedWithFileArguments() async {
        let executor = FakeDiagnosticProcessExecutor(effectiveOutput: """
        hostname prod.example.com
        user deploy
        port 2222
        proxyjump none
        userknownhostsfile ~/.ssh/known_hosts_custom ~/.ssh/known_hosts_backup
        """)
        let diagnostics = SSHConnectionDiagnostics(
            processClient: executor,
            environment: ["PATH": "/usr/bin:/bin"],
            stepTimeout: 1
        )

        _ = await diagnostics.diagnose(
            alias: "prod",
            document: SSHConfigDocument(source: "Host prod\n  HostName prod.example.com\n")
        )

        let lookups = executor.requests.filter {
            $0.executableURL.lastPathComponent == "ssh-keygen" && $0.arguments.contains("-F")
        }
        XCTAssertEqual(lookups.count, 2)
        XCTAssertTrue(lookups.allSatisfy { $0.arguments.contains("-f") })
        XCTAssertTrue(lookups.contains { $0.arguments.contains(where: { $0.hasSuffix("/.ssh/known_hosts_custom") }) })
        XCTAssertTrue(lookups.contains { $0.arguments.contains(where: { $0.hasSuffix("/.ssh/known_hosts_backup") }) })
    }

    func testUnresolvedKnownHostsAndIdentityTokensProduceWarningsWithoutFalseMissingResult() async {
        let executor = FakeDiagnosticProcessExecutor(effectiveOutput: """
        hostname prod.example.com
        user deploy
        port 2222
        proxyjump none
        identityfile ~/.ssh/%C/id_ed25519
        userknownhostsfile ~/.ssh/known_hosts_%C
        """)
        let diagnostics = SSHConnectionDiagnostics(
            processClient: executor,
            environment: ["PATH": "/usr/bin:/bin"],
            stepTimeout: 1
        )

        let report = await diagnostics.diagnose(
            alias: "prod",
            document: SSHConfigDocument(source: "Host prod\n  HostName prod.example.com\n")
        )

        let identity = report.checks.first { $0.id == "identity-0" }
        let knownHosts = report.checks.first { $0.id == "known-hosts-0" }
        XCTAssertEqual(identity?.status, .warning)
        XCTAssertTrue(identity?.summary.contains("token") == true)
        XCTAssertEqual(knownHosts?.status, .warning)
        XCTAssertTrue(knownHosts?.summary.contains("çözülemedi") == true)
        XCTAssertFalse(executor.requests.contains { $0.executableURL.lastPathComponent == "ssh-keygen" && $0.arguments.contains("-F") })
    }

    func testResolvedSettingIDsStayUniqueForDuplicateValues() async {
        let executor = FakeDiagnosticProcessExecutor(effectiveOutput: """
        hostname prod.example.com
        user deploy
        port 2222
        proxyjump none
        identityfile ~/.ssh/%C/key
        identityfile ~/.ssh/%C/key
        """)
        let diagnostics = SSHConnectionDiagnostics(processClient: executor, stepTimeout: 1)

        let report = await diagnostics.diagnose(
            alias: "prod",
            document: SSHConfigDocument(source: "Host prod\n")
        )
        let duplicateSettings = report.resolvedSettings.filter { $0.key == "identityfile" }

        XCTAssertEqual(duplicateSettings.count, 2)
        XCTAssertEqual(Set(duplicateSettings.map(\.id)).count, 2)
    }

    func testCancellationStopsBeforeStartingAnotherDiagnosticRequest() async {
        let executor = CancellableDiagnosticProcessExecutor()
        let diagnostics = SSHConnectionDiagnostics(processClient: executor, stepTimeout: 10)
        let task = Task {
            await diagnostics.diagnose(
                alias: "prod",
                document: SSHConfigDocument(source: "Host prod\n  HostName prod.example.com\n")
            )
        }

        while executor.requests.count < 2 { await Task.yield() }
        task.cancel()
        let report = await task.value

        XCTAssertEqual(executor.requests.count, 2)
        XCTAssertTrue(report.checks.contains { $0.summary == "İşlem iptal edildi" })
    }

    func testPathExpansionSupportsKnownTokensAndReportsUnknownTokens() {
        let context = SSHPathExpansionContext(
            homeDirectory: "/Users/local",
            hostname: "prod.example.com",
            port: "2222",
            remoteUser: "deploy",
            originalHost: "prod"
        )

        XCTAssertEqual(
            SSHPathTokenExpander.expand("~/.ssh/%r@%h-%p-%n-%%", context: context).expandedPath,
            "/Users/local/.ssh/deploy@prod.example.com-2222-prod-%"
        )
        XCTAssertEqual(
            SSHPathTokenExpander.expand("~/.ssh/%C", context: context).unresolvedTokens,
            ["%C"]
        )
        XCTAssertEqual(
            SSHConfigValueTokenizer.tokens("\"/tmp/known hosts\" /tmp/known\\ hosts-2"),
            ["/tmp/known hosts", "/tmp/known hosts-2"]
        )
    }
}

private final class FakeDiagnosticProcessExecutor: SSHProcessExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [SSHProcessRequest] = []
    private let effectiveOutput: String

    init(effectiveOutput: String = "hostname prod.example.com\nuser deploy\nport 2222\nproxyjump none\n") {
        self.effectiveOutput = effectiveOutput
    }

    var requests: [SSHProcessRequest] {
        lock.withLock { storedRequests }
    }

    func start(
        _ request: SSHProcessRequest,
        onOutput: @escaping @Sendable (SSHProcessStream, Data) -> Void,
        completion: @escaping @Sendable (Result<SSHProcessResult, SSHProcessClientError>) -> Void
    ) throws -> any SSHProcessTask {
        lock.withLock { storedRequests.append(request) }
        let result: SSHProcessResult
        switch (request.executableURL.lastPathComponent, request.arguments) {
        case ("ssh", let arguments) where arguments.contains("-G"):
            result = processResult(
                output: effectiveOutput,
                error: "debug1: Reading configuration data /Users/test/.ssh/config\n"
            )
        case ("dscacheutil", _):
            result = processResult(output: "name: prod.example.com\nip_address: 192.0.2.10\n")
        case ("nc", _):
            result = processResult()
        case ("ssh-add", _):
            result = processResult(output: "256 SHA256:example test@example (ED25519)\n")
        case ("ssh-keygen", let arguments) where arguments.contains("-F"):
            result = processResult(output: "[prod.example.com]:2222 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAExample\n")
        case ("ssh-keygen", let arguments) where arguments.contains("-lf"):
            result = processResult(output: "256 SHA256:fingerprint [prod.example.com]:2222 (ED25519)\n")
        case ("ssh", let arguments) where arguments.contains("-T"):
            result = processResult()
        default:
            result = processResult(status: 1, error: "unexpected request")
        }
        completion(.success(result))
        return FakeDiagnosticProcessTask()
    }

    private func processResult(
        status: Int32 = 0,
        output: String = "",
        error: String = ""
    ) -> SSHProcessResult {
        SSHProcessResult(
            terminationStatus: status,
            standardOutput: output,
            standardError: error,
            duration: 0.01
        )
    }
}

private final class FakeDiagnosticProcessTask: SSHProcessTask, @unchecked Sendable {
    func cancel() {}
}

private final class CancellableDiagnosticProcessExecutor: SSHProcessExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [SSHProcessRequest] = []

    var requests: [SSHProcessRequest] { lock.withLock { storedRequests } }

    func start(
        _ request: SSHProcessRequest,
        onOutput: @escaping @Sendable (SSHProcessStream, Data) -> Void,
        completion: @escaping @Sendable (Result<SSHProcessResult, SSHProcessClientError>) -> Void
    ) throws -> any SSHProcessTask {
        lock.withLock { storedRequests.append(request) }
        if request.executableURL.lastPathComponent == "ssh", request.arguments.contains("-G") {
            completion(.success(SSHProcessResult(
                terminationStatus: 0,
                standardOutput: "hostname prod.example.com\nuser deploy\nport 22\nproxyjump none\n",
                standardError: "",
                duration: 0
            )))
            return FakeDiagnosticProcessTask()
        }
        return CompletingCancellationProcessTask(completion: completion)
    }
}

private final class CompletingCancellationProcessTask: SSHProcessTask, @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable (Result<SSHProcessResult, SSHProcessClientError>) -> Void)?

    init(completion: @escaping @Sendable (Result<SSHProcessResult, SSHProcessClientError>) -> Void) {
        self.completion = completion
    }

    func cancel() {
        let completion = lock.withLock {
            defer { self.completion = nil }
            return self.completion
        }
        completion?(.failure(.cancelled))
    }
}
