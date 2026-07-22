import CoreGraphics
import Foundation
import XCTest
@testable import SSHConfigurator

final class TerminalWorkspaceModelTests: XCTestCase {
    @MainActor
    func testRequiresSavedConfigBeforeOpeningNewSession() {
        let model = makeModel()

        XCTAssertFalse(model.openConnection(hostID: 1, alias: "prod", hasUnsavedChanges: true))
        XCTAssertTrue(model.sessions.isEmpty)
        XCTAssertNotNil(model.errorMessage)
    }

    @MainActor
    func testReusesRunningSessionForTheSameHost() {
        let model = makeModel()

        XCTAssertTrue(model.openConnection(hostID: 1, alias: "prod", hasUnsavedChanges: false))
        let firstID = model.selectedSessionID
        XCTAssertTrue(model.openConnection(hostID: 1, alias: "prod", hasUnsavedChanges: false))

        XCTAssertEqual(model.sessions.count, 1)
        XCTAssertEqual(model.selectedSessionID, firstID)
    }

    /// Returning to the sidebar's Local Terminal item used to append a tab on
    /// every click, so coming back from another section (Snippets, say) threw
    /// you into a brand new terminal.
    @MainActor
    func testReturningToTheLocalTerminalReusesTheLiveTab() {
        let model = makeModel()

        XCTAssertTrue(model.openLocalTerminal())
        let firstID = model.selectedSessionID
        XCTAssertTrue(model.openLocalTerminal())

        XCTAssertEqual(model.sessions.count, 1)
        XCTAssertEqual(model.selectedSessionID, firstID)
    }

    @MainActor
    func testNewTabButtonOpensASecondLocalTerminalDespiteThatReuse() {
        let model = makeModel()

        XCTAssertTrue(model.openLocalTerminal())
        let firstID = try! XCTUnwrap(model.selectedSessionID)

        XCTAssertTrue(model.openNewTabFromActivePane(in: firstID))

        XCTAssertEqual(model.sessions.count, 2)
        XCTAssertEqual(model.sessions.map(\.alias), ["Yerel Terminal", "Yerel Terminal"])
        XCTAssertNotEqual(model.selectedSessionID, firstID)
    }

    @MainActor
    func testNewTabButtonDuplicatesAnSSHConnectionInsteadOfReusingItsTab() {
        let model = makeModel()

        XCTAssertTrue(model.openConnection(hostID: 1, alias: "prod", hasUnsavedChanges: false))
        let firstID = try! XCTUnwrap(model.selectedSessionID)

        XCTAssertTrue(model.openNewTabFromActivePane(in: firstID))

        XCTAssertEqual(model.sessions.count, 2)
        XCTAssertEqual(model.sessions.map(\.alias), ["prod", "prod"])
        XCTAssertEqual(model.sessions.map(\.hostID), [1, 1])
        XCTAssertNotEqual(model.selectedSessionID, firstID)

        // Reopening from the sidebar still selects an existing tab rather than
        // adding a third — duplicating is the explicit button's job only.
        XCTAssertTrue(model.openConnection(hostID: 1, alias: "prod", hasUnsavedChanges: false))
        XCTAssertEqual(model.sessions.count, 2)
    }

    /// A split session can hold panes from different hosts, so the new tab
    /// follows the *active pane*, not the session's own alias.
    @MainActor
    func testNewTabFollowsTheActivePaneOfASplitSession() {
        let model = makeModel()

        XCTAssertTrue(model.openConnection(hostID: 1, alias: "prod", hasUnsavedChanges: false))
        let sessionID = try! XCTUnwrap(model.selectedSessionID)
        model.splitActivePane(in: sessionID, axis: .vertical)
        let activeAlias = try! XCTUnwrap(model.selectedSession?.activePane?.alias)

        XCTAssertTrue(model.openNewTabFromActivePane(in: sessionID))

        XCTAssertEqual(model.sessions.count, 2)
        XCTAssertEqual(model.selectedSession?.panes.map(\.alias), [activeAlias])
    }

    @MainActor
    func testOpensMultipleConnectionsAsSeparateSessionsInOneBatch() {
        let model = makeModel()
        let targets = [
            SSHConnectionTarget(hostID: 1, alias: "prod-api"),
            SSHConnectionTarget(hostID: 2, alias: "prod-worker"),
            SSHConnectionTarget(hostID: 3, alias: "prod-db"),
        ]

        XCTAssertTrue(model.openConnections(targets, hasUnsavedChanges: false))

        XCTAssertEqual(model.sessions.map(\.alias), ["prod-api", "prod-worker", "prod-db"])
        XCTAssertEqual(model.sessions.count, 3)
        XCTAssertEqual(model.selectedSession?.alias, "prod-db")
        XCTAssertTrue(model.sessions.allSatisfy { $0.status == .running })
    }

    @MainActor
    func testBatchConnectionLaunchIsAtomicWhenAnAliasIsInvalid() {
        let model = makeModel()
        let targets = [
            SSHConnectionTarget(hostID: 1, alias: "prod-api"),
            SSHConnectionTarget(hostID: 2, alias: "*.example.com"),
        ]

        XCTAssertFalse(model.openConnections(targets, hasUnsavedChanges: false))

        XCTAssertTrue(model.sessions.isEmpty)
        XCTAssertNotNil(model.errorMessage)
    }

    @MainActor
    func testBatchConnectionDoesNotPartiallyOpenWithUnsavedChanges() {
        let model = makeModel()
        let targets = [
            SSHConnectionTarget(hostID: 1, alias: "prod-api"),
            SSHConnectionTarget(hostID: 2, alias: "prod-db"),
        ]

        XCTAssertFalse(model.openConnections(targets, hasUnsavedChanges: true))

        XCTAssertTrue(model.sessions.isEmpty)
        XCTAssertEqual(model.errorMessage, TerminalWorkspaceError.unsavedChanges.localizedDescription)
    }

    @MainActor
    func testBatchConnectionReusesAlreadyRunningSessions() {
        let model = makeModel()
        XCTAssertTrue(model.openConnection(hostID: 1, alias: "prod-api", hasUnsavedChanges: false))
        let existingSessionID = model.selectedSessionID

        XCTAssertTrue(
            model.openConnections(
                [
                    SSHConnectionTarget(hostID: 1, alias: "prod-api"),
                    SSHConnectionTarget(hostID: 2, alias: "prod-db"),
                ],
                hasUnsavedChanges: false
            )
        )

        XCTAssertEqual(model.sessions.count, 2)
        XCTAssertEqual(model.sessions.first?.id, existingSessionID)
        XCTAssertEqual(model.selectedSession?.alias, "prod-db")
    }

