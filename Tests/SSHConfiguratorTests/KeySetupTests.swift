import Foundation
import SSHConfigCore
import XCTest
@testable import SSHConfigurator

// MARK: - Path derivation

final class KeySetupPathDeriverTests: XCTestCase {
    func testSanitizesAliasForFilename() {
        XCTAssertEqual(KeySetupPathDeriver.sanitizedFilenameComponent(for: "prod-api"), "prod-api")
        XCTAssertEqual(KeySetupPathDeriver.sanitizedFilenameComponent(for: "db.example.com"), "db.example.com")
    }

    func testSanitizesSpacesSlashesAndShellMetacharacters() {
        XCTAssertEqual(
            KeySetupPathDeriver.sanitizedFilenameComponent(for: "my server; rm -rf /"),
            "my_server__rm_-rf__"
        )
        XCTAssertEqual(
            KeySetupPathDeriver.sanitizedFilenameComponent(for: "../../etc/passwd"),
            ".._.._etc_passwd"
        )
        XCTAssertFalse(KeySetupPathDeriver.sanitizedFilenameComponent(for: "a/b").contains("/"))
    }

    func testEmptyAliasFallsBackToNonEmptyComponent() {
        XCTAssertFalse(KeySetupPathDeriver.sanitizedFilenameComponent(for: "").isEmpty)
    }

    func testDefaultPrivateKeyPathIsUnderDotSSH() {
        let home = URL(fileURLWithPath: "/Users/tester")
        let path = KeySetupPathDeriver.defaultPrivateKeyPath(alias: "prod-api", homeDirectory: home)
        XCTAssertEqual(path, "/Users/tester/.ssh/id_ed25519_prod-api")
    }

    func testDefaultPrivateKeyPathSanitizesAliasWithSpaces() {
        let home = URL(fileURLWithPath: "/Users/tester")
        let path = KeySetupPathDeriver.defaultPrivateKeyPath(alias: "my server", homeDirectory: home)
        XCTAssertEqual(path, "/Users/tester/.ssh/id_ed25519_my_server")
    }

    func testDefaultCommentIsUserAtAlias() {
        XCTAssertEqual(
            KeySetupPathDeriver.defaultComment(alias: "prod-api", userName: "klc"),
            "klc@prod-api"
        )
    }
}

// MARK: - Command argument construction

final class KeySetupCommandBuilderTests: XCTestCase {
    func testKeygenArgumentsAreSeparateArgvElements() {
        let arguments = KeySetupCommandBuilder.keygenArguments(
            privateKeyPath: "/Users/tester/.ssh/id_ed25519_prod api",
            comment: "klc@prod api"
        )
        XCTAssertEqual(arguments, [
            "-t", "ed25519",
            "-f", "/Users/tester/.ssh/id_ed25519_prod api",
            "-C", "klc@prod api",
        ])
    }

    func testSSHAddArgumentsAreOnlyThePath() {
        XCTAssertEqual(
            KeySetupCommandBuilder.sshAddArguments(privateKeyPath: "/Users/tester/.ssh/id_ed25519_prod"),
            ["/Users/tester/.ssh/id_ed25519_prod"]
        )
    }

    func testCopyArgumentsPlaceAliasAfterDashDashAndUseFixedScript() {
        let arguments = KeySetupCommandBuilder.copyArguments(alias: "prod-api")
        XCTAssertEqual(arguments, [
            "--", "prod-api",
            "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys",
        ])
    }

    func testCopyArgumentsWithAliasContainingSpecialCharactersStayAsOneArgvElement() {
        // The alias comes straight from a Host pattern (already validated as
        // concrete elsewhere); this just proves it is never woven into the
        // remote script string, so no quoting is needed for it.
        let arguments = KeySetupCommandBuilder.copyArguments(alias: "weird's-host")
        XCTAssertEqual(arguments[1], "weird's-host")
        XCTAssertFalse(arguments[2].contains("weird"))
    }

    func testVerifyArgumentsUseBatchModeAndTrueCommand() {
        XCTAssertEqual(
            KeySetupCommandBuilder.verifyArguments(alias: "prod-api"),
            ["-o", "BatchMode=yes", "--", "prod-api", "true"]
        )
    }
}

// MARK: - KeySetupEngine

