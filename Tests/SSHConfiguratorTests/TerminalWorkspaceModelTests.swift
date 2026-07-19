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

    @MainActor
    func testOpensConnectionGroupAsSeparateSessionsInOneBatch() {
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
    func testConnectionGroupLaunchIsAtomicWhenAnAliasIsInvalid() {
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
    func testConnectionGroupDoesNotPartiallyOpenWithUnsavedChanges() {
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
    func testConnectionGroupReusesAlreadyRunningSessions() {
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
    func testOpensConnectionGroupInOneSessionWithSeparatePanes() {
        let model = makeModel()
        let groupID = UUID()
        let targets = [
            SSHConnectionTarget(hostID: 1, alias: "prod-api"),
            SSHConnectionTarget(hostID: 2, alias: "prod-worker"),
            SSHConnectionTarget(hostID: 3, alias: "prod-db"),
        ]

        XCTAssertTrue(
            model.openConnectionGroupInSplitSession(
                groupID: groupID,
                title: "Prod Servers",
                targets: targets,
                hasUnsavedChanges: false
            )
        )

        let session = try! XCTUnwrap(model.selectedSession)
        XCTAssertEqual(model.sessions.count, 1)
        XCTAssertEqual(session.groupID, groupID)
        XCTAssertEqual(session.alias, "Prod Servers")
        XCTAssertEqual(session.panes.map(\.alias), ["prod-api", "prod-worker", "prod-db"])
        XCTAssertEqual(session.panes.count, 3)
    }

    @MainActor
    func testReusesMatchingRunningSplitGroupSession() {
        let model = makeModel()
        let groupID = UUID()
        let targets = [
            SSHConnectionTarget(hostID: 1, alias: "prod-api"),
            SSHConnectionTarget(hostID: 2, alias: "prod-db"),
        ]
        XCTAssertTrue(
            model.openConnectionGroupInSplitSession(
                groupID: groupID,
                title: "Prod Servers",
                targets: targets,
                hasUnsavedChanges: false
            )
        )
        let firstSessionID = model.selectedSessionID

        XCTAssertTrue(
            model.openConnectionGroupInSplitSession(
                groupID: groupID,
                title: "Prod Servers",
                targets: targets,
                hasUnsavedChanges: true
            )
        )

        XCTAssertEqual(model.sessions.count, 1)
        XCTAssertEqual(model.selectedSessionID, firstSessionID)
    }

    @MainActor
    func testSplitGroupLaunchIsAtomicWhenAnAliasIsInvalid() {
        let model = makeModel()

        XCTAssertFalse(
            model.openConnectionGroupInSplitSession(
                groupID: UUID(),
                title: "Prod Servers",
                targets: [
                    SSHConnectionTarget(hostID: 1, alias: "prod-api"),
                    SSHConnectionTarget(hostID: 2, alias: "*.example.com"),
                ],
                hasUnsavedChanges: false
            )
        )

        XCTAssertTrue(model.sessions.isEmpty)
        XCTAssertEqual(model.errorMessage, TerminalWorkspaceError.noConcreteAlias.localizedDescription)
    }

    @MainActor
    func testManualSplitInGroupDuplicatesTheActivePaneConnection() {
        let model = makeModel()
        let groupID = UUID()
        XCTAssertTrue(
            model.openConnectionGroupInSplitSession(
                groupID: groupID,
                title: "Prod Servers",
                targets: [
                    SSHConnectionTarget(hostID: 1, alias: "prod-api"),
                    SSHConnectionTarget(hostID: 2, alias: "prod-db"),
                ],
                hasUnsavedChanges: false
            )
        )
        let sessionID = try! XCTUnwrap(model.selectedSessionID)
        let prodDBPane = try! XCTUnwrap(model.selectedSession?.panes.last)
        model.selectPane(prodDBPane.id, in: sessionID)

        XCTAssertTrue(model.splitActivePane(in: sessionID, axis: .horizontal))

        XCTAssertEqual(model.selectedSession?.panes.map(\.alias), ["prod-api", "prod-db", "prod-db"])
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
    func testGroupSkipMarksEveryAutomaticProfileSkipped() {
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

        XCTAssertTrue(model.openConnectionGroupInSplitSession(
            groupID: UUID(),
            title: "Prod",
            targets: targets,
            hasUnsavedChanges: false,
            startupProfiles: profiles,
            skipAllStartups: true
        ))

        XCTAssertEqual(model.selectedSession?.panes.map(\.startupState), [.skipped, .skipped])
        XCTAssertTrue(model.selectedSession?.panes.allSatisfy {
            $0.process.arguments == ["--", $0.alias]
        } == true)
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