    @MainActor
    func testClosingTabRemovesDirectSSHSession() {
        let model = makeModel()
        XCTAssertTrue(model.openConnection(hostID: 1, alias: "prod", hasUnsavedChanges: false))
        let sessionID = try! XCTUnwrap(model.selectedSessionID)

        model.closeTab(sessionID)

        XCTAssertTrue(model.sessions.isEmpty)
        XCTAssertNil(model.selectedSessionID)
    }

    @MainActor
    func testProcessExitMarksSessionAndAllowsAReplacement() {
        let model = makeModel()
        XCTAssertTrue(model.openConnection(hostID: 1, alias: "prod", hasUnsavedChanges: false))
        let firstID = try! XCTUnwrap(model.selectedSessionID)
        let firstPaneID = try! XCTUnwrap(model.selectedSession?.activePaneID)

        model.processDidExit(sessionID: firstID, paneID: firstPaneID, exitCode: 255)
        XCTAssertEqual(model.selectedSession?.status, .exited(255))

        XCTAssertTrue(model.openConnection(hostID: 1, alias: "prod", hasUnsavedChanges: false))
        XCTAssertEqual(model.sessions.count, 1)
        XCTAssertNotEqual(model.selectedSessionID, firstID)
        XCTAssertEqual(model.selectedSession?.status, .running)
    }

    @MainActor
    func testVerticalSplitOpensTheSameConnectionInANewPane() {
        let model = makeModel()
        XCTAssertTrue(model.openConnection(hostID: 1, alias: "prod", hasUnsavedChanges: false))
        let sessionID = try! XCTUnwrap(model.selectedSessionID)
        let originalPaneID = try! XCTUnwrap(model.selectedSession?.activePaneID)

        XCTAssertTrue(model.splitActivePane(in: sessionID, axis: .vertical))

        let session = try! XCTUnwrap(model.selectedSession)
        XCTAssertEqual(session.panes.count, 2)
        XCTAssertNotEqual(session.activePaneID, originalPaneID)
        XCTAssertTrue(session.panes.allSatisfy { $0.process.arguments == ["--", "prod"] })
        guard case let .split(_, axis, _, _, _) = session.layout else {
            return XCTFail("Dikey split layout bekleniyordu")
        }
        XCTAssertEqual(axis, .vertical)
    }

    @MainActor
    func testHorizontalSplitTargetsTheCurrentlyActivePane() {
        let model = makeModel()
        XCTAssertTrue(model.openConnection(hostID: 1, alias: "prod", hasUnsavedChanges: false))
        let sessionID = try! XCTUnwrap(model.selectedSessionID)
        XCTAssertTrue(model.splitActivePane(in: sessionID, axis: .vertical))
        let activePaneBeforeSecondSplit = try! XCTUnwrap(model.selectedSession?.activePaneID)

        XCTAssertTrue(model.splitActivePane(in: sessionID, axis: .horizontal))

        let session = try! XCTUnwrap(model.selectedSession)
        XCTAssertEqual(session.panes.count, 3)
        XCTAssertNotEqual(session.activePaneID, activePaneBeforeSecondSplit)
        XCTAssertTrue(session.panes.allSatisfy { $0.process.arguments == ["--", "prod"] })
    }

    @MainActor
    func testCommandClickSelectsTheActiveAndClickedPanesForSynchronization() {
        let model = makeModel()
        XCTAssertTrue(model.openConnection(hostID: 1, alias: "prod", hasUnsavedChanges: false))
        let sessionID = try! XCTUnwrap(model.selectedSessionID)
        let originalPaneID = try! XCTUnwrap(model.selectedSession?.activePaneID)
        XCTAssertTrue(model.splitActivePane(in: sessionID, axis: .vertical))
        let activePaneID = try! XCTUnwrap(model.selectedSession?.activePaneID)

        model.selectPane(
            originalPaneID,
            in: sessionID,
            extendingSynchronization: true
        )

        XCTAssertEqual(model.selectedSession?.activePaneID, activePaneID)
        XCTAssertEqual(
            model.selectedSession?.synchronizedPaneIDs,
            Set([originalPaneID, activePaneID])
        )
    }

    @MainActor
    func testCommandClickCanExtendAndToggleTheSynchronizedPaneSelection() {
        let model = makeModel()
        XCTAssertTrue(model.openConnection(hostID: 1, alias: "prod", hasUnsavedChanges: false))
        let sessionID = try! XCTUnwrap(model.selectedSessionID)
        let firstPaneID = try! XCTUnwrap(model.selectedSession?.activePaneID)
        XCTAssertTrue(model.splitActivePane(in: sessionID, axis: .vertical))
        let secondPaneID = try! XCTUnwrap(model.selectedSession?.activePaneID)
        XCTAssertTrue(model.splitActivePane(in: sessionID, axis: .horizontal))
        let thirdPaneID = try! XCTUnwrap(model.selectedSession?.activePaneID)

        model.selectPane(firstPaneID, in: sessionID, extendingSynchronization: true)
        model.selectPane(secondPaneID, in: sessionID, extendingSynchronization: true)
        XCTAssertEqual(
            model.selectedSession?.synchronizedPaneIDs,
            Set([firstPaneID, secondPaneID, thirdPaneID])
        )

        model.selectPane(secondPaneID, in: sessionID, extendingSynchronization: true)
        XCTAssertEqual(
            model.selectedSession?.synchronizedPaneIDs,
            Set([firstPaneID, thirdPaneID])
        )

        model.selectPane(firstPaneID, in: sessionID, extendingSynchronization: true)
        XCTAssertTrue(model.selectedSession?.synchronizedPaneIDs.isEmpty == true)
    }