@MainActor
final class KeySetupEngineTests: XCTestCase {
    func testGenerateKeySendsExactArgumentsAndNoStdinWhenFileDoesNotExist() async throws {
        let (directory, privateKeyPath) = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let executor = FakeKeySetupProcessExecutor()
        let engine = KeySetupEngine(processClient: executor, interactiveEnvironment: ["MARK": "interactive"])

        await engine.generateKey(privateKeyPath: privateKeyPath, comment: "klc@prod-api", overwriteConfirmed: false)

        XCTAssertEqual(engine.generateState, .succeeded)
        let request = try XCTUnwrap(executor.requests.first)
        XCTAssertEqual(request.executableURL.path, "/usr/bin/ssh-keygen")
        XCTAssertEqual(request.arguments, KeySetupCommandBuilder.keygenArguments(
            privateKeyPath: privateKeyPath,
            comment: "klc@prod-api"
        ))
        XCTAssertNil(request.standardInput)
        XCTAssertEqual(request.environment, ["MARK": "interactive"])
    }

    func testGenerateKeyRefusesOverwriteWithoutConfirmationAndNeverLaunchesProcess() async throws {
        let (directory, privateKeyPath) = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("existing".utf8).write(to: URL(fileURLWithPath: privateKeyPath))

        let executor = FakeKeySetupProcessExecutor()
        let engine = KeySetupEngine(processClient: executor)

        await engine.generateKey(privateKeyPath: privateKeyPath, comment: "c", overwriteConfirmed: false)

        guard case .failed = engine.generateState else {
            XCTFail("Expected overwrite to be refused, got \(engine.generateState)")
            return
        }
        XCTAssertTrue(executor.requests.isEmpty, "ssh-keygen must never run without explicit overwrite confirmation")
    }

    func testGenerateKeyFeedsYesOnStdinWhenOverwriteConfirmed() async throws {
        let (directory, privateKeyPath) = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("existing".utf8).write(to: URL(fileURLWithPath: privateKeyPath))

        let executor = FakeKeySetupProcessExecutor()
        let engine = KeySetupEngine(processClient: executor)

        await engine.generateKey(privateKeyPath: privateKeyPath, comment: "c", overwriteConfirmed: true)

        XCTAssertEqual(engine.generateState, .succeeded)
        let request = try XCTUnwrap(executor.requests.first)
        XCTAssertEqual(request.standardInput, Data("y\n".utf8))
    }

    func testReadPublicKeyReadsOnlyTheDotPubFileNeverThePrivateKey() throws {
        let (directory, privateKeyPath) = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data("PRIVATE-KEY-SECRET-MATERIAL".utf8).write(to: URL(fileURLWithPath: privateKeyPath))
        try Data("ssh-ed25519 AAAA-PUBLIC-ONLY comment\n".utf8)
            .write(to: URL(fileURLWithPath: privateKeyPath + ".pub"))

        let engine = KeySetupEngine(processClient: FakeKeySetupProcessExecutor())
        let text = try engine.readPublicKey(privateKeyPath: privateKeyPath)

        XCTAssertEqual(text, "ssh-ed25519 AAAA-PUBLIC-ONLY comment\n")
        XCTAssertFalse(text.contains("PRIVATE-KEY-SECRET-MATERIAL"))
    }

    func testReadPublicKeyThrowsInsteadOfFallingBackToPrivateKeyWhenPubMissing() throws {
        let (directory, privateKeyPath) = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("PRIVATE-KEY-SECRET-MATERIAL".utf8).write(to: URL(fileURLWithPath: privateKeyPath))
        // Deliberately no .pub file written.

        let engine = KeySetupEngine(processClient: FakeKeySetupProcessExecutor())
        XCTAssertThrowsError(try engine.readPublicKey(privateKeyPath: privateKeyPath)) { error in
            XCTAssertEqual(error as? KeySetupError, .publicKeyMissing)
        }
    }

