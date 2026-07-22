import Foundation
import XCTest
@testable import SSHConfigurator

final class SSHLaunchPlanBuilderTests: XCTestCase {
    func testBuildsDirectSSHCommand() throws {
        let sshURL = URL(fileURLWithPath: "/usr/bin/ssh")
        let builder = SSHLaunchPlanBuilder(
            sshURL: sshURL,
            baseEnvironment: ["PATH": "/usr/bin:/bin"],
            currentDirectoryURL: URL(fileURLWithPath: "/tmp")
        )

        let session = try builder.makeSession(hostID: 42, alias: "prod-api")
        let pane = try XCTUnwrap(session.activePane)

        XCTAssertEqual(session.hostID, 42)
        XCTAssertEqual(session.alias, "prod-api")
        XCTAssertEqual(session.panes.count, 1)
        XCTAssertEqual(pane.alias, "prod-api")
        XCTAssertEqual(pane.process.executableURL, sshURL)
        XCTAssertEqual(pane.process.arguments, ["--", "prod-api"])
        XCTAssertEqual(pane.process.environment["TERM"], "xterm-256color")
        XCTAssertEqual(pane.process.environment["COLORTERM"], "truecolor")
        XCTAssertEqual(pane.process.currentDirectoryURL?.path, "/tmp")
    }

    func testTrimsAliasBeforeBuildingCommand() throws {
        let builder = SSHLaunchPlanBuilder()

        let session = try builder.makeSession(hostID: 1, alias: "  prod-api \n")

        XCTAssertEqual(session.alias, "prod-api")
        XCTAssertEqual(session.activePane?.process.arguments, ["--", "prod-api"])
    }

    func testInteractiveTerminalKeepsConfiguredLocale() throws {
        let builder = SSHLaunchPlanBuilder(baseEnvironment: [
            "PATH": "/usr/bin:/bin",
            "LANG": "tr_TR.UTF-8",
            "LC_ALL": "tr_TR.UTF-8",
        ])

        let session = try builder.makeSession(hostID: 1, alias: "prod")

        XCTAssertEqual(session.activePane?.process.environment["LANG"], "tr_TR.UTF-8")
        XCTAssertEqual(session.activePane?.process.environment["LC_ALL"], "tr_TR.UTF-8")
    }

    func testRejectsWildcardAndNegativeAliases() {
        XCTAssertFalse(SSHLaunchPlanBuilder.isConcreteAlias("*.example.com"))
        XCTAssertFalse(SSHLaunchPlanBuilder.isConcreteAlias("!blocked"))
        XCTAssertFalse(SSHLaunchPlanBuilder.isConcreteAlias(""))
        XCTAssertTrue(SSHLaunchPlanBuilder.isConcreteAlias("prod-api"))
    }

    func testBuildsAutomaticStartupAsOneRemoteCommandAndKeepsPTYInteractive() throws {
        let profile = StartupFlowProfile(
            alias: "prod-api",
            automaticallyRun: true,
            steps: [.changeDirectory("/srv/my app"), .runCommand("source ./env.sh")]
        )

        let pane = try SSHLaunchPlanBuilder().makePane(
            alias: "prod-api",
            startupProfile: profile
        )

        XCTAssertEqual(pane.process.arguments, [
            "-tt",
            "-o", "RemoteCommand=none",
            "-o", "SessionType=default",
            "--", "prod-api",
            try XCTUnwrap(pane.startupExecution?.command),
        ])
        XCTAssertEqual(pane.process.arguments.last, pane.startupExecution?.command)
        XCTAssertEqual(pane.startupState, .running(stepIndex: nil))
        XCTAssertTrue(pane.process.arguments.last?.contains("exec \"${SHELL:-/bin/sh}\" -l") == true)
    }

    func testSkipKeepsDirectSSHAndRetainsFlowForManualRun() throws {
        let profile = StartupFlowProfile(
            alias: "prod",
            automaticallyRun: true,
            steps: [.runCommand("uptime")]
        )

        let pane = try SSHLaunchPlanBuilder().makePane(
            alias: "prod",
            startupProfile: profile,
            skipStartup: true
        )

        XCTAssertEqual(pane.process.arguments, ["--", "prod"])
        XCTAssertEqual(pane.startupState, .skipped)
        XCTAssertNotNil(pane.startupExecution)
    }

    func testAliasBeginningWithDashRemainsAfterOptionTerminator() throws {
        let pane = try SSHLaunchPlanBuilder().makePane(alias: "-prod")
        XCTAssertEqual(pane.process.arguments, ["--", "-prod"])
    }

    // MARK: - Phase A: per-pane startup override

    func testCommandOverrideRunsAutomaticallyAndRoundTripsOnPane() throws {
        let pane = try SSHLaunchPlanBuilder().makePane(
            alias: "prod-api",
            startupOverride: .command("htop")
        )

        XCTAssertEqual(pane.process.arguments.prefix(4), ["-tt", "-o", "RemoteCommand=none", "-o"])
        XCTAssertTrue(pane.process.arguments.contains("-o"))
        XCTAssertTrue(pane.process.arguments.contains("SessionType=default"))
        let bootstrapCommand = try XCTUnwrap(pane.process.arguments.last)
        XCTAssertTrue(bootstrapCommand.contains("htop"))
        XCTAssertEqual(pane.startupOverride, .command("htop"))
    }

    func testSuppressedOverrideWinsOverAutoRunAliasProfile() throws {
        let profile = StartupFlowProfile(
            alias: "prod-api",
            automaticallyRun: true,
            steps: [.runCommand("uptime")]
        )

        let pane = try SSHLaunchPlanBuilder().makePane(
            alias: "prod-api",
            startupProfile: profile,
            startupOverride: .suppressed
        )

        XCTAssertEqual(pane.process.arguments, ["--", "prod-api"])
        XCTAssertNil(pane.startupExecution)
    }

    func testFlowOverrideNormalizesAliasAndForcesAutomaticRun() throws {
        let embedded = StartupFlowProfile(
            alias: "other-alias",
            automaticallyRun: false,
            steps: [.runCommand("echo hi")]
        )

        let effectiveProfile = try XCTUnwrap(
            PaneStartupOverride.flow(embedded).effectiveProfile(alias: "prod-api")
        )
        XCTAssertEqual(effectiveProfile.alias, "prod-api")
        XCTAssertTrue(effectiveProfile.automaticallyRun)

        let pane = try SSHLaunchPlanBuilder().makePane(
            alias: "prod-api",
            startupOverride: .flow(embedded)
        )

        XCTAssertEqual(pane.startupState, .running(stepIndex: nil))
        let bootstrapCommand = try XCTUnwrap(pane.process.arguments.last)
        XCTAssertTrue(bootstrapCommand.contains("echo hi"))
    }

    func testWhitespaceOnlyCommandOverrideBehavesAsNoStartup() throws {
        let pane = try SSHLaunchPlanBuilder().makePane(
            alias: "prod-api",
            startupOverride: .command("   ")
        )

        XCTAssertEqual(pane.process.arguments, ["--", "prod-api"])
        XCTAssertNil(pane.startupExecution)
    }
}
