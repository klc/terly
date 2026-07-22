import CoreGraphics
import Foundation

enum TerminalEngineIdentifier: String, Sendable {
    case swiftTerm = "swiftterm"
    case ghostty = "ghostty"
}

/// Faz 5: ⌘⌥arrow directional pane navigation.
enum PaneDirection: Equatable, Sendable {
    case left, right, up, down
}

struct TerminalProcessConfiguration: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let currentDirectoryURL: URL?
}

enum TerminalSplitAxis: String, Equatable, Sendable, Codable {
    case vertical
    case horizontal
}

struct TerminalPane: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case running
        case exited(Int32?)
    }

    let id: UUID
    let alias: String
    let process: TerminalProcessConfiguration
    var status: Status
    let startupExecution: StartupFlowExecution?
    var startupState: StartupFlowRunState?
    /// Phase A: per-pane startup override that wins over the alias-keyed
    /// startup profile map. `nil` preserves today's behavior exactly.
    let startupOverride: PaneStartupOverride?

    init(
        id: UUID = UUID(),
        alias: String,
        process: TerminalProcessConfiguration,
        status: Status = .running,
        startupExecution: StartupFlowExecution? = nil,
        startupState: StartupFlowRunState? = nil,
        startupOverride: PaneStartupOverride? = nil
    ) {
        self.id = id
        self.alias = alias
        self.process = process
        self.status = status
        self.startupExecution = startupExecution
        self.startupState = startupState
        self.startupOverride = startupOverride
    }
}

