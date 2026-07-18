import Foundation
import XCTest
@testable import SSHConfigurator

/// Manually-driven `ReconnectScheduling` fake: nothing fires until a test
/// explicitly calls `fireOldest()`, so backoff/timeout behaviour can be
/// verified without waiting on a real clock. Internal (not `private`) so
/// `TerminalWorkspaceModelTests` can reuse it for the model-level
/// integration tests.
@MainActor
final class ManualReconnectScheduler: ReconnectScheduling {
    private(set) var scheduled: [ReconnectTimerToken: (delay: TimeInterval, action: () -> Void)] = [:]
    private(set) var cancelledTokens: [ReconnectTimerToken] = []
    /// Order panes were scheduled in, oldest first — lets tests fire "the
    /// next timer" deterministically without relying on Dictionary order.
    private(set) var scheduleOrder: [ReconnectTimerToken] = []

    var scheduledCount: Int { scheduled.count }

    @discardableResult
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> ReconnectTimerToken {
        let token = ReconnectTimerToken()
        scheduled[token] = (delay, action)
        scheduleOrder.append(token)
        return token
    }

    func cancel(_ token: ReconnectTimerToken) {
        scheduled[token] = nil
        cancelledTokens.append(token)
    }

    func cancelAll() {
        scheduled.removeAll()
    }

    /// Fires the oldest still-scheduled timer (simulating time passing).
    @discardableResult
    func fireOldest() -> Bool {
        guard let token = scheduleOrder.first(where: { scheduled[$0] != nil }) else { return false }
        let entry = scheduled[token]!
        scheduled[token] = nil
        entry.action()
        return true
    }
}

@MainActor
final class AutoReconnectManagerTests: XCTestCase {
    private func makeSUT(
        successGraceInterval: TimeInterval = 15,
        performReconnect: @escaping AutoReconnectManager.ReconnectPerformer
    ) -> (AutoReconnectManager, ManualReconnectScheduler) {
        let scheduler = ManualReconnectScheduler()
        let manager = AutoReconnectManager(
            scheduler: scheduler,
            successGraceInterval: successGraceInterval,
            performReconnect: performReconnect
        )
        return (manager, scheduler)
    }

    // MARK: - Backoff policy

    func testBackoffDoublesFrom2sAndCapsAt60s() {
        XCTAssertEqual(ReconnectBackoffPolicy.delay(forAttempt: 1), 2)
        XCTAssertEqual(ReconnectBackoffPolicy.delay(forAttempt: 2), 4)
        XCTAssertEqual(ReconnectBackoffPolicy.delay(forAttempt: 3), 8)
        XCTAssertEqual(ReconnectBackoffPolicy.delay(forAttempt: 4), 16)
        XCTAssertEqual(ReconnectBackoffPolicy.delay(forAttempt: 5), 32)
        // Beyond the 5-attempt ceiling the raw doubling (64s) is capped at 60s.
        XCTAssertEqual(ReconnectBackoffPolicy.delay(forAttempt: 6), 60)
        XCTAssertEqual(ReconnectBackoffPolicy.delay(forAttempt: 7), 60)
    }

    func testMaxAttemptsIsFive() {
        XCTAssertEqual(ReconnectBackoffPolicy.maxAttempts, 5)
        XCTAssertEqual(AutoReconnectManager.maxAttempts, 5)
    }

    // MARK: - Basic chain

    func testUnexpectedExitWithAutoModeSchedulesFirstAttempt() {
        let (manager, scheduler) = makeSUT { _, _, _ in nil }
        let paneID = UUID()
        let sessionID = UUID()

        manager.handleUnexpectedExit(paneID: paneID, sessionID: sessionID, alias: "prod", autoModeEnabled: true)

        XCTAssertEqual(scheduler.scheduledCount, 1)
        guard case let .countingDown(attempt, maxAttempts, _) = manager.states[paneID] else {
            return XCTFail("Beklenen: countingDown durumu")
        }
        XCTAssertEqual(attempt, 1)
        XCTAssertEqual(maxAttempts, 5)
    }

    func testUnexpectedExitWithAutoModeOffShowsPlainBandAndSchedulesNothing() {
        let (manager, scheduler) = makeSUT { _, _, _ in nil }
        let paneID = UUID()

        manager.handleUnexpectedExit(paneID: paneID, sessionID: UUID(), alias: "prod", autoModeEnabled: false)

        XCTAssertEqual(scheduler.scheduledCount, 0)
        XCTAssertEqual(manager.states[paneID], .awaitingManualReconnect)
    }

