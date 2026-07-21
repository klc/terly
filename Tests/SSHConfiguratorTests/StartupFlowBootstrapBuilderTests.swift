import Foundation
import XCTest
@testable import SSHConfigurator

final class StartupFlowBootstrapBuilderTests: XCTestCase {
    func testBuildsUserDirectoryAndCommandInOneQuotedBootstrap() throws {
        let runID = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
        let profile = StartupFlowProfile(
            alias: "prod-api",
            automaticallyRun: true,
            steps: [
                .changeUser("deploy-user"),
                .changeDirectory("/srv/Acme's API/current release"),
                .runCommand("printf '%s\\n' \"$HOME\";"),
            ]
        )

        let execution = try StartupFlowBootstrapBuilder().build(profile: profile, runID: runID)

        XCTAssertTrue(execution.command.hasPrefix("/bin/sh -lc '"))
        XCTAssertTrue(execution.command.contains("sudo -iu"))
        XCTAssertTrue(execution.command.contains("-- /bin/sh -lc"))
        XCTAssertTrue(execution.command.contains("startup_user=$(id -un"))
        XCTAssertTrue(execution.command.contains("cd --"))
        XCTAssertTrue(execution.command.contains("Acme"))
        XCTAssertTrue(execution.command.contains("printf"))
        XCTAssertTrue(execution.command.contains("SHELL:-/bin/sh"))
        XCTAssertTrue(execution.command.contains("-l"))
        XCTAssertEqual(
            execution.markerPrefix,
            "SSHCFG_STARTUP_00000000000000000000000000000123"
        )
        XCTAssertEqual(execution.stepSummaries.count, 3)
        try assertValidShell(execution.command)
    }

    func testShellQuoterHandlesSpacesApostrophesAndSpecialCharacters() {
        XCTAssertEqual(
            StartupShellQuoter.singleQuoted("/srv/O'Reilly/$live data"),
            "'/srv/O'\"'\"'Reilly/$live data'"
        )
    }

    func testCommandThatAlreadyEndsWithSemicolonStillBuildsValidShell() throws {
        let profile = StartupFlowProfile(
            alias: "prod",
            steps: [.runCommand("export APP_ENV='release';")]
        )

        let execution = try StartupFlowBootstrapBuilder().build(profile: profile)

        try assertValidShell(execution.command)
    }

    func testRejectsInvalidOrMisorderedUserStepsInsteadOfSilentlyRunningThem() {
        let builder = StartupFlowBootstrapBuilder()

        XCTAssertThrowsError(try builder.build(profile: StartupFlowProfile(
            alias: "prod",
            steps: [.changeDirectory("/srv"), .changeUser("deploy")]
        ))) { error in
            XCTAssertEqual(error as? StartupFlowBuildError, .changeUserMustBeFirst(step: 1))
        }

        XCTAssertThrowsError(try builder.build(profile: StartupFlowProfile(
            alias: "prod",
            steps: [.changeUser("deploy; whoami")]
        ))) { error in
            XCTAssertEqual(error as? StartupFlowBuildError, .invalidUser(step: 0))
        }

        XCTAssertThrowsError(try builder.build(profile: StartupFlowProfile(
            alias: "prod",
            steps: [.changeUser("deploy"), .changeUser("root")]
        ))) { error in
            XCTAssertEqual(error as? StartupFlowBuildError, .multipleUserChanges(step: 1))
        }
    }

    func testRejectsEmptyDirectoryAndCommand() {
        let builder = StartupFlowBootstrapBuilder()
        XCTAssertThrowsError(try builder.build(profile: StartupFlowProfile(
            alias: "prod",
            steps: [.changeDirectory("   ")]
        )))
        XCTAssertThrowsError(try builder.build(profile: StartupFlowProfile(
            alias: "prod",
            steps: [.runCommand("\n")]
        )))
    }

    func testSecretDetectorWarnsWithoutInspectingPrivateKeyFiles() {
        let detector = StartupFlowSecretDetector()
        XCTAssertTrue(detector.mayContainSecret(StartupFlowProfile(
            alias: "prod",
            steps: [.runCommand("export API_TOKEN=abc")]
        )))
        XCTAssertFalse(detector.mayContainSecret(StartupFlowProfile(
            alias: "prod",
            steps: [.runCommand("source /etc/profile")]
        )))
    }

    func testDirectoryAndCommandRunInSameShellContext() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("startup O'Reilly \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = StartupFlowProfile(
            alias: "prod",
            steps: [.changeDirectory(directory.path), .runCommand("pwd")]
        )
        let execution = try StartupFlowBootstrapBuilder().build(profile: profile)