indirect enum TerminalPaneLayout: Equatable, Sendable {
    case pane(TerminalPane)
    case split(
        id: UUID,
        axis: TerminalSplitAxis,
        ratio: Double,
        first: TerminalPaneLayout,
        second: TerminalPaneLayout
    )

    static let minimumSplitRatio = 0.15
    static let maximumSplitRatio = 0.85

    var panes: [TerminalPane] {
        switch self {
        case let .pane(pane):
            return [pane]
        case let .split(_, _, _, first, second):
            return first.panes + second.panes
        }
    }

    static func tiled(_ panes: [TerminalPane], depth: Int = 0) -> TerminalPaneLayout? {
        guard !panes.isEmpty else { return nil }
        guard panes.count > 1 else { return .pane(panes[0]) }

        let midpoint = (panes.count + 1) / 2
        guard let first = tiled(Array(panes[..<midpoint]), depth: depth + 1),
              let second = tiled(Array(panes[midpoint...]), depth: depth + 1) else {
            return nil
        }

        return .split(
            id: UUID(),
            axis: depth.isMultiple(of: 2) ? .vertical : .horizontal,
            ratio: 0.5,
            first: first,
            second: second
        )
    }

    func pane(id: TerminalPane.ID) -> TerminalPane? {
        switch self {
        case let .pane(pane):
            return pane.id == id ? pane : nil
        case let .split(_, _, _, first, second):
            return first.pane(id: id) ?? second.pane(id: id)
        }
    }

    func splitting(
        paneID: TerminalPane.ID,
        with newPane: TerminalPane,
        axis: TerminalSplitAxis
    ) -> TerminalPaneLayout? {
        switch self {
        case let .pane(pane):
            guard pane.id == paneID else { return nil }
            return .split(
                id: UUID(),
                axis: axis,
                ratio: 0.5,
                first: .pane(pane),
                second: .pane(newPane)
            )

        case let .split(id, currentAxis, ratio, first, second):
            if let updatedFirst = first.splitting(paneID: paneID, with: newPane, axis: axis) {
                return .split(id: id, axis: currentAxis, ratio: ratio, first: updatedFirst, second: second)
            }
            if let updatedSecond = second.splitting(paneID: paneID, with: newPane, axis: axis) {
                return .split(id: id, axis: currentAxis, ratio: ratio, first: first, second: updatedSecond)
            }
            return nil
        }
    }

    func removing(paneID: TerminalPane.ID) -> TerminalPaneLayout? {
        switch self {
        case let .pane(pane):
            return pane.id == paneID ? nil : self

        case let .split(id, axis, ratio, first, second):
            let updatedFirst = first.removing(paneID: paneID)
            let updatedSecond = second.removing(paneID: paneID)

            switch (updatedFirst, updatedSecond) {
            case let (.some(first), .some(second)):
                return .split(id: id, axis: axis, ratio: ratio, first: first, second: second)
            case let (.some(remaining), .none), let (.none, .some(remaining)):
                return remaining
            case (.none, .none):
                return nil
            }
        }
    }

    func updatingPaneStatus(
        paneID: TerminalPane.ID,
        status: TerminalPane.Status
    ) -> TerminalPaneLayout {
        switch self {
        case .pane(var pane):
            if pane.id == paneID {
                pane.status = status
            }
            return .pane(pane)

        case let .split(id, axis, ratio, first, second):
            return .split(
                id: id,
                axis: axis,
                ratio: ratio,
                first: first.updatingPaneStatus(paneID: paneID, status: status),
                second: second.updatingPaneStatus(paneID: paneID, status: status)
            )
        }
    }

    func updatingStartupState(
        paneID: TerminalPane.ID,
        state: StartupFlowRunState
    ) -> TerminalPaneLayout {
        switch self {
        case .pane(var pane):
            if pane.id == paneID {
                pane.startupState = state
            }
            return .pane(pane)

        case let .split(id, axis, ratio, first, second):
            return .split(
                id: id,
                axis: axis,
                ratio: ratio,
                first: first.updatingStartupState(paneID: paneID, state: state),
                second: second.updatingStartupState(paneID: paneID, state: state)
            )
        }
    }

    func replacing(
        paneID: TerminalPane.ID,
        with newPane: TerminalPane
    ) -> TerminalPaneLayout {
        switch self {
        case let .pane(pane):
            return pane.id == paneID ? .pane(newPane) : self

        case let .split(id, axis, ratio, first, second):
            return .split(
                id: id,
                axis: axis,
                ratio: ratio,
                first: first.replacing(paneID: paneID, with: newPane),
                second: second.replacing(paneID: paneID, with: newPane)
            )
        }
    }

    func updatingRatio(splitID: UUID, ratio: Double) -> TerminalPaneLayout {
        let clamped = min(max(ratio, Self.minimumSplitRatio), Self.maximumSplitRatio)
        switch self {
        case .pane:
            return self

        case let .split(id, axis, currentRatio, first, second):
            return .split(
                id: id,
                axis: axis,
                ratio: id == splitID ? clamped : currentRatio,
                first: first.updatingRatio(splitID: splitID, ratio: ratio),
                second: second.updatingRatio(splitID: splitID, ratio: ratio)
            )
        }
    }

    func swappingPanes(_ a: TerminalPane.ID, _ b: TerminalPane.ID) -> TerminalPaneLayout? {
        guard a != b, pane(id: a) != nil, pane(id: b) != nil else { return nil }

        func swap(_ layout: TerminalPaneLayout) -> TerminalPaneLayout {
            switch layout {
            case let .pane(pane):
                if pane.id == a, let paneB = self.pane(id: b) {
                    return .pane(paneB)
                }
                if pane.id == b, let paneA = self.pane(id: a) {
                    return .pane(paneA)
                }
                return layout

            case let .split(id, axis, ratio, first, second):
                return .split(
                    id: id,
                    axis: axis,
                    ratio: ratio,
                    first: swap(first),
                    second: swap(second)
                )
            }
        }

        return swap(self)
    }

    /// Normalized (0–1) frame per pane, respecting each split's `ratio`. Pure
    /// geometry, no view/state dependency — moved here from
    /// `TerminalWorkspaceView.layoutGeometry` (Faz 5) so it's directly
    /// testable and `nearestPane(from:direction:)` can hit-test the same
    /// frames the view draws. Divider geometry stays view-side.
    func normalizedFrames(in frame: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> [TerminalPane.ID: CGRect] {
        switch self {
        case let .pane(pane):
            return [pane.id: frame]

        case let .split(_, axis, ratio, first, second):
            let firstFrame: CGRect
            let secondFrame: CGRect

            switch axis {
            case .vertical:
                let firstWidth = frame.width * ratio
                firstFrame = CGRect(x: frame.minX, y: frame.minY, width: firstWidth, height: frame.height)
                secondFrame = CGRect(x: frame.minX + firstWidth, y: frame.minY, width: frame.width - firstWidth, height: frame.height)
            case .horizontal:
                let firstHeight = frame.height * ratio
                firstFrame = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: firstHeight)
                secondFrame = CGRect(x: frame.minX, y: frame.minY + firstHeight, width: frame.width, height: frame.height - firstHeight)
            }

            var frames = first.normalizedFrames(in: firstFrame)
            frames.merge(second.normalizedFrames(in: secondFrame)) { current, _ in current }
            return frames
        }
    }

    /// Faz 5: from `paneID`'s center, the pane whose center is nearest in
    /// `direction` — a strict half-plane filter (nothing behind/level with
    /// the source counts) followed by nearest-by-squared-distance. Returns
    /// `nil` when nothing lies that way (edge of the grid) or `paneID` isn't
    /// part of this layout.
    func nearestPane(from paneID: TerminalPane.ID, direction: PaneDirection) -> TerminalPane.ID? {
        let frames = normalizedFrames()
        guard let sourceFrame = frames[paneID] else { return nil }
        let sourceCenter = CGPoint(x: sourceFrame.midX, y: sourceFrame.midY)
        let epsilon: CGFloat = 0.001

        let candidates: [(id: TerminalPane.ID, distanceSquared: CGFloat)] = frames.compactMap { id, candidateFrame in
            guard id != paneID else { return nil }
            let center = CGPoint(x: candidateFrame.midX, y: candidateFrame.midY)
            let isInDirection: Bool
            switch direction {
            case .left: isInDirection = center.x < sourceCenter.x - epsilon
            case .right: isInDirection = center.x > sourceCenter.x + epsilon
            case .up: isInDirection = center.y < sourceCenter.y - epsilon
            case .down: isInDirection = center.y > sourceCenter.y + epsilon
            }
            guard isInDirection else { return nil }
            let dx = center.x - sourceCenter.x
            let dy = center.y - sourceCenter.y
            return (id, dx * dx + dy * dy)
        }

        return candidates.min { $0.distanceSquared < $1.distanceSquared }?.id
    }
}

