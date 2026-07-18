import Foundation

/// Backoff schedule for automatic reconnect attempts: doubles from 2s,
/// capped at 60s. `maxAttempts` bounds how many automatic retries WP7 allows
/// before giving up and asking the user to act manually.
enum ReconnectBackoffPolicy {
    static let maxAttempts = 5
    private static let initialDelay: TimeInterval = 2
    private static let cap: TimeInterval = 60

    /// `attempt` is 1-based (the Nth automatic retry after a disconnect).
    static func delay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt >= 1 else { return initialDelay }
        let raw = initialDelay * pow(2, Double(attempt - 1))
        return min(raw, cap)
    }
}

/// Tracks per-pane automatic-reconnect state across the WP7 backoff chain:
/// unexpected disconnect -> scheduled retry -> reconnect attempt -> either a
/// fresh disconnect (chain continues, backoff grows) or the pane surviving
/// long enough to reset the chain.
///
/// Deliberately knows nothing about `TerminalSession`/`TerminalPane` beyond
/// their IDs and alias strings, so it can be driven and unit-tested without a
/// real `TerminalWorkspaceModel`. Owned by `TerminalWorkspaceModel`, which
/// wires `performReconnect` to its own `reconnectPane` machinery and mirrors
/// `onStateChange` into a `@Published` property the view observes.
@MainActor
final class AutoReconnectManager {
    enum State: Equatable {
        /// Waiting to retry automatically; `attempt` is 1-based, `fireDate` is
        /// when the retry fires (the view derives a live countdown from it).
        case countingDown(attempt: Int, maxAttempts: Int, fireDate: Date)
        /// All automatic attempts were used without the pane staying up.
        case exhausted(attempts: Int)
        /// Unexpected disconnect, auto mode is off for this host — plain
        /// "reconnect manually" band.
        case awaitingManualReconnect
        /// Same as above, but the network just came back — nudge the user.
        case networkReturnedSuggestion
    }

    private struct Chain {
        var attempt: Int
        var sessionID: TerminalSession.ID
        var alias: String
    }

    /// Attempts a reconnect for `paneID` in `sessionID`. Returns the new
    /// pane's ID on success, `nil` if the attempt failed synchronously (e.g.
    /// the launch plan couldn't be built) — in which case there's no new pane
    /// to keep tracking and the chain ends.
    typealias ReconnectPerformer = (
        _ paneID: TerminalPane.ID,
        _ sessionID: TerminalSession.ID,
        _ alias: String
    ) -> TerminalPane.ID?

    private(set) var states: [TerminalPane.ID: State] = [:]
    /// Fired whenever a pane's state changes (`nil` means "no longer tracked,
    /// clear any band"). `TerminalWorkspaceModel` mirrors this into its own
    /// `@Published` dictionary so `TerminalWorkspaceView` re-renders.
    var onStateChange: ((TerminalPane.ID, State?) -> Void)?

    private var chains: [TerminalPane.ID: Chain] = [:]
    private var pendingTimers: [TerminalPane.ID: ReconnectTimerToken] = [:]
    private var successTimers: [TerminalPane.ID: ReconnectTimerToken] = [:]

    private let scheduler: any ReconnectScheduling
    private let successGraceInterval: TimeInterval
    private let performReconnect: ReconnectPerformer
    private let now: () -> Date

    static let maxAttempts = ReconnectBackoffPolicy.maxAttempts

    init(
        scheduler: any ReconnectScheduling,
        successGraceInterval: TimeInterval = 15,
        now: @escaping () -> Date = Date.init,
        performReconnect: @escaping ReconnectPerformer
    ) {
        self.scheduler = scheduler
        self.successGraceInterval = successGraceInterval
        self.now = now
        self.performReconnect = performReconnect
    }

    // MARK: - Public entry points

    /// Call when a pane's SSH process exited while the pane was still present
    /// in the workspace — i.e. the model classified this as an *unexpected*
    /// disconnect, not a user-initiated close. Starts or continues the pane's
    /// backoff chain. Always cancels any timer already pending for `paneID`
    /// first, so calling this twice in a row for the same pane never stacks
    /// two competing timers.
    func handleUnexpectedExit(
        paneID: TerminalPane.ID,
        sessionID: TerminalSession.ID,
        alias: String,
        autoModeEnabled: Bool
    ) {
        cancelTimer(for: paneID)
        cancelSuccessTimer(for: paneID)

        guard autoModeEnabled else {
            chains[paneID] = nil
            setState(.awaitingManualReconnect, for: paneID)
            return
        }

        let previousAttempt = chains[paneID]?.attempt ?? 0
        let nextAttempt = previousAttempt + 1
        guard nextAttempt <= Self.maxAttempts else {
            chains[paneID] = nil
            setState(.exhausted(attempts: previousAttempt), for: paneID)
            return
        }

        chains[paneID] = Chain(attempt: nextAttempt, sessionID: sessionID, alias: alias)
        scheduleAttempt(paneID: paneID, attempt: nextAttempt)
    }

