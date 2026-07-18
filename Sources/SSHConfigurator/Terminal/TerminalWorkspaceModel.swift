import AppKit
import Combine
import Foundation

@MainActor
final class TerminalWorkspaceModel: ObservableObject {
    @Published private(set) var sessions: [TerminalSession] = [] {
        didSet {
            scheduleSave()
        }
    }
    @Published var selectedSessionID: TerminalSession.ID? {
        didSet {
            scheduleSave()
        }
    }
    @Published private(set) var errorMessage: String?
    /// WP7: per-pane automatic-reconnect UI state (countdown / exhausted /
    /// awaiting manual reconnect / network-back suggestion), mirrored from
    /// `autoReconnectManager` so `TerminalWorkspaceView` can observe it.
    @Published private(set) var paneReconnectStates: [TerminalPane.ID: AutoReconnectManager.State] = [:]
    /// WP7: aliases with automatic reconnect opted in (host-per-host, default
    /// off), mirrored from `autoReconnectSettingsStore`.
    @Published private(set) var autoReconnectEnabledAliases: Set<String> = []

    /// Looks up the startup flow profile for an alias when auto-reconnecting.
    /// The model doesn't own `StartupFlowLibrary` (that's owned alongside the
    /// view), so `ContentView` wires this once at launch — mirrors exactly
    /// what a manual reconnect click already passes in from the view layer.
    var startupProfileProvider: ((String) -> StartupFlowProfile?)?

    private let launchPlanBuilder: SSHLaunchPlanBuilder
    private let workspaceStore: any WorkspaceLayoutPersisting
    private let autoReconnectSettingsStore: any AutoReconnectSettingsPersisting
    private let networkObserver: any NetworkPathObserving
    private var autoReconnectManager: AutoReconnectManager!
    private var isRestoring = false
    private var saveDebounceTask: Task<Void, Never>?
    private var willTerminateCancellable: AnyCancellable?
    /// Panes currently being torn down through `closeTab`/`closePane` — lets
    /// `processDidExit` tell a user-initiated close apart from an unexpected
    /// disconnect (WP7). Cleared as soon as the matching exit is observed.
    private var userClosedPaneIDs: Set<TerminalPane.ID> = []
    private static let saveDebounceNanoseconds: UInt64 = 500_000_000

    init(
        launchPlanBuilder: SSHLaunchPlanBuilder = SSHLaunchPlanBuilder(),
        workspaceStore: any WorkspaceLayoutPersisting = WorkspaceLayoutStore(),
        autoReconnectSettingsStore: any AutoReconnectSettingsPersisting = AutoReconnectSettingsStore(),
        reconnectScheduler: any ReconnectScheduling = RealReconnectScheduler(),
        networkObserver: any NetworkPathObserving = NWPathAvailabilityObserver()
    ) {
        self.launchPlanBuilder = launchPlanBuilder
        self.workspaceStore = workspaceStore
        self.autoReconnectSettingsStore = autoReconnectSettingsStore
        self.networkObserver = networkObserver

        if let loaded = try? autoReconnectSettingsStore.load() {
            autoReconnectEnabledAliases = loaded.enabledAliases
        }

        willTerminateCancellable = NotificationCenter.default
            .publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                self?.flushPendingSave()
                self?.autoReconnectManager.cancelAll()
                self?.networkObserver.stop()
            }

        autoReconnectManager = AutoReconnectManager(scheduler: reconnectScheduler) { [weak self] paneID, sessionID, alias in
            guard let self else { return nil }
            return self.reconnectPaneReturningNewID(
                paneID,
                in: sessionID,
                startupProfile: self.startupProfileProvider?(alias)
            )
        }
        autoReconnectManager.onStateChange = { [weak self] paneID, state in
            self?.paneReconnectStates[paneID] = state
        }