struct TerminalSession: Identifiable, Equatable, Sendable {
    let id: UUID
    let hostID: Int
    let alias: String
    var customTitle: String?
    var layout: TerminalPaneLayout
    var activePaneID: TerminalPane.ID
    var synchronizedPaneIDs: Set<TerminalPane.ID>
    /// Faz 6: pane zoom. Session-local UI state only — never persisted (not
    /// part of `PersistedSession`), so a relaunch always starts unzoomed.
    var zoomedPaneID: TerminalPane.ID?

    init(
        id: UUID = UUID(),
        hostID: Int,
        alias: String,
        initialPane: TerminalPane,
        customTitle: String? = nil
    ) {
        self.id = id
        self.hostID = hostID
        self.alias = alias
        self.customTitle = customTitle
        layout = .pane(initialPane)
        activePaneID = initialPane.id
        synchronizedPaneIDs = []
        zoomedPaneID = nil
    }

    init(
        id: UUID = UUID(),
        hostID: Int,
        alias: String,
        layout: TerminalPaneLayout,
        activePaneID: TerminalPane.ID,
        customTitle: String? = nil
    ) {
        self.id = id
        self.hostID = hostID
        self.alias = alias
        self.customTitle = customTitle
        self.layout = layout
        self.activePaneID = activePaneID
        synchronizedPaneIDs = []
        zoomedPaneID = nil
    }

    var panes: [TerminalPane] { layout.panes }
    var activePane: TerminalPane? { layout.pane(id: activePaneID) }
    var isStartupRunning: Bool {
        panes.contains {
            if case .running = $0.startupState { return true }
            return false
        }
    }

    var status: TerminalPane.Status {
        if panes.contains(where: { $0.status == .running }) {
            return .running
        }
        return activePane?.status ?? panes.first?.status ?? .exited(nil)
    }
}

enum TerminalWorkspaceError: LocalizedError, Equatable {
    case unsavedChanges
    case noConcreteAlias
    case noConnections

    var errorDescription: String? {
        switch self {
        case .unsavedChanges:
            return String(localized: "Save your changes before opening the connection. SSH uses the ~/.ssh/config file on disk.")
        case .noConcreteAlias:
            return String(localized: "Wildcard or negated Host patterns can't be opened directly as a connection. Select a specific alias.")
        case .noConnections:
            return String(localized: "No SSH connection found to open.")
        }
    }
}

struct SSHLaunchPlanBuilder: Sendable {
    let sshURL: URL
    let baseEnvironment: [String: String]
    let currentDirectoryURL: URL?
    let startupBuilder: StartupFlowBootstrapBuilder

    init(
        sshURL: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectoryURL: URL? = FileManager.default.homeDirectoryForCurrentUser,
        startupBuilder: StartupFlowBootstrapBuilder = StartupFlowBootstrapBuilder()
    ) {
        self.sshURL = sshURL
        self.baseEnvironment = baseEnvironment
        self.currentDirectoryURL = currentDirectoryURL
        self.startupBuilder = startupBuilder
    }