    @MainActor
    func testNormalPaneSelectionClearsSynchronization() {
        let model = makeModel()
        XCTAssertTrue(model.openConnection(hostID: 1, alias: "prod", hasUnsavedChanges: false))
        let sessionID = try! XCTUnwrap(model.selectedSessionID)
        let firstPaneID = try! XCTUnwrap(model.selectedSession?.activePaneID)
        XCTAssertTrue(model.splitActivePane(in: sessionID, axis: .vertical))
        let secondPaneID = try! XCTUnwrap(model.selectedSession?.activePaneID)
        model.selectPane(firstPaneID, in: sessionID, extendingSynchronization: true)

        model.selectPane(secondPaneID, in: sessionID)

        XCTAssertEqual(model.selectedSession?.activePaneID, secondPaneID)
        XCTAssertTrue(model.selectedSession?.synchronizedPaneIDs.isEmpty == true)
    }

    @MainActor
    func testClosingPaneRemovesItFromSynchronization() {
        let model = makeModel()
        XCTAssertTrue(model.openConnection(hostID: 1, alias: "prod", hasUnsavedChanges: false))
        let sessionID = try! XCTUnwrap(model.selectedSessionID)
        let firstPaneID = try! XCTUnwrap(model.selectedSession?.activePaneID)
        XCTAssertTrue(model.splitActivePane(in: sessionID, axis: .vertical))
        let secondPaneID = try! XCTUnwrap(model.selectedSession?.activePaneID)
        model.selectPane(firstPaneID, in: sessionID, extendingSynchronization: true)

        model.closePane(firstPaneID, in: sessionID)

        XCTAssertEqual(model.selectedSession?.activePaneID, secondPaneID)
        XCTAssertTrue(model.selectedSession?.synchronizedPaneIDs.isEmpty == true)
    }

    @MainActor
    func testClosingActivePaneKeepsRemainingConnectionAndCollapsesLayout() {
        let model = makeModel()
        XCTAssertTrue(model.openConnection(hostID: 1, alias: "prod", hasUnsavedChanges: false))
        let sessionID = try! XCTUnwrap(model.selectedSessionID)
        XCTAssertTrue(model.splitActivePane(in: sessionID, axis: .vertical))
        let paneToClose = try! XCTUnwrap(model.selectedSession?.activePaneID)

        model.closePane(paneToClose, in: sessionID)

        let session = try! XCTUnwrap(model.selectedSession)
        XCTAssertEqual(session.panes.count, 1)
        XCTAssertNotEqual(session.activePaneID, paneToClose)
        guard case .pane = session.layout else {
            return XCTFail("Tek pane kaldığında split layout çökmeliydi")
        }
    }

    @MainActor
    func testProcessExitOnlyMarksMatchingPane() {
        let model = makeModel()
        XCTAssertTrue(model.openConnection(hostID: 1, alias: "prod", hasUnsavedChanges: false))
        let sessionID = try! XCTUnwrap(model.selectedSessionID)
        let firstPaneID = try! XCTUnwrap(model.selectedSession?.activePaneID)
        XCTAssertTrue(model.splitActivePane(in: sessionID, axis: .horizontal))
        let secondPaneID = try! XCTUnwrap(model.selectedSession?.activePaneID)

        model.processDidExit(sessionID: sessionID, paneID: secondPaneID, exitCode: 7)

        let session = try! XCTUnwrap(model.selectedSession)
        XCTAssertEqual(session.layout.pane(id: firstPaneID)?.status, .running)
        XCTAssertEqual(session.layout.pane(id: secondPaneID)?.status, .exited(7))
        XCTAssertEqual(session.status, .running)
    }

    @MainActor
    func testStartupRunningBlocksSynchronizationUntilMarkerCompletes() {
        let model = makeModel()
        let profile = StartupFlowProfile(
            alias: "prod",
            automaticallyRun: true,
            steps: [.runCommand("uptime")]
        )
        XCTAssertTrue(model.openConnection(
            hostID: 1,
            alias: "prod",
            hasUnsavedChanges: false,
            startupProfile: profile
        ))
        let sessionID = try! XCTUnwrap(model.selectedSessionID)
        let firstPaneID = try! XCTUnwrap(model.selectedSession?.activePaneID)
        XCTAssertTrue(model.splitActivePane(
            in: sessionID,
            axis: .vertical,
            startupProfile: profile
        ))
        let secondPaneID = try! XCTUnwrap(model.selectedSession?.activePaneID)
        XCTAssertEqual(model.selectedSession?.activePane?.startupState, .running(stepIndex: nil))

        model.selectPane(firstPaneID, in: sessionID, extendingSynchronization: true)
        XCTAssertTrue(model.selectedSession?.synchronizedPaneIDs.isEmpty == true)

        model.startupEvent(.completed, sessionID: sessionID, paneID: firstPaneID)
        model.selectPane(firstPaneID, in: sessionID, extendingSynchronization: true)
        XCTAssertTrue(model.selectedSession?.synchronizedPaneIDs.isEmpty == true)

        model.startupEvent(.completed, sessionID: sessionID, paneID: secondPaneID)
        model.selectPane(firstPaneID, in: sessionID, extendingSynchronization: true)
        XCTAssertEqual(
            model.selectedSession?.synchronizedPaneIDs,
            Set([firstPaneID, secondPaneID])
        )
    }

    @MainActor
    func testManualStartupClearsSynchronizationAndReportsFailedStep() {
        let model = makeModel()
        let profile = StartupFlowProfile(
            alias: "prod",
            automaticallyRun: false,
            steps: [.changeDirectory("/missing path"), .runCommand("uptime")]
        )
        XCTAssertTrue(model.openConnection(
            hostID: 1,
            alias: "prod",
            hasUnsavedChanges: false,
            startupProfile: profile
        ))
        let sessionID = try! XCTUnwrap(model.selectedSessionID)
        let paneID = try! XCTUnwrap(model.selectedSession?.activePaneID)

        let command = model.prepareManualStartup(sessionID: sessionID, paneID: paneID)
        XCTAssertTrue(command?.hasSuffix("\r") == true)
        XCTAssertEqual(model.selectedSession?.activePane?.startupState, .running(stepIndex: nil))

        model.startupEvent(.failed(stepIndex: 0, exitCode: 2), sessionID: sessionID, paneID: paneID)
        guard case let .failed(stepIndex, message) = model.selectedSession?.activePane?.startupState else {
            return XCTFail("Başarısız başlangıç durumu bekleniyordu")
        }
        XCTAssertEqual(stepIndex, 0)
        XCTAssertTrue(message.contains("/missing path"))
        XCTAssertTrue(message.contains("exit: 2"))
    }