    func testGenerateKeyPopulatesPublicKeyPreviewFromPubFileOnly() async throws {
        let (directory, privateKeyPath) = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Simulate what ssh-keygen would have written to disk (the fake
        // executor itself performs no I/O, so the test pre-creates the pair
        // to prove the engine reads the .pub companion afterwards).
        try Data("PRIVATE-KEY-SECRET-MATERIAL".utf8).write(to: URL(fileURLWithPath: privateKeyPath))
        try Data("ssh-ed25519 AAAA-GENERATED comment\n".utf8)
            .write(to: URL(fileURLWithPath: privateKeyPath + ".pub"))

        let engine = KeySetupEngine(processClient: FakeKeySetupProcessExecutor())
        // The private key file already exists on disk (standing in for what
        // ssh-keygen would have just written), so this requires
        // overwriteConfirmed: true — otherwise generateKey would correctly
        // refuse to run at all.
        await engine.generateKey(privateKeyPath: privateKeyPath, comment: "c", overwriteConfirmed: true)

        XCTAssertEqual(engine.publicKeyPreview, "ssh-ed25519 AAAA-GENERATED comment\n")
    }

    func testAddToAgentSendsOnlyThePathAsArgument() async throws {
        let executor = FakeKeySetupProcessExecutor()
        let engine = KeySetupEngine(processClient: executor)

        await engine.addToAgent(privateKeyPath: "/Users/tester/.ssh/id_ed25519_prod")

        XCTAssertEqual(engine.agentAddState, .succeeded)
        let request = try XCTUnwrap(executor.requests.first)
        XCTAssertEqual(request.executableURL.path, "/usr/bin/ssh-add")
        XCTAssertEqual(request.arguments, ["/Users/tester/.ssh/id_ed25519_prod"])
    }

    func testCopyPublicKeyStreamsTextOverStdinAndAppendsTrailingNewline() async throws {
        let executor = FakeKeySetupProcessExecutor()
        let engine = KeySetupEngine(processClient: executor, interactiveEnvironment: ["MARK": "interactive"])

        await engine.copyPublicKey(alias: "prod-api", publicKeyText: "ssh-ed25519 AAAA test")

        XCTAssertEqual(engine.copyState, .succeeded)
        let request = try XCTUnwrap(executor.requests.first)
        XCTAssertEqual(request.executableURL.path, "/usr/bin/ssh")
        XCTAssertEqual(request.arguments, KeySetupCommandBuilder.copyArguments(alias: "prod-api"))
        XCTAssertEqual(request.standardInput, Data("ssh-ed25519 AAAA test\n".utf8))
        XCTAssertEqual(request.environment, ["MARK": "interactive"])
    }

    func testCopyPublicKeyDoesNotDuplicateExistingTrailingNewline() async throws {
        let executor = FakeKeySetupProcessExecutor()
        let engine = KeySetupEngine(processClient: executor)

        await engine.copyPublicKey(alias: "prod-api", publicKeyText: "ssh-ed25519 AAAA test\n")

        let request = try XCTUnwrap(executor.requests.first)
        XCTAssertEqual(request.standardInput, Data("ssh-ed25519 AAAA test\n".utf8))
    }

    func testCopyPublicKeyFailureReportsCombinedOutput() async throws {
        let executor = FakeKeySetupProcessExecutor()
        executor.responder = { _ in .failure(status: 1, error: "Permission denied (publickey).") }
        let engine = KeySetupEngine(processClient: executor)

        await engine.copyPublicKey(alias: "prod-api", publicKeyText: "ssh-ed25519 AAAA test")

        guard case let .failed(message) = engine.copyState else {
            XCTFail("Expected failure, got \(engine.copyState)")
            return
        }
        XCTAssertTrue(message.contains("Permission denied"))
    }

    func testVerifyUsesBatchModeEnvironmentNotInteractiveEnvironment() async throws {
        let executor = FakeKeySetupProcessExecutor()
        let engine = KeySetupEngine(
            processClient: executor,
            interactiveEnvironment: ["MARK": "interactive"],
            batchEnvironment: ["MARK": "batch"]
        )

        await engine.verifyPasswordlessLogin(alias: "prod-api")

        XCTAssertEqual(engine.verifyState, .succeeded)
        let request = try XCTUnwrap(executor.requests.first)
        XCTAssertEqual(request.arguments, ["-o", "BatchMode=yes", "--", "prod-api", "true"])
        XCTAssertEqual(request.environment, ["MARK": "batch"])
    }

    // MARK: - Helpers

    private func makeTempDirectory() throws -> (directory: URL, privateKeyPath: String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("key-setup-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let privateKeyPath = directory.appendingPathComponent("id_ed25519_test").path
        return (directory, privateKeyPath)
    }
}

// MARK: - Diagnostics integration (agent-missing + permission-denied suggestion)

final class KeySetupDiagnosticsSuggestionTests: XCTestCase {
    func testSuggestsKeySetupWhenAgentWarningAndPermissionDeniedBothPresent() {
        let report = SSHDiagnosticReport(
            alias: "prod-api",
            createdAt: Date(),
            checks: [
                SSHDiagnosticCheck(id: "agent", title: "SSH agent", status: .warning, summary: "Agent boş.", detail: nil),
                SSHDiagnosticCheck(id: "connection", title: "Bağlantı", status: .failed, summary: "Authentication rejected", detail: nil),
            ],
            resolvedSettings: []
        )
        XCTAssertTrue(report.suggestsKeySetup)
    }

    func testDoesNotSuggestWhenOnlyAgentWarningPresent() {
        let report = SSHDiagnosticReport(
            alias: "prod-api",
            createdAt: Date(),
            checks: [
                SSHDiagnosticCheck(id: "agent", title: "SSH agent", status: .warning, summary: "Agent boş.", detail: nil),
                SSHDiagnosticCheck(id: "connection", title: "Bağlantı", status: .passed, summary: "OK", detail: nil),
            ],
            resolvedSettings: []
        )
        XCTAssertFalse(report.suggestsKeySetup)
    }

    func testDoesNotSuggestWhenOnlyPermissionDeniedPresent() {
        let report = SSHDiagnosticReport(
            alias: "prod-api",
            createdAt: Date(),
            checks: [
                SSHDiagnosticCheck(id: "agent", title: "SSH agent", status: .passed, summary: "1 anahtar.", detail: nil),
                SSHDiagnosticCheck(id: "connection", title: "Bağlantı", status: .failed, summary: "Authentication rejected", detail: nil),
            ],
            resolvedSettings: []
        )
        XCTAssertFalse(report.suggestsKeySetup)
    }
}

// MARK: - ConfigViewModel.updateIdentityFile

@MainActor
final class ConfigViewModelIdentityFileTests: XCTestCase {
    func testUpdateIdentityFileWritesThroughToDisk() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("key-setup-config-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let configURL = directory.appendingPathComponent("config")
        try Data("Host prod-api\n    HostName prod.example.com\n".utf8).write(to: configURL)

        let model = ConfigViewModel(
            configURL: configURL,
            store: SSHConfigFileStore(backupDirectory: directory.appendingPathComponent("backups")),
            connectionGroupStore: ConnectionGroupStore(fileURL: directory.appendingPathComponent("groups.json"))
        )
        model.load()

        let host = try XCTUnwrap(model.hosts.first)
        let succeeded = model.updateIdentityFile(for: host, path: "/Users/tester/.ssh/id_ed25519_prod-api")
        XCTAssertTrue(succeeded)

        let updatedHost = try XCTUnwrap(model.hosts.first)
        XCTAssertEqual(
            model.document?.directiveValue(named: "IdentityFile", in: updatedHost),
            "/Users/tester/.ssh/id_ed25519_prod-api"
        )

        // Write-through: reload straight from disk and confirm it persisted.
        let onDiskSource = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(onDiskSource.contains("IdentityFile /Users/tester/.ssh/id_ed25519_prod-api"))
    }
}

// MARK: - Fakes

private enum FakeKeySetupResponse {
    case success(output: String = "")
    case failure(status: Int32, error: String)
}

private final class FakeKeySetupProcessExecutor: SSHProcessExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [SSHProcessRequest] = []

    var responder: (@Sendable (SSHProcessRequest) -> FakeKeySetupResponse)?

    var requests: [SSHProcessRequest] { lock.withLock { storedRequests } }

    func start(
        _ request: SSHProcessRequest,
        onOutput: @escaping @Sendable (SSHProcessStream, Data) -> Void,
        completion: @escaping @Sendable (Result<SSHProcessResult, SSHProcessClientError>) -> Void
    ) throws -> any SSHProcessTask {
        lock.withLock { storedRequests.append(request) }
        let response = responder?(request) ?? .success()
        switch response {
        case let .success(output):
            completion(.success(SSHProcessResult(
                terminationStatus: 0,
                standardOutput: output,
                standardError: "",
                duration: 0.01
            )))
        case let .failure(status, error):
            completion(.success(SSHProcessResult(
                terminationStatus: status,
                standardOutput: "",
                standardError: error,
                duration: 0.01
            )))
        }
        return FakeKeySetupProcessTask()
    }
}

private final class FakeKeySetupProcessTask: SSHProcessTask, @unchecked Sendable {
    func cancel() {}
}