    func testFiringScheduledAttemptReconnectsAndTracksTheNewPaneForSuccess() {
        var reconnected: [(TerminalPane.ID, TerminalSession.ID, String)] = []
        let newPaneID = UUID()
        let (manager, scheduler) = makeSUT { paneID, sessionID, alias in
            reconnected.append((paneID, sessionID, alias))
            return newPaneID
        }
        let oldPaneID = UUID()
        let sessionID = UUID()

        manager.handleUnexpectedExit(paneID: oldPaneID, sessionID: sessionID, alias: "prod", autoModeEnabled: true)
        XCTAssertTrue(scheduler.fireOldest())

        XCTAssertEqual(reconnected.count, 1)
        XCTAssertEqual(reconnected[0].0, oldPaneID)
        XCTAssertEqual(reconnected[0].1, sessionID)
        XCTAssertEqual(reconnected[0].2, "prod")
        // Old pane no longer tracked, new pane not showing a band (it's running).
        XCTAssertNil(manager.states[oldPaneID])
        XCTAssertNil(manager.states[newPaneID])
        // A success-grace timer is now pending for the new pane.
        XCTAssertEqual(scheduler.scheduledCount, 1)
    }

    func testPaneSurvivingGraceIntervalResetsTheChainToAttemptOne() {
        let newPaneID = UUID()
        let (manager, scheduler) = makeSUT { _, _, _ in newPaneID }
        let oldPaneID = UUID()
        let sessionID = UUID()

        manager.handleUnexpectedExit(paneID: oldPaneID, sessionID: sessionID, alias: "prod", autoModeEnabled: true)
        scheduler.fireOldest() // attempt 1 fires -> reconnects to newPaneID, starts success timer
        XCTAssertTrue(scheduler.fireOldest()) // success timer fires: pane survived 15s

        // A fresh disconnect on the (now confirmed-alive) pane starts over at attempt 1.
        manager.handleUnexpectedExit(paneID: newPaneID, sessionID: sessionID, alias: "prod", autoModeEnabled: true)
        guard case let .countingDown(attempt, _, _) = manager.states[newPaneID] else {
            return XCTFail("Beklenen: countingDown durumu")
        }
        XCTAssertEqual(attempt, 1)
    }

    func testRepeatedFailuresBeforeGraceIntervalKeepIncrementingTheAttemptCounter() {
        var currentNewPaneID = UUID()
        let (manager, scheduler) = makeSUT { _, _, _ in currentNewPaneID }
        let sessionID = UUID()
        var paneID = UUID()

        manager.handleUnexpectedExit(paneID: paneID, sessionID: sessionID, alias: "prod", autoModeEnabled: true)
        for expectedNextAttempt in 2...5 {
            XCTAssertTrue(scheduler.fireOldest()) // fires the pending backoff attempt -> reconnects
            paneID = currentNewPaneID
            currentNewPaneID = UUID()
            // The reconnected pane dies again immediately, well before its 15s
            // success-grace timer would fire — `handleUnexpectedExit` cancels
            // that stale success timer itself, so the chain just continues.
            manager.handleUnexpectedExit(paneID: paneID, sessionID: sessionID, alias: "prod", autoModeEnabled: true)
            guard case let .countingDown(attempt, _, _) = manager.states[paneID] else {
                return XCTFail("Beklenen: countingDown durumu (deneme \(expectedNextAttempt))")
            }
            XCTAssertEqual(attempt, expectedNextAttempt)
        }
    }

    func testChainStopsAfterMaxAttemptsAndReportsExhausted() {
        var currentNewPaneID = UUID()
        let (manager, scheduler) = makeSUT { _, _, _ in currentNewPaneID }
        let sessionID = UUID()
        var paneID = UUID()

        manager.handleUnexpectedExit(paneID: paneID, sessionID: sessionID, alias: "prod", autoModeEnabled: true)
        for _ in 1..<ReconnectBackoffPolicy.maxAttempts {
            XCTAssertTrue(scheduler.fireOldest()) // performs the reconnect attempt
            paneID = currentNewPaneID
            currentNewPaneID = UUID()
            manager.handleUnexpectedExit(paneID: paneID, sessionID: sessionID, alias: "prod", autoModeEnabled: true)
        }

        // 5th attempt already scheduled; fire it, then the pane dies once more —
        // that's a 6th disconnect, past the 5-attempt ceiling.
        XCTAssertTrue(scheduler.fireOldest())
        let lastPaneID = currentNewPaneID
        manager.handleUnexpectedExit(paneID: lastPaneID, sessionID: sessionID, alias: "prod", autoModeEnabled: true)

        XCTAssertEqual(manager.states[lastPaneID], .exhausted(attempts: ReconnectBackoffPolicy.maxAttempts))
        XCTAssertEqual(scheduler.scheduledCount, 0)
    }

    // MARK: - User-driven cancellation / double-trigger guard

    func testCancelCountdownStopsTheTimerAndFallsBackToManualBand() {
        let (manager, scheduler) = makeSUT { _, _, _ in nil }
        let paneID = UUID()
        manager.handleUnexpectedExit(paneID: paneID, sessionID: UUID(), alias: "prod", autoModeEnabled: true)
        XCTAssertEqual(scheduler.scheduledCount, 1)

        manager.cancelCountdown(paneID: paneID)

        XCTAssertEqual(scheduler.scheduledCount, 0)
        XCTAssertEqual(manager.states[paneID], .awaitingManualReconnect)
        // The (now-cancelled) timer must not fire a reconnect if a stray reference lingers.
        XCTAssertFalse(scheduler.fireOldest())
    }