    @MainActor
    func testBatchSkipMarksEveryAutomaticProfileSkipped() {
        let model = makeModel()
        let targets = [
            SSHConnectionTarget(hostID: 1, alias: "prod-api"),
            SSHConnectionTarget(hostID: 2, alias: "prod-db"),
        ]
        let profiles = Dictionary(uniqueKeysWithValues: targets.map {
            ($0.alias, StartupFlowProfile(
                alias: $0.alias,
                automaticallyRun: true,
                steps: [.runCommand("echo \($0.alias)")]
            ))
        })

        XCTAssertTrue(model.openConnections(
            targets,
            hasUnsavedChanges: false,
            startupProfiles: profiles,
            skipAllStartups: true
        ))

        let allPanes = model.sessions.flatMap(\.panes)
        XCTAssertEqual(allPanes.map(\.startupState), [.skipped, .skipped])
        XCTAssertTrue(allPanes.allSatisfy {
            $0.process.arguments == ["--", $0.alias]
        })
    }

    @MainActor
    func testProcessExitBeforeStartupCompletionMarksFlowFailed() {
        let model = makeModel()
        let profile = StartupFlowProfile(
            alias: "prod",
            automaticallyRun: true,
            steps: [.runCommand("uptime")]
        )
        XCTAssertTrue(model.openConnection(
            hostID: 1,
            alias: "prod",
            hasUnsavedChanges: false,
            startupProfile: profile
        ))
        let sessionID = try! XCTUnwrap(model.selectedSessionID)
        let paneID = try! XCTUnwrap(model.selectedSession?.activePaneID)

        model.processDidExit(sessionID: sessionID, paneID: paneID, exitCode: 255)

        guard case let .failed(_, message) = model.selectedSession?.activePane?.startupState else {
            return XCTFail("Başlangıç başarısız durumu bekleniyordu")
        }
        XCTAssertTrue(message.contains("closed before the startup flow finished"))
        XCTAssertTrue(message.contains("255"))
    }

    // MARK: - WP7: automatic reconnect

    @MainActor
    func testClosingPaneBeforeItsDelayedExitEventArrivesNeverShowsTheDisconnectBand() {
        let model = makeModel(reconnectScheduler: ManualReconnectScheduler())
        XCTAssertTrue(model.openConnection(hostID: 1, alias: "prod", hasUnsavedChanges: false))
        let sessionID = try! XCTUnwrap(model.selectedSessionID)
        let paneID = try! XCTUnwrap(model.selectedSession?.activePaneID)

        // User closes the pane; the real SwiftTerm engine's `processTerminated`
        // callback for the now-dead process can still arrive afterwards
        // (see `dismantleNSView` -> `terminate()`), simulated here directly.
        model.closePane(paneID, in: sessionID)
        model.processDidExit(sessionID: sessionID, paneID: paneID, exitCode: 0)

        XCTAssertNil(model.paneReconnectStates[paneID])
    }

    @MainActor
    func testUnexpectedExitOnRealHostAwaitsManualReconnectByDefault() {
        let model = makeModel(reconnectScheduler: ManualReconnectScheduler())
        XCTAssertTrue(model.openConnection(hostID: 1, alias: "prod", hasUnsavedChanges: false))
        let sessionID = try! XCTUnwrap(model.selectedSessionID)
        let paneID = try! XCTUnwrap(model.selectedSession?.activePaneID)

        model.processDidExit(sessionID: sessionID, paneID: paneID, exitCode: 0)

        XCTAssertEqual(model.paneReconnectStates[paneID], .awaitingManualReconnect)
    }

    @MainActor
    func testUnexpectedExitOnLocalTerminalIsNeverTracked() {
        let model = makeModel(reconnectScheduler: ManualReconnectScheduler())
        XCTAssertTrue(model.openLocalTerminal())
        let sessionID = try! XCTUnwrap(model.selectedSessionID)
        let paneID = try! XCTUnwrap(model.selectedSession?.activePaneID)

        model.processDidExit(sessionID: sessionID, paneID: paneID, exitCode: 0)

        XCTAssertNil(model.paneReconnectStates[paneID])
    }

    @MainActor
    func testEnablingAutoReconnectWhileDisconnectedStartsACountdownAndPersists() {
        let scheduler = ManualReconnectScheduler()
        let settingsStore = MockAutoReconnectSettingsStore()
        let model = makeModel(reconnectScheduler: scheduler, autoReconnectSettingsStore: settingsStore)
        XCTAssertTrue(model.openConnection(hostID: 1, alias: "prod", hasUnsavedChanges: false))
        let sessionID = try! XCTUnwrap(model.selectedSessionID)
        let paneID = try! XCTUnwrap(model.selectedSession?.activePaneID)
        model.processDidExit(sessionID: sessionID, paneID: paneID, exitCode: 0)
        XCTAssertFalse(model.isAutoReconnectEnabled(forAlias: "prod"))

        model.setAutoReconnectEnabled(true, forAlias: "prod", paneID: paneID, sessionID: sessionID)

        XCTAssertTrue(model.isAutoReconnectEnabled(forAlias: "prod"))
        XCTAssertEqual(settingsStore.savedState?.enabledAliases, ["prod"])
        guard case .countingDown = model.paneReconnectStates[paneID] else {
            return XCTFail("Beklenen: countingDown durumu")
        }

        // Letting the scheduled attempt fire reconnects the pane (WP7: same
        // path a manual reconnect uses).
        XCTAssertTrue(scheduler.fireOldest())
        XCTAssertEqual(model.selectedSession?.activePane?.status, .running)
        XCTAssertNotEqual(model.selectedSession?.activePaneID, paneID)
    }

    @MainActor
    func testManualReconnectCancelsAPendingAutomaticCountdown() {
        let scheduler = ManualReconnectScheduler()
        let settingsStore = MockAutoReconnectSettingsStore(enabledAliases: ["prod"])
        let model = makeModel(reconnectScheduler: scheduler, autoReconnectSettingsStore: settingsStore)
        XCTAssertTrue(model.openConnection(hostID: 1, alias: "prod", hasUnsavedChanges: false))
        let sessionID = try! XCTUnwrap(model.selectedSessionID)
        let paneID = try! XCTUnwrap(model.selectedSession?.activePaneID)
        model.processDidExit(sessionID: sessionID, paneID: paneID, exitCode: 1)
        guard case .countingDown = model.paneReconnectStates[paneID] else {
            return XCTFail("Beklenen: countingDown durumu (otomatik mod açık)")
        }

        // Manual click while a countdown is pending must win outright, not
        // race with (or later double-fire alongside) the scheduled attempt.
        XCTAssertTrue(model.manualReconnectRequested(paneID, in: sessionID, startupProfile: nil))

        XCTAssertNil(model.paneReconnectStates[paneID])
        XCTAssertFalse(scheduler.fireOldest()) // nothing left pending for the old pane
    }