    /// User turned auto mode ON while this exact pane is sitting disconnected
    /// (band showing `.awaitingManualReconnect` / `.networkReturnedSuggestion`).
    /// Kicks off attempt 1 immediately instead of waiting for the next
    /// disconnect to notice the setting changed.
    func autoModeEnabledWhileDisconnected(
        paneID: TerminalPane.ID,
        sessionID: TerminalSession.ID,
        alias: String
    ) {
        switch states[paneID] {
        case .awaitingManualReconnect, .networkReturnedSuggestion:
            break
        default:
            return
        }
        guard chains[paneID] == nil else { return }
        chains[paneID] = Chain(attempt: 1, sessionID: sessionID, alias: alias)
        scheduleAttempt(paneID: paneID, attempt: 1)
    }

    /// User clicked "Vazgeç" on a live countdown: stop retrying automatically,
    /// fall back to the plain manual band.
    func cancelCountdown(paneID: TerminalPane.ID) {
        guard states[paneID] != nil else { return }
        cancelTimer(for: paneID)
        chains[paneID] = nil
        setState(.awaitingManualReconnect, for: paneID)
    }

    /// Network came back. Panes with a live countdown retry right away;
    /// panes waiting on the user (auto mode off) just get a nudge — no
    /// self-initiated connection (roadmap §8: user consent required).
    func networkBecameAvailable() {
        for (paneID, state) in states {
            switch state {
            case .countingDown:
                fireNow(paneID: paneID)
            case .awaitingManualReconnect:
                setState(.networkReturnedSuggestion, for: paneID)
            case .exhausted, .networkReturnedSuggestion:
                continue
            }
        }
    }

    /// Pane closed by the user (tab/pane close) or about to be replaced by a
    /// manual reconnect — stop tracking it so no stray timer ever fires
    /// against it, and so a manual retry always starts a fresh chain.
    func cancel(paneID: TerminalPane.ID) {
        cancelTimer(for: paneID)
        cancelSuccessTimer(for: paneID)
        chains[paneID] = nil
        setState(nil, for: paneID)
    }

    /// App is quitting, or the workspace is being restored from disk — drop
    /// every timer and every tracked pane so no countdown survives restart.
    func cancelAll() {
        scheduler.cancelAll()
        pendingTimers.removeAll()
        successTimers.removeAll()
        chains.removeAll()
        let ids = Array(states.keys)
        states.removeAll()
        for id in ids { onStateChange?(id, nil) }
    }

    // MARK: - Internals

    private func scheduleAttempt(paneID: TerminalPane.ID, attempt: Int) {
        let delay = ReconnectBackoffPolicy.delay(forAttempt: attempt)
        let fireDate = now().addingTimeInterval(delay)
        setState(.countingDown(attempt: attempt, maxAttempts: Self.maxAttempts, fireDate: fireDate), for: paneID)
        pendingTimers[paneID] = scheduler.schedule(after: delay) { [weak self] in
            self?.fire(paneID: paneID)
        }
    }

    /// Cancels the pending timer (if any) and runs the attempt immediately —
    /// used when the network comes back mid-countdown.
    private func fireNow(paneID: TerminalPane.ID) {
        cancelTimer(for: paneID)
        fire(paneID: paneID)
    }

    private func fire(paneID: TerminalPane.ID) {
        pendingTimers[paneID] = nil
        guard let chain = chains[paneID] else { return }

        guard let newPaneID = performReconnect(paneID, chain.sessionID, chain.alias) else {
            chains[paneID] = nil
            setState(.exhausted(attempts: chain.attempt), for: paneID)
            return
        }

        chains[paneID] = nil
        setState(nil, for: paneID)

        chains[newPaneID] = chain
        successTimers[newPaneID] = scheduler.schedule(after: successGraceInterval) { [weak self] in
            self?.confirmSuccess(paneID: newPaneID)
        }
    }

    /// The reconnected pane survived the grace interval without exiting
    /// again — reset the chain so the next disconnect starts fresh at 2s.
    private func confirmSuccess(paneID: TerminalPane.ID) {
        successTimers[paneID] = nil
        chains[paneID] = nil
    }

    private func cancelTimer(for paneID: TerminalPane.ID) {
        guard let token = pendingTimers[paneID] else { return }
        scheduler.cancel(token)
        pendingTimers[paneID] = nil
    }

    private func cancelSuccessTimer(for paneID: TerminalPane.ID) {
        guard let token = successTimers[paneID] else { return }
        scheduler.cancel(token)
        successTimers[paneID] = nil
    }

    private func setState(_ state: State?, for paneID: TerminalPane.ID) {
        states[paneID] = state
        onStateChange?(paneID, state)
    }
}
