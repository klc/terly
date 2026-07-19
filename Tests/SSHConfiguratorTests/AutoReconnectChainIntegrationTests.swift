import Foundation
import XCTest
@testable import SSHConfigurator

/// WP8: an end-to-end reconnect-chain test driven through the full
/// `TerminalWorkspaceModel` (not the isolated `AutoReconnectManager` that
/// `AutoReconnectManagerTests` already covers in detail). It reuses that same
/// file's `ManualReconnectScheduler` fake — nothing fires until the test
/// explicitly asks it to — so the whole "disconnect -> backoff attempt fires
/// -> reconnect succeeds -> pane survives its success-grace window -> a fresh
/// disconnect restarts the chain at attempt 1" path is exercised through the
/// model's public API (`processDidExit`/`paneReconnectStates`), the same
/// surface `TerminalWorkspaceView` observes. `TerminalWorkspaceModelTests`
/// covers the countdown-starts and manual-cancel paths already; this test
/// targets the grace-interval-reset path neither of those exercises.
@MainActor
final class AutoReconnectChainIntegrationTests: XCTestCase {
    func testDisconnectBackoffSuccessThenFreshDisconnectResetsAttemptCounterToOne() {
        let scheduler = ManualReconnectScheduler()
        let settingsStore = MockAutoReconnectSettingsStore(enabledAliases: ["prod"])
        let model = TerminalWorkspaceModel(
            launchPlanBuilder: SSHLaunchPlanBuilder(
                sshURL: URL(fileURLWithPath: "/usr/bin/ssh"),
                baseEnvironment: ["PATH": "/usr/bin:/bin"],
                currentDirectoryURL: URL(fileURLWithPath: "/tmp")
            ),
            autoReconnectSettingsStore: settingsStore,
            reconnectScheduler: scheduler
        )

        XCTAssertTrue(model.openConnection(hostID: 1, alias: "prod", hasUnsavedChanges: false))
        guard let sessionID = model.selectedSessionID,
              let originalPaneID = model.selectedSession?.activePaneID else {
            return XCTFail("Expected: newly opened connection should produce a session and pane")
        }

        // 1. Unexpected exit with auto-reconnect already opted in for "prod"
        // schedules the first backoff attempt.
        model.processDidExit(sessionID: sessionID, paneID: originalPaneID, exitCode: 1)
        guard case let .countingDown(firstAttempt, _, _) = model.paneReconnectStates[originalPaneID] else {
            return XCTFail("Expected: countingDown state (first disconnect)")
        }
        XCTAssertEqual(firstAttempt, 1)
        XCTAssertEqual(scheduler.scheduledCount, 1)

        // 2. Firing that attempt reconnects the pane (same code path a manual
        // reconnect click uses) and starts a success-grace timer for the new pane.
        XCTAssertTrue(scheduler.fireOldest())
        guard let reconnectedPaneID = model.selectedSession?.activePaneID,
              reconnectedPaneID != originalPaneID else {
            return XCTFail("Expected: reconnecting should produce a new pane ID")
        }
        XCTAssertEqual(model.selectedSession?.activePane?.status, .running)
        XCTAssertNil(model.paneReconnectStates[originalPaneID])
        XCTAssertNil(model.paneReconnectStates[reconnectedPaneID]) // running, no band shown
        XCTAssertEqual(scheduler.scheduledCount, 1) // the pending success-grace timer

        // 3. The pane survives the grace window (nothing else fires before this),
        // so the chain is confirmed healthy and forgotten.
        XCTAssertTrue(scheduler.fireOldest())
        XCTAssertEqual(scheduler.scheduledCount, 0)

        // 4. A brand-new disconnect on that (now-confirmed-alive) pane must
        // restart the chain at attempt 1, not continue from wherever it left off.
        model.processDidExit(sessionID: sessionID, paneID: reconnectedPaneID, exitCode: 1)
        guard case let .countingDown(freshAttempt, maxAttempts, _) = model.paneReconnectStates[reconnectedPaneID] else {
            return XCTFail("Expected: countingDown state (new disconnect, counter reset)")
        }
        XCTAssertEqual(freshAttempt, 1)
        XCTAssertEqual(maxAttempts, AutoReconnectManager.maxAttempts)
    }
}