        let result = try runShell(execution.command)

        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.output.contains(directory.path))
        XCTAssertTrue(result.output.contains("|completed"))
    }

    func testStoppingCommandPreventsLaterStepAndEmitsExactFailureMarker() throws {
        let profile = StartupFlowProfile(
            alias: "prod",
            steps: [
                .runCommand("false", stopOnFailure: true),
                .runCommand("echo SHOULD_NOT_RUN"),
            ]
        )
        let execution = try StartupFlowBootstrapBuilder().build(profile: profile)

        let result = try runShell(execution.command)

        XCTAssertEqual(result.status, 0)
        XCTAssertFalse(result.output.contains("SHOULD_NOT_RUN"))
        XCTAssertTrue(result.output.contains("|failed|0|1"))
        XCTAssertFalse(result.output.contains("|completed"))
    }

    func testNonStoppingCommandContinuesToLaterStep() throws {
        let profile = StartupFlowProfile(
            alias: "prod",
            steps: [
                .runCommand("false", stopOnFailure: false),
                .runCommand("echo CONTINUED"),
            ]
        )
        let execution = try StartupFlowBootstrapBuilder().build(profile: profile)

        let result = try runShell(execution.command)

        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("CONTINUED"))
        XCTAssertTrue(result.output.contains("|completed"))
        XCTAssertFalse(result.output.contains("|failed"))
    }

    func testMultilineFunctionsConditionalsQuotesAndBracesPreserveShellState() throws {
        let profile = StartupFlowProfile(
            alias: "prod",
            steps: [
                .runCommand(
                    """
                    startup_test_function() {
                        export STARTUP_TEST_VALUE="O'Reilly {release}"
                    }
                    if [ -n "${PATH}" ]; then
                        startup_test_function
                    fi
                    """
                ),
                .runCommand("printf 'STATE=%s\\n' \"$STARTUP_TEST_VALUE\""),
            ]
        )
        let execution = try StartupFlowBootstrapBuilder().build(profile: profile)

        let result = try runShell(execution.command)

        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("STATE=O'Reilly {release}"), result.output)
        XCTAssertTrue(result.output.contains("|completed"), result.output)
    }

    func testManualRerunSkipsSudoWhenAlreadyTargetUser() throws {
        let fixture = try makeCommandFixture(
            idOutput: "deploy",
            sudoScript: "printf 'SUDO_CALLED\\n'; exit 99"
        )
        defer { try? FileManager.default.removeItem(at: fixture) }
        let profile = StartupFlowProfile(
            alias: "prod",
            steps: [.changeUser("deploy"), .runCommand("echo TARGET_USER_PATH")]
        )
        let execution = try StartupFlowBootstrapBuilder().build(profile: profile)

        let result = try runShell(execution.command, prependingToPath: fixture.path)

        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("TARGET_USER_PATH"), result.output)
        XCTAssertFalse(result.output.contains("SUDO_CALLED"), result.output)
        XCTAssertTrue(result.output.contains("|completed"), result.output)
    }

    func testFirstUserChangeUsesSudoWhenCurrentUserDiffers() throws {
        let fixture = try makeCommandFixture(
            idOutput: "operator",
            sudoScript: """
            printf 'SUDO_CALLED\\n'
            while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do shift; done
            [ "$#" -gt 0 ] && shift
            exec "$@"
            """
        )
        defer { try? FileManager.default.removeItem(at: fixture) }
        let profile = StartupFlowProfile(
            alias: "prod",
            steps: [.changeUser("deploy"), .runCommand("echo FIRST_USER_CHANGE")]
        )
        let execution = try StartupFlowBootstrapBuilder().build(profile: profile)

        let result = try runShell(execution.command, prependingToPath: fixture.path)

        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("SUDO_CALLED"), result.output)
        XCTAssertTrue(result.output.contains("FIRST_USER_CHANGE"), result.output)
        XCTAssertTrue(result.output.contains("|completed"), result.output)
    }

    func testExitingTargetUserShellFallsBackToOriginalUserShell() throws {
        let fixture = try makeCommandFixture(
            idOutput: "original-user",
            sudoScript: """
            printf 'TARGET_USER_SHELL_EXITED\\n'
            exit 0
            """
        )
        defer { try? FileManager.default.removeItem(at: fixture) }
        let profile = StartupFlowProfile(
            alias: "prod",
            steps: [.changeUser("target-user"), .runCommand("echo INSIDE_TARGET")]
        )
        let execution = try StartupFlowBootstrapBuilder().build(profile: profile)

        let result = try runShell(execution.command, prependingToPath: fixture.path)

        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("TARGET_USER_SHELL_EXITED"), result.output)
        // Verify that after sudo exits, the script falls back to executing original user interactive shell
        XCTAssertTrue(execution.command.contains("; exec \"${SHELL:-/bin/sh}\" -l"), execution.command)
    }

    private func assertValidShell(_ command: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n", "-c", command]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        let error = String(
            data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, error)
    }

    private func runShell(
        _ command: String,
        prependingToPath path: String? = nil
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        let commandToRun: String
        if let path {
            let prefix = "/bin/sh -lc '"
            XCTAssertTrue(command.hasPrefix(prefix))
            commandToRun = prefix
                + "PATH=\(path):/usr/bin:/bin; "
                + command.dropFirst(prefix.count)
        } else {
            commandToRun = command
        }
        process.arguments = ["-c", commandToRun]
        let pathValue = path.map { "\($0):/usr/bin:/bin" } ?? "/usr/bin:/bin"
        process.environment = ["PATH": pathValue, "SHELL": "/usr/bin/true"]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        process.waitUntilExit()
        let output = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return (process.terminationStatus, output)
    }

    private func makeCommandFixture(idOutput: String, sudoScript: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeExecutable(
            "#!/bin/sh\nprintf '%s\\n' \(StartupShellQuoter.singleQuoted(idOutput))\n",
            to: directory.appendingPathComponent("id")
        )
        try writeExecutable(
            "#!/bin/sh\n\(sudoScript)\n",
            to: directory.appendingPathComponent("sudo")
        )
        return directory
    }

    private func writeExecutable(_ source: String, to url: URL) throws {
        try Data(source.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: url.path
        )
    }
}