        networkObserver.onBecomeSatisfied = { [weak self] in
            self?.autoReconnectManager.networkBecameAvailable()
        }
        networkObserver.start()
    }

    deinit {
        saveDebounceTask?.cancel()
        // `willTerminateCancellable` (Combine's `AnyCancellable`) cancels itself
        // automatically when it deallocates, so no explicit cancellation is needed
        // (and isn't possible here: it's non-Sendable and this deinit is nonisolated).
    }

    /// Debounces `saveWorkspace()` so rapid-fire mutations (tab switches, pane
    /// selection, per-step startup updates) coalesce into a single disk write.
    private func scheduleSave() {
        guard !isRestoring else { return }
        saveDebounceTask?.cancel()
        saveDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.saveDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            self?.saveWorkspace()
        }
    }

    /// Immediately flushes any pending debounced save. Used on app termination
    /// so the last in-flight change isn't lost. Internal (not private) so
    /// tests can flush the debounce deterministically instead of sleeping.
    func flushPendingSave() {
        guard saveDebounceTask != nil else { return }
        saveDebounceTask?.cancel()
        saveDebounceTask = nil
        saveWorkspace()
    }

    var selectedSession: TerminalSession? {
        guard let selectedSessionID else { return nil }
        return sessions.first { $0.id == selectedSessionID }
    }

    @discardableResult
    func openLocalTerminal() -> Bool {
        let localAlias = "Yerel Terminal"

        do {
            let pane = try launchPlanBuilder.makePane(alias: localAlias)
            let session = TerminalSession(
                hostID: -1,
                alias: localAlias,
                initialPane: pane
            )
            sessions.removeAll { $0.hostID == -1 && $0.alias == localAlias && Self.isExited($0.status) }
            sessions.append(session)
            selectedSessionID = session.id
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func openConnection(
        hostID: Int,
        alias: String,
        hasUnsavedChanges: Bool,
        startupProfile: StartupFlowProfile? = nil,
        skipStartup: Bool = false
    ) -> Bool {
        openConnections(
            [SSHConnectionTarget(hostID: hostID, alias: alias)],
            hasUnsavedChanges: hasUnsavedChanges,
            startupProfiles: startupProfile.map { [alias: $0] } ?? [:],
            skipAllStartups: skipStartup
        )
    }

    @discardableResult
    func openConnections(
        _ targets: [SSHConnectionTarget],
        hasUnsavedChanges: Bool,
        startupProfiles: [String: StartupFlowProfile] = [:],
        skipAllStartups: Bool = false
    ) -> Bool {
        var seenTargets: Set<SSHConnectionTarget> = []
        let uniqueTargets = targets.filter { seenTargets.insert($0).inserted }
        guard !uniqueTargets.isEmpty else {
            errorMessage = TerminalWorkspaceError.noConnections.localizedDescription
            return false
        }

        let targetsRequiringNewSession = uniqueTargets.filter { target in
            !sessions.contains {
                $0.hostID == target.hostID &&
                    $0.alias == target.alias &&
                    !Self.isExited($0.status)
            }
        }

        guard targetsRequiringNewSession.isEmpty || !hasUnsavedChanges else {
            errorMessage = TerminalWorkspaceError.unsavedChanges.localizedDescription
            return false
        }

        do {
            let newSessions = try Dictionary(
                uniqueKeysWithValues: targetsRequiringNewSession.map { target in
                    (
                        target,
                        try launchPlanBuilder.makeSession(
                            hostID: target.hostID,
                            alias: target.alias,
                            startupProfile: startupProfiles[target.alias],
                            skipStartup: skipAllStartups
                        )
                    )
                }
            )

            var updatedSessions = sessions
            var lastSelectedSessionID: TerminalSession.ID?

            for target in uniqueTargets {
                if let existing = updatedSessions.first(where: {
                    $0.hostID == target.hostID &&
                        $0.alias == target.alias &&
                        !Self.isExited($0.status)
                }) {
                    lastSelectedSessionID = existing.id
                    continue
                }

                updatedSessions.removeAll {
                    $0.hostID == target.hostID &&
                        $0.alias == target.alias &&
                        Self.isExited($0.status)
                }
                if let session = newSessions[target] {
                    updatedSessions.append(session)
                    lastSelectedSessionID = session.id
                }
            }

            sessions = updatedSessions
            selectedSessionID = lastSelectedSessionID
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func openConnectionGroupInSplitSession(
        groupID: UUID,
        title: String,
        targets: [SSHConnectionTarget],
        hasUnsavedChanges: Bool,
        startupProfiles: [String: StartupFlowProfile] = [:],
        skipAllStartups: Bool = false
    ) -> Bool {
        var seenTargets: Set<SSHConnectionTarget> = []
        let uniqueTargets = targets.filter { seenTargets.insert($0).inserted }
        guard !uniqueTargets.isEmpty else {
            errorMessage = TerminalWorkspaceError.noConnections.localizedDescription
            return false
        }

        let aliases = uniqueTargets.map(\.alias)
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionTitle = normalizedTitle.isEmpty ? aliases[0] : normalizedTitle
        if let existingSession = sessions.first(where: {
            $0.groupID == groupID &&
                $0.alias == sessionTitle &&
                $0.panes.map(\.alias) == aliases &&
                $0.panes.allSatisfy { !Self.isExited($0.status) }
        }) {
            selectedSessionID = existingSession.id
            errorMessage = nil
            return true
        }

        guard !hasUnsavedChanges else {
            errorMessage = TerminalWorkspaceError.unsavedChanges.localizedDescription
            return false
        }

        do {
            let newSession = try launchPlanBuilder.makeGroupedSession(
                groupID: groupID,
                title: title,
                targets: uniqueTargets,
                startupProfiles: startupProfiles,
                skipAllStartups: skipAllStartups
            )
            sessions.removeAll { $0.groupID == groupID }
            sessions.append(newSession)
            selectedSessionID = newSession.id
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func closeTab(_ sessionID: TerminalSession.ID) {
        if let session = sessions.first(where: { $0.id == sessionID }) {
            markPanesAsUserClosed(session.panes.map(\.id))
        }
        sessions.removeAll { $0.id == sessionID }
        if selectedSessionID == sessionID {
            selectedSessionID = sessions.last?.id
        }
    }

    /// Marks panes as closed-by-the-user (WP7 exit classification) and drops
    /// any pending auto-reconnect timer/state for them, so a tab/pane close
    /// never triggers the "connection dropped" band or a stray reconnect.
    private func markPanesAsUserClosed(_ paneIDs: [TerminalPane.ID]) {
        for paneID in paneIDs {
            userClosedPaneIDs.insert(paneID)
            autoReconnectManager.cancel(paneID: paneID)
        }
    }

    @discardableResult
    func splitActivePane(
        in sessionID: TerminalSession.ID,
        axis: TerminalSplitAxis,
        startupProfile: StartupFlowProfile? = nil
    ) -> Bool {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return false }
        let session = sessions[index]

        do {
            guard let activePane = session.activePane else { return false }
            let newPane = try launchPlanBuilder.makePane(
                alias: activePane.alias,
                startupProfile: startupProfile,
                skipStartup: activePane.startupState == .skipped
            )
            guard let updatedLayout = session.layout.splitting(
                paneID: session.activePaneID,
                with: newPane,
                axis: axis
            ) else { return false }

            sessions[index].layout = updatedLayout
            sessions[index].activePaneID = newPane.id
            sessions[index].synchronizedPaneIDs = []
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func selectPane(
        _ paneID: TerminalPane.ID,
        in sessionID: TerminalSession.ID,
        extendingSynchronization: Bool = false
    ) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
              sessions[index].layout.pane(id: paneID) != nil else { return }

        if extendingSynchronization {
            guard !sessions[index].isStartupRunning else { return }
            let activePaneID = sessions[index].activePaneID
            if sessions[index].synchronizedPaneIDs.isEmpty {
                guard paneID != activePaneID else { return }
                sessions[index].synchronizedPaneIDs = [activePaneID, paneID]
            } else if sessions[index].synchronizedPaneIDs.contains(paneID) {
                sessions[index].synchronizedPaneIDs.remove(paneID)
                if sessions[index].synchronizedPaneIDs.count < 2 {
                    sessions[index].synchronizedPaneIDs = []
                }
            } else {
                sessions[index].synchronizedPaneIDs.insert(paneID)
            }
            return
        }

        sessions[index].activePaneID = paneID
        sessions[index].synchronizedPaneIDs = []
    }

    func clearPaneSynchronization(in sessionID: TerminalSession.ID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].synchronizedPaneIDs = []
    }

    func closePane(_ paneID: TerminalPane.ID, in sessionID: TerminalSession.ID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
              sessions[index].layout.pane(id: paneID) != nil else { return }
        markPanesAsUserClosed([paneID])

        if sessions[index].panes.count == 1 {
            closeTab(sessionID)
            return
        }

        guard let updatedLayout = sessions[index].layout.removing(paneID: paneID) else {
            closeTab(sessionID)
            return
        }

        sessions[index].layout = updatedLayout
        sessions[index].synchronizedPaneIDs.remove(paneID)
        if sessions[index].synchronizedPaneIDs.count < 2 {
            sessions[index].synchronizedPaneIDs = []
        }
        if sessions[index].activePaneID == paneID {
            sessions[index].activePaneID = updatedLayout.panes[0].id
        }
    }

    func processDidExit(
        sessionID: TerminalSession.ID,
        paneID: TerminalPane.ID,
        exitCode: Int32?
    ) {
        let wasUserClosed = userClosedPaneIDs.remove(paneID) != nil

        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else {
            autoReconnectManager.cancel(paneID: paneID)
            return
        }
        let paneBeforeExit = sessions[index].layout.pane(id: paneID)
        sessions[index].layout = sessions[index].layout.updatingPaneStatus(
            paneID: paneID,
            status: .exited(exitCode)
        )
        if case let .running(stepIndex) = paneBeforeExit?.startupState {
            let failedStep = stepIndex ?? 0
            let suffix = exitCode.map { " (çıkış: \($0))" } ?? ""
            sessions[index].layout = sessions[index].layout.updatingStartupState(
                paneID: paneID,
                state: .failed(
                    stepIndex: failedStep,
                    message: "SSH süreci başlangıç akışı tamamlanmadan kapandı\(suffix)."
                )
            )
        }
        sessions[index].synchronizedPaneIDs.remove(paneID)
        if sessions[index].synchronizedPaneIDs.count < 2 {
            sessions[index].synchronizedPaneIDs = []
        }

        // WP7: hostID -1 is the local shell (no SSH host to reconnect to).
        // Otherwise, any exit that isn't the user's own tab/pane close counts
        // as an unexpected disconnect — including a plain `exit` typed into
        // the remote shell (see ReconnectExitClassifier).
        guard sessions[index].hostID != -1, let pane = paneBeforeExit else {
            autoReconnectManager.cancel(paneID: paneID)
            return
        }
        let isUnexpected = ReconnectExitClassifier.isUnexpectedDisconnect(
            paneStillPresent: true,
            userInitiatedClose: wasUserClosed
        )
        guard isUnexpected else {
            autoReconnectManager.cancel(paneID: paneID)
            return
        }
        autoReconnectManager.handleUnexpectedExit(
            paneID: paneID,
            sessionID: sessionID,
            alias: pane.alias,
            autoModeEnabled: autoReconnectEnabledAliases.contains(pane.alias)
        )
    }

    func startupEvent(
        _ event: StartupFlowMarkerEvent,
        sessionID: TerminalSession.ID,
        paneID: TerminalPane.ID
    ) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
              let pane = sessions[index].layout.pane(id: paneID),
              let execution = pane.startupExecution else { return }

        let state: StartupFlowRunState
        switch event {
        case let .running(stepIndex):
            state = .running(stepIndex: stepIndex)
            sessions[index].synchronizedPaneIDs = []
        case .completed:
            state = .completed
        case let .failed(stepIndex, exitCode):
            let summary = execution.stepSummaries.indices.contains(stepIndex)
                ? execution.stepSummaries[stepIndex]
                : "Bilinmeyen adım"
            state = .failed(
                stepIndex: stepIndex,
                message: "\(summary) başarısız oldu (çıkış: \(exitCode))."
            )
        }
        sessions[index].layout = sessions[index].layout.updatingStartupState(
            paneID: paneID,
            state: state
        )
    }

    func prepareManualStartup(
        sessionID: TerminalSession.ID,
        paneID: TerminalPane.ID
    ) -> String? {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
              let pane = sessions[index].layout.pane(id: paneID),
              let execution = pane.startupExecution,
              pane.status == .running else { return nil }

        sessions[index].synchronizedPaneIDs = []
        sessions[index].layout = sessions[index].layout.updatingStartupState(
            paneID: paneID,
            state: .running(stepIndex: nil)
        )
        return execution.command + "\r"
    }

    func manualStartupSendFailed(
        sessionID: TerminalSession.ID,
        paneID: TerminalPane.ID
    ) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].layout = sessions[index].layout.updatingStartupState(
            paneID: paneID,
            state: .failed(stepIndex: 0, message: "Başlangıç komutu terminale gönderilemedi.")
        )
    }

    func dismissError() {
        errorMessage = nil
    }

    private static func isExited(_ status: TerminalPane.Status) -> Bool {
        if case .exited = status { return true }
        return false
    }

    func saveWorkspace() {
        guard !isRestoring else { return }
        let persistedSessions = sessions.map { session in
            PersistedSession(
                id: session.id,
                hostID: session.hostID,
                alias: session.alias,
                groupID: session.groupID,
                layout: session.layout.persisted,
                activePaneID: session.activePaneID,
                synchronizedPaneIDs: Array(session.synchronizedPaneIDs)
            )
        }
        let workspace = PersistedWorkspace(
            sessions: persistedSessions,
            selectedSessionID: selectedSessionID
        )
        try? workspaceStore.save(workspace)
    }

    func restoreWorkspace(
        startupProfiles: [String: StartupFlowProfile] = [:],
        validAliases: Set<String>? = nil
    ) {
        isRestoring = true
        defer { isRestoring = false }

        // Restored panes always come back `.running` (layout persistence
        // never stores exit status), so no countdown should legitimately
        // survive a restore — clear defensively anyway so a re-restore
        // during the same run never resurrects a stale one.
        autoReconnectManager.cancelAll()
        userClosedPaneIDs.removeAll()

        do {
            let persisted = try workspaceStore.load()
            var restoredSessions: [TerminalSession] = []

            for persistedSession in persisted.sessions {
                if let validAliases,
                   persistedSession.alias != "Yerel Terminal" && persistedSession.alias != "Local Terminal",
                   !validAliases.contains(persistedSession.alias) {
                    continue
                }

                do {
                    let restoredLayout = try persistedSession.layout.restore(
                        builder: launchPlanBuilder,
                        startupProfiles: startupProfiles
                    )
                    
                    var session = TerminalSession(
                        id: persistedSession.id,
                        hostID: persistedSession.hostID,
                        alias: persistedSession.alias,
                        groupID: persistedSession.groupID,
                        layout: restoredLayout,
                        activePaneID: persistedSession.activePaneID
                    )
                    session.synchronizedPaneIDs = Set(persistedSession.synchronizedPaneIDs)
                    restoredSessions.append(session)
                } catch {
                    print("Failed to restore session \(persistedSession.alias): \(error)")
                }
            }

            self.sessions = restoredSessions
            self.selectedSessionID = persisted.selectedSessionID
        } catch {
            print("Failed to load persisted workspace: \(error)")
        }
    }

    @discardableResult
    func reconnectPane(
        _ paneID: TerminalPane.ID,
        in sessionID: TerminalSession.ID,
        startupProfile: StartupFlowProfile?
    ) -> Bool {
        reconnectPaneReturningNewID(paneID, in: sessionID, startupProfile: startupProfile) != nil
    }

    /// Same reconnect as above, but returns the replacement pane's ID so
    /// callers that need to keep tracking it (WP7's `AutoReconnectManager`)
    /// can. `reconnectPane` above is the pre-existing public Bool-returning
    /// API and stays unchanged for existing call sites/tests.
    @discardableResult
    private func reconnectPaneReturningNewID(
        _ paneID: TerminalPane.ID,
        in sessionID: TerminalSession.ID,
        startupProfile: StartupFlowProfile?
    ) -> TerminalPane.ID? {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
              let pane = sessions[index].layout.pane(id: paneID) else {
            return nil
        }

        do {
            let newPaneID = UUID()
            let newPane = try launchPlanBuilder.makePane(
                id: newPaneID,
                alias: pane.alias,
                startupProfile: startupProfile,
                skipStartup: false
            )

            let updatedLayout = sessions[index].layout.replacing(paneID: pane.id, with: newPane)
            sessions[index].layout = updatedLayout

            if sessions[index].activePaneID == pane.id {
                sessions[index].activePaneID = newPaneID
            }

            if sessions[index].synchronizedPaneIDs.contains(pane.id) {
                sessions[index].synchronizedPaneIDs.remove(pane.id)
                sessions[index].synchronizedPaneIDs.insert(newPaneID)
            }

            errorMessage = nil
            return newPaneID
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    // MARK: - WP7: automatic reconnect

    /// The pane's own manual "Yeniden Bağlan" button goes through here rather
    /// than calling `reconnectPane` directly: it cancels any pending
    /// auto-reconnect timer for this exact pane first, so a manual click
    /// never races with (and double-fires alongside) a scheduled automatic
    /// attempt.
    @discardableResult
    func manualReconnectRequested(
        _ paneID: TerminalPane.ID,
        in sessionID: TerminalSession.ID,
        startupProfile: StartupFlowProfile?
    ) -> Bool {
        autoReconnectManager.cancel(paneID: paneID)
        return reconnectPane(paneID, in: sessionID, startupProfile: startupProfile)
    }

    func isAutoReconnectEnabled(forAlias alias: String) -> Bool {
        autoReconnectEnabledAliases.contains(alias)
    }

    /// Toggles the per-host auto-reconnect opt-in (persisted, default off).
    /// If this exact pane is currently sitting disconnected waiting on the
    /// user, flipping the setting on immediately starts a countdown instead
    /// of waiting for the next disconnect to notice; flipping it off cancels
    /// any countdown in progress.
    func setAutoReconnectEnabled(
        _ enabled: Bool,
        forAlias alias: String,
        paneID: TerminalPane.ID,
        sessionID: TerminalSession.ID
    ) {
        if enabled {
            autoReconnectEnabledAliases.insert(alias)
        } else {
            autoReconnectEnabledAliases.remove(alias)
        }
        try? autoReconnectSettingsStore.save(
            AutoReconnectSettingsState(enabledAliases: autoReconnectEnabledAliases)
        )

        if enabled {
            autoReconnectManager.autoModeEnabledWhileDisconnected(
                paneID: paneID,
                sessionID: sessionID,
                alias: alias
            )
        } else {
            // Same effect as the user hitting "Vazgeç": stop any countdown/
            // exhausted-retry state and fall back to the plain manual band.
            autoReconnectManager.cancelCountdown(paneID: paneID)
        }
    }

    /// User clicked "Vazgeç" on a live countdown band.
    func cancelReconnectCountdown(_ paneID: TerminalPane.ID) {
        autoReconnectManager.cancelCountdown(paneID: paneID)
    }
}
