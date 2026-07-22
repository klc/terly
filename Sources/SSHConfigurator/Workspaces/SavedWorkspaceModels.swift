import Foundation

/// Phase B: a named snapshot of the live tab/split layout — reopened later
/// *appended* to whatever is already open (see `TerminalWorkspaceModel
/// .openSavedWorkspace`). Distinct from `WorkspaceLayoutStore`'s
/// `PersistedWorkspace`, which is the session-restore auto-save mirror of
/// "what's open right now" and is replaced wholesale on every launch.
///
/// Pane IDs inside a saved workspace are snapshot-internal identity only —
/// `activePaneID`/`synchronizedPaneIDs` refer to them, but reopening always
/// mints fresh `UUID`s (see `openSavedWorkspace`) so the same saved workspace
/// can be opened multiple times side by side.
struct SavedWorkspacePane: Codable, Equatable, Sendable {
    let id: UUID
    let alias: String
    /// Phase A per-pane startup override, carried through verbatim.
    let startup: PaneStartupOverride?

    init(id: UUID, alias: String, startup: PaneStartupOverride? = nil) {
        self.id = id
        self.alias = alias
        self.startup = startup
    }
}

/// Mirrors `PersistedPaneLayout`'s shape and "type" discriminator, but with
/// no split `id` — a fresh split ID is generated every time the workspace is
/// opened, since split IDs are only ever used to address a live split's
/// ratio and have no meaning across snapshots.
indirect enum SavedWorkspacePaneLayout: Codable, Equatable, Sendable {
    case pane(SavedWorkspacePane)
    case split(
        axis: TerminalSplitAxis,
        ratio: Double,
        first: SavedWorkspacePaneLayout,
        second: SavedWorkspacePaneLayout
    )

    private enum CodingKeys: String, CodingKey {
        case type
        case pane
        case axis
        case ratio
        case first
        case second
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "pane":
            let pane = try container.decode(SavedWorkspacePane.self, forKey: .pane)
            self = .pane(pane)
        case "split":
            let axis = try container.decode(TerminalSplitAxis.self, forKey: .axis)
            let ratio = try container.decodeIfPresent(Double.self, forKey: .ratio) ?? 0.5
            let first = try container.decode(SavedWorkspacePaneLayout.self, forKey: .first)
            let second = try container.decode(SavedWorkspacePaneLayout.self, forKey: .second)
            self = .split(axis: axis, ratio: ratio, first: first, second: second)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown layout type")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .pane(pane):
            try container.encode("pane", forKey: .type)
            try container.encode(pane, forKey: .pane)
        case let .split(axis, ratio, first, second):
            try container.encode("split", forKey: .type)
            try container.encode(axis, forKey: .axis)
            try container.encode(ratio, forKey: .ratio)
            try container.encode(first, forKey: .first)
            try container.encode(second, forKey: .second)
        }
    }

    var panes: [SavedWorkspacePane] {
        switch self {
        case let .pane(pane):
            return [pane]
        case let .split(_, _, first, second):
            return first.panes + second.panes
        }
    }
}

struct SavedWorkspaceSession: Codable, Equatable, Sendable {
    let hostID: Int
    let alias: String
    let customTitle: String?
    let layout: SavedWorkspacePaneLayout
    let activePaneID: UUID
    let synchronizedPaneIDs: [UUID]

    init(
        hostID: Int,
        alias: String,
        customTitle: String? = nil,
        layout: SavedWorkspacePaneLayout,
        activePaneID: UUID,
        synchronizedPaneIDs: [UUID] = []
    ) {
        self.hostID = hostID
        self.alias = alias
        self.customTitle = customTitle
        self.layout = layout
        self.activePaneID = activePaneID
        self.synchronizedPaneIDs = synchronizedPaneIDs
    }
}

struct SavedWorkspace: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    let createdAt: Date
    var updatedAt: Date
    var sessions: [SavedWorkspaceSession]

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        sessions: [SavedWorkspaceSession]
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sessions = sessions
    }

    /// Number of tabs (top-level sessions) this snapshot reopens as.
    var tabCount: Int { sessions.count }
    /// Total pane count across every session's layout.
    var paneCount: Int { sessions.reduce(0) { $0 + $1.layout.panes.count } }

    /// Pure mapping of the live `sessions` into a named snapshot. Captures
    /// every pane — including exited ones, which simply reopen fresh — along
    /// with each pane's `startupOverride` and each session's `customTitle`.
    /// Deliberately drops `zoomedPaneID` (never persisted anywhere,
    /// session-local UI state only).
    static func capture(
        name: String,
        from sessions: [TerminalSession],
        id: UUID = UUID(),
        createdAt: Date = .now
    ) -> SavedWorkspace {
        let savedSessions = sessions.map { session -> SavedWorkspaceSession in
            SavedWorkspaceSession(
                hostID: session.hostID,
                alias: session.alias,
                customTitle: session.customTitle,
                layout: session.layout.savedWorkspaceLayout,
                activePaneID: session.activePaneID,
                synchronizedPaneIDs: Array(session.synchronizedPaneIDs)
            )
        }
        return SavedWorkspace(
            id: id,
            name: name,
            createdAt: createdAt,
            updatedAt: createdAt,
            sessions: savedSessions
        )
    }
}

/// Result of `TerminalWorkspaceModel.openSavedWorkspace` — which new
/// sessions got appended, and which of the snapshot's aliases were pruned
/// out (invalid alias, or `makePane` otherwise rejected them).
struct SavedWorkspaceOpenOutcome: Equatable {
    let openedSessionIDs: [TerminalSession.ID]
    let skippedAliases: [String]
}

extension TerminalPaneLayout {
    /// Snapshot mirror of a live layout — see `SavedWorkspace.capture`.
    var savedWorkspaceLayout: SavedWorkspacePaneLayout {
        switch self {
        case let .pane(pane):
            return .pane(SavedWorkspacePane(id: pane.id, alias: pane.alias, startup: pane.startupOverride))
        case let .split(_, axis, ratio, first, second):
            return .split(
                axis: axis,
                ratio: ratio,
                first: first.savedWorkspaceLayout,
                second: second.savedWorkspaceLayout
            )
        }
    }
}