    func makeSession(
        hostID: Int,
        alias: String,
        startupProfile: StartupFlowProfile? = nil,
        skipStartup: Bool = false
    ) throws -> TerminalSession {
        let normalizedAlias = try Self.normalizedAlias(alias)
        let pane = try makePane(
            alias: normalizedAlias,
            startupProfile: startupProfile,
            skipStartup: skipStartup
        )
        return TerminalSession(hostID: hostID, alias: normalizedAlias, initialPane: pane)
    }

    func makePane(
        id: UUID = UUID(),
        alias: String,
        startupProfile: StartupFlowProfile? = nil,
        skipStartup: Bool = false,
        startupOverride: PaneStartupOverride? = nil
    ) throws -> TerminalPane {
        if alias == "Yerel Terminal" || alias == "Local Terminal" {
            let shellPath = baseEnvironment["SHELL"] ?? "/bin/zsh"
            let shellURL = URL(fileURLWithPath: shellPath)
            var environment = SSHProcessEnvironment.interactive(base: baseEnvironment)
            environment["TERM"] = "xterm-256color"
            environment["COLORTERM"] = "truecolor"
            
            return TerminalPane(
                id: id,
                alias: alias,
                process: TerminalProcessConfiguration(
                    executableURL: shellURL,
                    // Login shell: /etc/zprofile (path_helper) ve ~/.zprofile
                    // çalışsın diye — GUI'den başlayan app'in PATH'inde
                    // /opt/homebrew/bin yok. Terminal.app da böyle yapar.
                    arguments: ["-l"],
                    environment: environment,
                    currentDirectoryURL: currentDirectoryURL
                ),
                startupExecution: nil,
                startupState: nil
            )
        }

        let normalizedAlias = try Self.normalizedAlias(alias)

        var environment = SSHProcessEnvironment.interactive(base: baseEnvironment)
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"

        // Phase A: an explicit per-pane override wins over the alias-keyed
        // profile. This must NOT fall back to `startupProfile` when the
        // override resolves to nil (`.suppressed`, a blank `.command`, or an
        // empty-step `.flow`) — that nil IS the resolved answer.
        let resolvedProfile: StartupFlowProfile?
        if let startupOverride {
            resolvedProfile = startupOverride.effectiveProfile(alias: normalizedAlias)
        } else {
            resolvedProfile = startupProfile
        }

        let execution = try resolvedProfile.flatMap { profile in
            profile.steps.isEmpty ? nil : try startupBuilder.build(profile: profile)
        }
        let shouldRunStartup = execution != nil && resolvedProfile?.automaticallyRun == true && !skipStartup
        let arguments = shouldRunStartup
            ? [
                "-tt",
                "-o", "RemoteCommand=none",
                "-o", "SessionType=default",
                "--", normalizedAlias, execution!.command,
            ]
            : ["--", normalizedAlias]
        let startupState: StartupFlowRunState? = execution.map { _ in
            if skipStartup && resolvedProfile?.automaticallyRun == true { return .skipped }
            return shouldRunStartup ? .running(stepIndex: nil) : .ready
        }

        return TerminalPane(
            id: id,
            alias: normalizedAlias,
            process: TerminalProcessConfiguration(
                executableURL: sshURL,
                arguments: arguments,
                environment: environment,
                currentDirectoryURL: currentDirectoryURL
            ),
            startupExecution: execution,
            startupState: startupState,
            startupOverride: startupOverride
        )
    }

    static func isConcreteAlias(_ alias: String) -> Bool {
        !alias.isEmpty &&
            !alias.hasPrefix("!") &&
            !alias.contains("*") &&
            !alias.contains("?")
    }

    private static func normalizedAlias(_ alias: String) throws -> String {
        let normalizedAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isConcreteAlias(normalizedAlias) else {
            throw TerminalWorkspaceError.noConcreteAlias
        }
        return normalizedAlias
    }
}

extension TerminalSession {
    var displayName: String {
        if alias == "Yerel Terminal" || alias == "Local Terminal" {
            return String(localized: "Local Terminal")
        }
        return alias
    }

    var displayTitle: String {
        customTitle ?? displayName
    }
}

extension TerminalPane {
    var displayName: String {
        if alias == "Yerel Terminal" || alias == "Local Terminal" {
            return String(localized: "Local Terminal")
        }
        return alias
    }
}
