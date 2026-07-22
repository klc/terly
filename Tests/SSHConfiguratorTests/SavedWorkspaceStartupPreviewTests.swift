import Foundation
import XCTest
@testable import SSHConfigurator

final class SavedWorkspaceStartupPreviewTests: XCTestCase {
    func testSameHostTwoCommandPanesProduceTwoItemsWithDistinctEffectiveCommands() {
        let firstID = UUID()
        let secondID = UUID()
        let workspace = SavedWorkspace(
            name: "Snapshot",
            sessions: [
                SavedWorkspaceSession(
                    hostID: 1,
                    alias: "prod",
                    layout: .split(
                        axis: .vertical,
                        ratio: 0.5,
                        first: .pane(SavedWorkspacePane(id: firstID, alias: "prod", startup: .command("htop"))),
                        second: .pane(SavedWorkspacePane(id: secondID, alias: "prod", startup: .command("iotop")))
                    ),
                    activePaneID: firstID
                ),
            ]
        )

        let items = SavedWorkspaceStartupPreview.autoRunningItems(for: workspace, aliasStartupProfiles: [:])

        XCTAssertEqual(items.count, 2)
        let commands = items.compactMap { $0.profile?.steps.first?.summary }
        XCTAssertEqual(Set(commands), Set(["htop", "iotop"]))
        XCTAssertTrue(items.allSatisfy { $0.target.hostID == 1 && $0.target.alias == "prod" })
    }

    func testSuppressedPaneIsExcluded() {
        let paneID = UUID()
        let workspace = SavedWorkspace(
            name: "Snapshot",
            sessions: [
                SavedWorkspaceSession(
                    hostID: 1,
                    alias: "prod",
                    layout: .pane(SavedWorkspacePane(id: paneID, alias: "prod", startup: .suppressed)),
                    activePaneID: paneID
                ),
            ]
        )

        let items = SavedWorkspaceStartupPreview.autoRunningItems(
            for: workspace,
            aliasStartupProfiles: ["prod": StartupFlowProfile(alias: "prod", automaticallyRun: true, steps: [.runCommand("echo hi")])]
        )

        XCTAssertTrue(items.isEmpty)
    }

    func testNilOverridePaneUsesAliasKeyedProfile() {
        let paneID = UUID()
        let workspace = SavedWorkspace(
            name: "Snapshot",
            sessions: [
                SavedWorkspaceSession(
                    hostID: 1,
                    alias: "prod",
                    layout: .pane(SavedWorkspacePane(id: paneID, alias: "prod")),
                    activePaneID: paneID
                ),
            ]
        )
        let aliasProfile = StartupFlowProfile(alias: "prod", automaticallyRun: true, steps: [.runCommand("tail -f app.log")])

        let items = SavedWorkspaceStartupPreview.autoRunningItems(
            for: workspace,
            aliasStartupProfiles: ["prod": aliasProfile]
        )

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].profile?.steps.first?.summary, "tail -f app.log")
    }

    func testNonAutomaticAliasProfileProducesNoItem() {
        let paneID = UUID()
        let workspace = SavedWorkspace(
            name: "Snapshot",
            sessions: [
                SavedWorkspaceSession(
                    hostID: 1,
                    alias: "prod",
                    layout: .pane(SavedWorkspacePane(id: paneID, alias: "prod")),
                    activePaneID: paneID
                ),
            ]
        )
        let aliasProfile = StartupFlowProfile(alias: "prod", automaticallyRun: false, steps: [.runCommand("tail -f app.log")])

        let items = SavedWorkspaceStartupPreview.autoRunningItems(
            for: workspace,
            aliasStartupProfiles: ["prod": aliasProfile]
        )

        XCTAssertTrue(items.isEmpty)
    }

    func testLocalTerminalPaneNeverProducesAnItemEvenWithOverride() {
        let paneID = UUID()
        let workspace = SavedWorkspace(
            name: "Snapshot",
            sessions: [
                SavedWorkspaceSession(
                    hostID: -1,
                    alias: "Local Terminal",
                    layout: .pane(SavedWorkspacePane(id: paneID, alias: "Local Terminal", startup: .command("echo hi"))),
                    activePaneID: paneID
                ),
            ]
        )

        let items = SavedWorkspaceStartupPreview.autoRunningItems(for: workspace, aliasStartupProfiles: [:])

        XCTAssertTrue(items.isEmpty)
    }
}