    @MainActor
    func testSetSplitRatioUpdatesTargetSplit() {
        let model = makeModel()
        XCTAssertTrue(model.openConnection(hostID: 1, alias: "prod", hasUnsavedChanges: false))
        let sessionID = try! XCTUnwrap(model.selectedSessionID)
        XCTAssertTrue(model.splitActivePane(in: sessionID, axis: .vertical))

        guard case let .split(splitID, _, _, _, _) = try! XCTUnwrap(model.selectedSession?.layout) else {
            return XCTFail("Split layout bekleniyordu")
        }

        model.setSplitRatio(0.7, splitID: splitID, in: sessionID)

        guard case let .split(_, _, ratio, _, _) = try! XCTUnwrap(model.selectedSession?.layout) else {
            return XCTFail("Split layout bekleniyordu")
        }
        XCTAssertEqual(ratio, 0.7)
    }

    @MainActor
    func testSetSplitRatioClamps() {
        let model = makeModel()
        XCTAssertTrue(model.openConnection(hostID: 1, alias: "prod", hasUnsavedChanges: false))
        let sessionID = try! XCTUnwrap(model.selectedSessionID)
        XCTAssertTrue(model.splitActivePane(in: sessionID, axis: .vertical))
        guard case let .split(splitID, _, _, _, _) = try! XCTUnwrap(model.selectedSession?.layout) else {
            return XCTFail("Split layout bekleniyordu")
        }

        model.setSplitRatio(0.05, splitID: splitID, in: sessionID)
        guard case let .split(_, _, lowRatio, _, _) = try! XCTUnwrap(model.selectedSession?.layout) else {
            return XCTFail("Split layout bekleniyordu")
        }
        XCTAssertEqual(lowRatio, TerminalPaneLayout.minimumSplitRatio)

        model.setSplitRatio(0.95, splitID: splitID, in: sessionID)
        guard case let .split(_, _, highRatio, _, _) = try! XCTUnwrap(model.selectedSession?.layout) else {
            return XCTFail("Split layout bekleniyordu")
        }
        XCTAssertEqual(highRatio, TerminalPaneLayout.maximumSplitRatio)
    }

    @MainActor
    func testSetSplitRatioIgnoresUnknownID() {
        let model = makeModel()
        XCTAssertTrue(model.openConnection(hostID: 1, alias: "prod", hasUnsavedChanges: false))
        let sessionID = try! XCTUnwrap(model.selectedSessionID)
        XCTAssertTrue(model.splitActivePane(in: sessionID, axis: .vertical))
        let layoutBefore = try! XCTUnwrap(model.selectedSession?.layout)

        model.setSplitRatio(0.7, splitID: UUID(), in: sessionID)

        XCTAssertEqual(model.selectedSession?.layout, layoutBefore)
    }

    func testSwappingPanesExchangesLeaves() {
        let paneA = TerminalPane(
            alias: "a",
            process: TerminalProcessConfiguration(
                executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
                arguments: [],
                environment: [:],
                currentDirectoryURL: nil
            )
        )
        let paneB = TerminalPane(
            alias: "b",
            process: TerminalProcessConfiguration(
                executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
                arguments: [],
                environment: [:],
                currentDirectoryURL: nil
            )
        )
        let layout = TerminalPaneLayout.split(
            id: UUID(),
            axis: .vertical,
            ratio: 0.5,
            first: .pane(paneA),
            second: .pane(paneB)
        )

        let swapped = try! XCTUnwrap(layout.swappingPanes(paneA.id, paneB.id))

        XCTAssertEqual(swapped.panes.map(\.id), [paneB.id, paneA.id])
        XCTAssertEqual(Set(swapped.panes.map(\.id)), Set([paneA.id, paneB.id]))
    }

    func testSwappingPanesReturnsNilForUnknownOrIdenticalIDs() {
        let paneA = TerminalPane(
            alias: "a",
            process: TerminalProcessConfiguration(
                executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
                arguments: [],
                environment: [:],
                currentDirectoryURL: nil
            )
        )
        let paneB = TerminalPane(
            alias: "b",
            process: TerminalProcessConfiguration(
                executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
                arguments: [],
                environment: [:],
                currentDirectoryURL: nil
            )
        )
        let layout = TerminalPaneLayout.split(
            id: UUID(),
            axis: .vertical,
            ratio: 0.5,
            first: .pane(paneA),
            second: .pane(paneB)
        )

        XCTAssertNil(layout.swappingPanes(paneA.id, paneA.id))
        XCTAssertNil(layout.swappingPanes(paneA.id, UUID()))
    }

    // MARK: - Faz 2: pane drag-and-drop swap

    @MainActor
    func testSwapPanesExchangesTreePositions() {
        let model = makeModel()
        XCTAssertTrue(model.openConnection(hostID: 1, alias: "prod", hasUnsavedChanges: false))
        let sessionID = try! XCTUnwrap(model.selectedSessionID)
        let firstPaneID = try! XCTUnwrap(model.selectedSession?.activePaneID)
        XCTAssertTrue(model.splitActivePane(in: sessionID, axis: .vertical))
        let secondPaneID = try! XCTUnwrap(model.selectedSession?.activePaneID)

        model.swapPanes(firstPaneID, secondPaneID, in: sessionID)

        let session = try! XCTUnwrap(model.selectedSession)
        XCTAssertEqual(session.panes.map(\.id), [secondPaneID, firstPaneID])
        XCTAssertEqual(Set(session.panes.map(\.id)), Set([firstPaneID, secondPaneID]))
    }