    func testPaneClosedByUserStopsTrackingItEntirely() {
        let (manager, scheduler) = makeSUT { _, _, _ in nil }
        let paneID = UUID()
        manager.handleUnexpectedExit(paneID: paneID, sessionID: UUID(), alias: "prod", autoModeEnabled: true)

        manager.cancel(paneID: paneID)

        XCTAssertEqual(scheduler.scheduledCount, 0)
        XCTAssertNil(manager.states[paneID])
    }

    /// WP7 guard: calling the "unexpected exit" entry point twice in a row for
    /// the very same pane (e.g. a duplicate signal) must never leave two
    /// competing timers scheduled for it.
    func testHandlingTheSameUnexpectedExitTwiceNeverStacksTimers() {
        let (manager, scheduler) = makeSUT { _, _, _ in nil }
        let paneID = UUID()
        let sessionID = UUID()

        manager.handleUnexpectedExit(paneID: paneID, sessionID: sessionID, alias: "prod", autoModeEnabled: true)
        manager.handleUnexpectedExit(paneID: paneID, sessionID: sessionID, alias: "prod", autoModeEnabled: true)

        XCTAssertEqual(scheduler.scheduledCount, 1)
    }

    func testCancelAllClearsEveryTrackedPaneAndNotifiesNilState() {
        let (manager, scheduler) = makeSUT { _, _, _ in nil }
        let paneA = UUID()
        let paneB = UUID()
        var nilNotifications: Set<TerminalPane.ID> = []
        manager.onStateChange = { paneID, state in
            if state == nil { nilNotifications.insert(paneID) }
        }

        manager.handleUnexpectedExit(paneID: paneA, sessionID: UUID(), alias: "a", autoModeEnabled: true)
        manager.handleUnexpectedExit(paneID: paneB, sessionID: UUID(), alias: "b", autoModeEnabled: false)
        nilNotifications.removeAll() // only care about notifications from cancelAll() itself

        manager.cancelAll()

        XCTAssertEqual(scheduler.scheduledCount, 0)
        XCTAssertTrue(manager.states.isEmpty)
        XCTAssertEqual(nilNotifications, [paneA, paneB])
    }

    // MARK: - Auto mode toggled while disconnected

    func testEnablingAutoModeWhileWaitingManuallyStartsAttemptOneImmediately() {
        let (manager, scheduler) = makeSUT { _, _, _ in nil }
        let paneID = UUID()
        let sessionID = UUID()
        manager.handleUnexpectedExit(paneID: paneID, sessionID: sessionID, alias: "prod", autoModeEnabled: false)
        XCTAssertEqual(manager.states[paneID], .awaitingManualReconnect)

        manager.autoModeEnabledWhileDisconnected(paneID: paneID, sessionID: sessionID, alias: "prod")

        XCTAssertEqual(scheduler.scheduledCount, 1)
        guard case let .countingDown(attempt, _, _) = manager.states[paneID] else {
            return XCTFail("Beklenen: countingDown durumu")
        }
        XCTAssertEqual(attempt, 1)
    }

    func testEnablingAutoModeWhileRunningDoesNothing() {
        let (manager, scheduler) = makeSUT { _, _, _ in nil }
        let paneID = UUID()

        manager.autoModeEnabledWhileDisconnected(paneID: paneID, sessionID: UUID(), alias: "prod")

        XCTAssertEqual(scheduler.scheduledCount, 0)
        XCTAssertNil(manager.states[paneID])
    }

    // MARK: - Network return

    func testNetworkReturnFiresAPendingCountdownImmediately() {
        var reconnectedPaneIDs: [TerminalPane.ID] = []
        let (manager, scheduler) = makeSUT { paneID, _, _ in
            reconnectedPaneIDs.append(paneID)
            return nil
        }
        let paneID = UUID()
        manager.handleUnexpectedExit(paneID: paneID, sessionID: UUID(), alias: "prod", autoModeEnabled: true)
        XCTAssertTrue(reconnectedPaneIDs.isEmpty) // hasn't fired yet

        manager.networkBecameAvailable()

        XCTAssertEqual(reconnectedPaneIDs, [paneID])
        XCTAssertEqual(scheduler.scheduledCount, 0) // pending timer consumed, not left dangling
    }

    func testNetworkReturnOnlySuggestsWhenAutoModeIsOff() {
        let (manager, scheduler) = makeSUT { _, _, _ in nil }
        let paneID = UUID()
        manager.handleUnexpectedExit(paneID: paneID, sessionID: UUID(), alias: "prod", autoModeEnabled: false)

        manager.networkBecameAvailable()

        XCTAssertEqual(manager.states[paneID], .networkReturnedSuggestion)
        XCTAssertEqual(scheduler.scheduledCount, 0) // never connects on its own
    }
}
