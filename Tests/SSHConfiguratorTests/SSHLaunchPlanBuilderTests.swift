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

    func testBuildsGroupedSessionWithBalancedPaneLayout() throws {
        let builder = SSHLaunchPlanBuilder(
            baseEnvironment: ["PATH": "/usr/bin:/bin"],
            currentDirectoryURL: URL(fileURLWithPath: "/tmp")
        )
        let groupID = UUID()

        let session = try builder.makeGroupedSession(
            groupID: groupID,
            title: "Prod Servers",
            targets: [
                SSHConnectionTarget(hostID: 1, alias: "prod-api"),
                SSHConnectionTarget(hostID: 2, alias: "prod-worker"),
                SSHConnectionTarget(hostID: 3, alias: "prod-db"),
            ]
        )

        XCTAssertEqual(session.alias, "Prod Servers")
        XCTAssertEqual(session.groupID, groupID)
        XCTAssertEqual(session.panes.map(\.alias), ["prod-api", "prod-worker", "prod-db"])
        XCTAssertEqual(session.panes.map(\.process.arguments), [
            ["--", "prod-api"],
            ["--", "prod-worker"],
            ["--", "prod-db"],
        ])
        guard case let .split(_, axis, _, _, _) = session.layout else {
            return XCTFail("Çoklu bağlantı için split layout bekleniyordu")
        }
        XCTAssertEqual(axis, .vertical)
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

    func testGroupedSessionUsesEachHostsOwnProfileWithoutCrossingCommands() throws {
        let first = StartupFlowProfile(
            alias: "prod-api",
            automaticallyRun: true,
            steps: [.runCommand("echo API_ONLY")]
        )
        let second = StartupFlowProfile(
            alias: "prod-db",
            automaticallyRun: true,
            steps: [.changeDirectory("/srv/DB ONLY")]
        )

        let session = try SSHLaunchPlanBuilder().makeGroupedSession(
            groupID: UUID(),
            title: "Prod",
            targets: [
                SSHConnectionTarget(hostID: 1, alias: "prod-api"),
                SSHConnectionTarget(hostID: 2, alias: "prod-db"),
            ],
            startupProfiles: ["prod-api": first, "prod-db": second]
        )

        let apiCommand = try XCTUnwrap(session.panes[0].process.arguments.last)
        let dbCommand = try XCTUnwrap(session.panes[1].process.arguments.last)
        XCTAssertTrue(apiCommand.contains("API_ONLY"))
        XCTAssertFalse(apiCommand.contains("DB ONLY"))
        XCTAssertTrue(dbCommand.contains("DB ONLY"))
        XCTAssertFalse(dbCommand.contains("API_ONLY"))
    }

    func testAliasBeginningWithDashRemainsAfterOptionTerminator() throws {
        let pane = try SSHLaunchPlanBuilder().makePane(alias: "-prod")
        XCTAssertEqual(pane.process.arguments, ["--", "-prod"])
    }
}