    @MainActor
    func testSwapPanesKeepsActiveAndSyncIDs() {
        let model = makeModel()
        XCTAssertTrue(model.openConnection(hostID: 1, alias: "prod", hasUnsavedChanges: false))
        let sessionID = try! XCTUnwrap(model.selectedSessionID)
        let firstPaneID = try! XCTUnwrap(model.selectedSession?.activePaneID)
        XCTAssertTrue(model.splitActivePane(in: sessionID, axis: .vertical))
        let secondPaneID = try! XCTUnwrap(model.selectedSession?.activePaneID)
        model.selectPane(firstPaneID, in: sessionID, extendingSynchronization: true)
        let activePaneIDBeforeSwap = try! XCTUnwrap(model.selectedSession?.activePaneID)
        let syncedIDsBeforeSwap = try! XCTUnwrap(model.selectedSession?.synchronizedPaneIDs)

        model.swapPanes(firstPaneID, secondPaneID, in: sessionID)

        XCTAssertEqual(model.selectedSession?.activePaneID, activePaneIDBeforeSwap)
        XCTAssertEqual(model.selectedSession?.synchronizedPaneIDs, syncedIDsBeforeSwap)
    }

    @MainActor
    func testSwapPanesIgnoresUnknownOrIdenticalIDs() {
        let model = makeModel()
        XCTAssertTrue(model.openConnection(hostID: 1, alias: "prod", hasUnsavedChanges: false))
        let sessionID = try! XCTUnwrap(model.selectedSessionID)
        let firstPaneID = try! XCTUnwrap(model.selectedSession?.activePaneID)
        XCTAssertTrue(model.splitActivePane(in: sessionID, axis: .vertical))
        let layoutBefore = try! XCTUnwrap(model.selectedSession?.layout)

        model.swapPanes(firstPaneID, firstPaneID, in: sessionID)
        XCTAssertEqual(model.selectedSession?.layout, layoutBefore)

        model.swapPanes(firstPaneID, UUID(), in: sessionID)
        XCTAssertEqual(model.selectedSession?.layout, layoutBefore)
    }

    // MARK: - Faz 3: tab drag-and-drop reorder

    @MainActor
    func testMoveSessionReordersTabs() {
        let model = makeModel()
        XCTAssertTrue(model.openConnection(hostID: 1, alias: "prod-api", hasUnsavedChanges: false))
        XCTAssertTrue(model.openConnection(hostID: 2, alias: "prod-db", hasUnsavedChanges: false))
        XCTAssertTrue(model.openConnection(hostID: 3, alias: "prod-worker", hasUnsavedChanges: false))
        let firstID = model.sessions[0].id
        let thirdID = model.sessions[2].id

        model.moveSession(thirdID, before: firstID)

        XCTAssertEqual(model.sessions.map(\.alias), ["prod-worker", "prod-api", "prod-db"])
    }

    @MainActor
    func testMoveSessionKeepsSelection() {
        let model = makeModel()
        XCTAssertTrue(model.openConnection(hostID: 1, alias: "prod-api", hasUnsavedChanges: false))
        XCTAssertTrue(model.openConnection(hostID: 2, alias: "prod-db", hasUnsavedChanges: false))
        XCTAssertTrue(model.openConnection(hostID: 3, alias: "prod-worker", hasUnsavedChanges: false))
        let selectedID = try! XCTUnwrap(model.selectedSessionID)
        let firstID = model.sessions[0].id

        model.moveSession(selectedID, before: firstID)

        XCTAssertEqual(model.selectedSessionID, selectedID)
        XCTAssertEqual(model.sessions.map(\.id).first, selectedID)
    }

    @MainActor
    func testMoveSessionIgnoresUnknownIDs() {
        let model = makeModel()
        XCTAssertTrue(model.openConnection(hostID: 1, alias: "prod-api", hasUnsavedChanges: false))
        XCTAssertTrue(model.openConnection(hostID: 2, alias: "prod-db", hasUnsavedChanges: false))
        let aliasesBefore = model.sessions.map(\.alias)
        let firstID = model.sessions[0].id

        model.moveSession(UUID(), before: firstID)
        XCTAssertEqual(model.sessions.map(\.alias), aliasesBefore)

        model.moveSession(firstID, before: UUID())
        XCTAssertEqual(model.sessions.map(\.alias), aliasesBefore)

        model.moveSession(firstID, before: firstID)
        XCTAssertEqual(model.sessions.map(\.alias), aliasesBefore)
    }

    // MARK: - Faz 5: normalizedFrames + directional pane navigation

    func testNormalizedFramesOfNestedSplitMatchesExpectedRects() {
        let paneA = TerminalPane(
            alias: "a",
            process: TerminalProcessConfiguration(
                executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
                arguments: [],
                environment: [:],
                currentDirectoryURL: nil
            )
        )
        let paneB = TerminalPane(
            alias: "b",
            process: TerminalProcessConfiguration(
                executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
                arguments: [],
                environment: [:],
                currentDirectoryURL: nil
            )
        )
        let paneC = TerminalPane(
            alias: "c",
            process: TerminalProcessConfiguration(
                executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
                arguments: [],
                environment: [:],
                currentDirectoryURL: nil
            )
        )
        // Left half: paneA. Right half split horizontally 25/75 into paneB (top)/paneC (bottom).
        let layout = TerminalPaneLayout.split(
            id: UUID(),
            axis: .vertical,
            ratio: 0.5,
            first: .pane(paneA),
            second: .split(
                id: UUID(),
                axis: .horizontal,
                ratio: 0.25,
                first: .pane(paneB),
                second: .pane(paneC)
            )
        )

        let frames = layout.normalizedFrames()

        XCTAssertEqual(frames[paneA.id], CGRect(x: 0, y: 0, width: 0.5, height: 1))
        XCTAssertEqual(frames[paneB.id], CGRect(x: 0.5, y: 0, width: 0.5, height: 0.25))
        XCTAssertEqual(frames[paneC.id], CGRect(x: 0.5, y: 0.25, width: 0.5, height: 0.75))
    }

    @MainActor
    func testSelectPaneDirectionalPicksNearestInDirection() {
        let model = makeModel()
        XCTAssertTrue(model.openConnection(hostID: 1, alias: "prod", hasUnsavedChanges: false))
        let sessionID = try! XCTUnwrap(model.selectedSessionID)
        let topLeftID = try! XCTUnwrap(model.selectedSession?.activePaneID)

        // Vertical split: topLeft (left half, unchanged ID) | new pane (right half, active).
        XCTAssertTrue(model.splitActivePane(in: sessionID, axis: .vertical))
        let topRightID = try! XCTUnwrap(model.selectedSession?.activePaneID)

        // Split the left half horizontally: topLeft (top) | bottomLeft (bottom, active).
        model.selectPane(topLeftID, in: sessionID)
        XCTAssertTrue(model.splitActivePane(in: sessionID, axis: .horizontal))
        let bottomLeftID = try! XCTUnwrap(model.selectedSession?.activePaneID)

        // Split the right half horizontally: topRight (top) | bottomRight (bottom, active).
        model.selectPane(topRightID, in: sessionID)
        XCTAssertTrue(model.splitActivePane(in: sessionID, axis: .horizontal))
        let bottomRightID = try! XCTUnwrap(model.selectedSession?.activePaneID)

        // 2x2 grid: [topLeft, topRight] / [bottomLeft, bottomRight]. Exercise all 4 directions.
        model.selectPane(topLeftID, in: sessionID)
        model.selectPane(direction: .right, in: sessionID)
        XCTAssertEqual(model.selectedSession?.activePaneID, topRightID)

        model.selectPane(topLeftID, in: sessionID)
        model.selectPane(direction: .down, in: sessionID)
        XCTAssertEqual(model.selectedSession?.activePaneID, bottomLeftID)

        model.selectPane(bottomRightID, in: sessionID)
        model.selectPane(direction: .left, in: sessionID)
        XCTAssertEqual(model.selectedSession?.activePaneID, bottomLeftID)

        model.selectPane(bottomRightID, in: sessionID)
        model.selectPane(direction: .up, in: sessionID)
        XCTAssertEqual(model.selectedSession?.activePaneID, topRightID)
    }

    @MainActor
    func testSelectPaneDirectionalNoOpAtEdge() {
        let model = makeModel()
        XCTAssertTrue(model.openConnection(hostID: 1, alias: "prod", hasUnsavedChanges: false))
        let sessionID = try! XCTUnwrap(model.selectedSessionID)
        let leftID = try! XCTUnwrap(model.selectedSession?.activePaneID)
        XCTAssertTrue(model.splitActivePane(in: sessionID, axis: .vertical))
        let rightID = try! XCTUnwrap(model.selectedSession?.activePaneID)

        // Rightmost pane: nothing further right, and this is a purely
        // horizontal grid, so up/down are also no-ops.
        model.selectPane(direction: .right, in: sessionID)
        XCTAssertEqual(model.selectedSession?.activePaneID, rightID)
        model.selectPane(direction: .up, in: sessionID)
        XCTAssertEqual(model.selectedSession?.activePaneID, rightID)
        model.selectPane(direction: .down, in: sessionID)
        XCTAssertEqual(model.selectedSession?.activePaneID, rightID)

        // Leftmost pane: nothing further left.
        model.selectPane(leftID, in: sessionID)
        model.selectPane(direction: .left, in: sessionID)
        XCTAssertEqual(model.selectedSession?.activePaneID, leftID)
    }

    // MARK: - Faz 8: tab rename

    @MainActor
    func testRenameSessionSetsAndClearsCustomTitle() {
        let model = makeModel()
        XCTAssertTrue(model.openConnection(hostID: 1, alias: "prod", hasUnsavedChanges: false))
        let sessionID = try! XCTUnwrap(model.selectedSessionID)

        model.renameSession(sessionID, title: "  Production API  ")
        XCTAssertEqual(model.selectedSession?.customTitle, "Production API")
        XCTAssertEqual(model.selectedSession?.displayTitle, "Production API")

        model.renameSession(sessionID, title: "")
        XCTAssertNil(model.selectedSession?.customTitle)
    }

    @MainActor
    func testRenameSessionPersistsRoundTrip() {
        let store = MockWorkspaceLayoutStore()
        let model = TerminalWorkspaceModel(
            launchPlanBuilder: SSHLaunchPlanBuilder(
                sshURL: URL(fileURLWithPath: "/usr/bin/ssh"),
                baseEnvironment: ["PATH": "/usr/bin:/bin"],
                currentDirectoryURL: URL(fileURLWithPath: "/tmp")
            ),
            workspaceStore: store
        )
        XCTAssertTrue(model.openConnection(hostID: 1, alias: "prod", hasUnsavedChanges: false))
        let sessionID = try! XCTUnwrap(model.selectedSessionID)
        model.renameSession(sessionID, title: "Production")
        model.flushPendingSave()

        let restoredModel = TerminalWorkspaceModel(
            launchPlanBuilder: SSHLaunchPlanBuilder(
                sshURL: URL(fileURLWithPath: "/usr/bin/ssh"),
                baseEnvironment: ["PATH": "/usr/bin:/bin"],
                currentDirectoryURL: URL(fileURLWithPath: "/tmp")
            ),
            workspaceStore: store
        )
        restoredModel.restoreWorkspace()

        XCTAssertEqual(restoredModel.selectedSessionID, sessionID)
        XCTAssertEqual(restoredModel.selectedSession?.customTitle, "Production")
        XCTAssertEqual(restoredModel.selectedSession?.displayTitle, "Production")
    }

    @MainActor
    func testWorkspaceSaveFailureIsExposedAndDismissable() {
        let store = MockWorkspaceLayoutStore()
        store.shouldFailSave = true
        let model = TerminalWorkspaceModel(
            launchPlanBuilder: SSHLaunchPlanBuilder(
                sshURL: URL(fileURLWithPath: "/usr/bin/ssh"),
                baseEnvironment: ["PATH": "/usr/bin:/bin"],
                currentDirectoryURL: URL(fileURLWithPath: "/tmp")
            ),
            workspaceStore: store
        )

        XCTAssertTrue(model.openConnection(hostID: 1, alias: "prod", hasUnsavedChanges: false))
        model.flushPendingSave()

        XCTAssertTrue(model.persistenceErrorMessage?.contains("disk full") == true)
        model.dismissPersistenceError()
        XCTAssertNil(model.persistenceErrorMessage)
    }

    @MainActor
    func testEmptyTitleRevertsToAlias() {
        let model = makeModel()
        XCTAssertTrue(model.openConnection(hostID: 1, alias: "prod", hasUnsavedChanges: false))
        let sessionID = try! XCTUnwrap(model.selectedSessionID)

        model.renameSession(sessionID, title: "Custom")
        model.renameSession(sessionID, title: "  \n\t ")

        XCTAssertNil(model.selectedSession?.customTitle)
        XCTAssertEqual(model.selectedSession?.displayTitle, "prod")
    }

    // MARK: - Faz 6: pane zoom

    @MainActor
    func testToggleZoomSetsAndClears() {
        let model = makeModel()
        XCTAssertTrue(model.openConnection(hostID: 1, alias: "prod", hasUnsavedChanges: false))
        let sessionID = try! XCTUnwrap(model.selectedSessionID)

        // Single-pane session: no-op.
        model.toggleZoom(in: sessionID)
        XCTAssertNil(model.selectedSession?.zoomedPaneID)

        XCTAssertTrue(model.splitActivePane(in: sessionID, axis: .vertical))
        let activeID = try! XCTUnwrap(model.selectedSession?.activePaneID)

        model.toggleZoom(in: sessionID)
        XCTAssertEqual(model.selectedSession?.zoomedPaneID, activeID)

        model.toggleZoom(in: sessionID)
        XCTAssertNil(model.selectedSession?.zoomedPaneID)
    }

    @MainActor
    func testSplitOrCloseExitsZoom() {
        let model = makeModel()
        XCTAssertTrue(model.openConnection(hostID: 1, alias: "prod", hasUnsavedChanges: false))
        let sessionID = try! XCTUnwrap(model.selectedSessionID)
        XCTAssertTrue(model.splitActivePane(in: sessionID, axis: .vertical))

        model.toggleZoom(in: sessionID)
        XCTAssertNotNil(model.selectedSession?.zoomedPaneID)
        XCTAssertTrue(model.splitActivePane(in: sessionID, axis: .horizontal))
        XCTAssertNil(model.selectedSession?.zoomedPaneID, "splitActivePane should exit zoom")

        model.toggleZoom(in: sessionID)
        XCTAssertNotNil(model.selectedSession?.zoomedPaneID)
        let paneIDs = try! XCTUnwrap(model.selectedSession?.panes.map(\.id))
        model.swapPanes(paneIDs[0], paneIDs[1], in: sessionID)
        XCTAssertNil(model.selectedSession?.zoomedPaneID, "swapPanes should exit zoom")
    }

    @MainActor
    func testCloseZoomedPaneClearsZoom() {
        let model = makeModel()
        XCTAssertTrue(model.openConnection(hostID: 1, alias: "prod", hasUnsavedChanges: false))
        let sessionID = try! XCTUnwrap(model.selectedSessionID)
        XCTAssertTrue(model.splitActivePane(in: sessionID, axis: .vertical))
        let zoomedID = try! XCTUnwrap(model.selectedSession?.activePaneID)

        model.toggleZoom(in: sessionID)
        XCTAssertEqual(model.selectedSession?.zoomedPaneID, zoomedID)

        model.closePane(zoomedID, in: sessionID)

        XCTAssertNil(model.selectedSession?.zoomedPaneID)
    }

    /// `nearestPane` hit-tests the real (unzoomed) geometry, so navigating
    /// while zoomed must exit zoom — otherwise the newly active pane would be
    /// a still-hidden one and focus would have nowhere visible to land. A
    /// no-op navigation (nothing in that direction) must leave zoom alone.
    @MainActor
    func testSelectPaneDirectionalExitsZoom() {
        let model = makeModel()
        XCTAssertTrue(model.openConnection(hostID: 1, alias: "prod", hasUnsavedChanges: false))
        let sessionID = try! XCTUnwrap(model.selectedSessionID)
        let leftID = try! XCTUnwrap(model.selectedSession?.activePaneID)
        XCTAssertTrue(model.splitActivePane(in: sessionID, axis: .vertical))
        let rightID = try! XCTUnwrap(model.selectedSession?.activePaneID)

        model.toggleZoom(in: sessionID)
        XCTAssertEqual(model.selectedSession?.zoomedPaneID, rightID)

        model.selectPane(direction: .left, in: sessionID)

        XCTAssertEqual(model.selectedSession?.activePaneID, leftID)
        XCTAssertNil(model.selectedSession?.zoomedPaneID, "directional nav should exit zoom")

        model.toggleZoom(in: sessionID)
        XCTAssertEqual(model.selectedSession?.zoomedPaneID, leftID)

        // Leftmost pane, nothing further left: a no-op navigation must not
        // exit zoom either.
        model.selectPane(direction: .left, in: sessionID)
        XCTAssertEqual(model.selectedSession?.zoomedPaneID, leftID, "no-op nav must not exit zoom")
    }

    @MainActor
    private func makeModel() -> TerminalWorkspaceModel {
        TerminalWorkspaceModel(
            launchPlanBuilder: SSHLaunchPlanBuilder(
                sshURL: URL(fileURLWithPath: "/usr/bin/ssh"),
                baseEnvironment: ["PATH": "/usr/bin:/bin"],
                currentDirectoryURL: URL(fileURLWithPath: "/tmp")
            )
        )
    }

    @MainActor
    private func makeModel(
        reconnectScheduler: any ReconnectScheduling,
        autoReconnectSettingsStore: any AutoReconnectSettingsPersisting = MockAutoReconnectSettingsStore()
    ) -> TerminalWorkspaceModel {
        TerminalWorkspaceModel(
            launchPlanBuilder: SSHLaunchPlanBuilder(
                sshURL: URL(fileURLWithPath: "/usr/bin/ssh"),
                baseEnvironment: ["PATH": "/usr/bin:/bin"],
                currentDirectoryURL: URL(fileURLWithPath: "/tmp")
            ),
            autoReconnectSettingsStore: autoReconnectSettingsStore,
            reconnectScheduler: reconnectScheduler,
            networkObserver: NullNetworkPathObserver()
        )
    }
}

final class MockAutoReconnectSettingsStore: AutoReconnectSettingsPersisting {
    var savedState: AutoReconnectSettingsState?
    private let initialState: AutoReconnectSettingsState

    init(enabledAliases: Set<String> = []) {
        initialState = AutoReconnectSettingsState(enabledAliases: enabledAliases)
    }

    func load() throws -> AutoReconnectSettingsState {
        savedState ?? initialState
    }

    func save(_ state: AutoReconnectSettingsState) throws {
        savedState = state
    }
}
