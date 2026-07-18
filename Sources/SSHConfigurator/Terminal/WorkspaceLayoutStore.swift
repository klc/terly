import Foundation

struct PersistedPane: Codable, Equatable {
    let id: UUID
    let alias: String
    let skippedAutomaticStartup: Bool

    init(id: UUID, alias: String, skippedAutomaticStartup: Bool = false) {
        self.id = id
        self.alias = alias
        self.skippedAutomaticStartup = skippedAutomaticStartup
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case alias
        case skippedAutomaticStartup
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        alias = try container.decode(String.self, forKey: .alias)
        skippedAutomaticStartup = try container.decodeIfPresent(
            Bool.self,
            forKey: .skippedAutomaticStartup
        ) ?? false
    }
}

indirect enum PersistedPaneLayout: Codable, Equatable {
    case pane(PersistedPane)
    case split(
        id: UUID,
        axis: TerminalSplitAxis,
        first: PersistedPaneLayout,
        second: PersistedPaneLayout
    )

    enum CodingKeys: String, CodingKey {
        case type
        case pane
        case id
        case axis
        case first
        case second
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "pane":
            let pane = try container.decode(PersistedPane.self, forKey: .pane)
            self = .pane(pane)
        case "split":
            let id = try container.decode(UUID.self, forKey: .id)
            let axis = try container.decode(TerminalSplitAxis.self, forKey: .axis)
            let first = try container.decode(PersistedPaneLayout.self, forKey: .first)
            let second = try container.decode(PersistedPaneLayout.self, forKey: .second)
            self = .split(id: id, axis: axis, first: first, second: second)
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
        case let .split(id, axis, first, second):
            try container.encode("split", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(axis, forKey: .axis)
            try container.encode(first, forKey: .first)
            try container.encode(second, forKey: .second)
        }
    }
}

struct PersistedSession: Codable, Equatable {
    let id: UUID
    let hostID: Int
    let alias: String
    let groupID: UUID?
    let layout: PersistedPaneLayout
    let activePaneID: UUID
    let synchronizedPaneIDs: [UUID]
}

struct PersistedWorkspace: Codable, Equatable {
    let sessions: [PersistedSession]
    let selectedSessionID: UUID?
}

protocol WorkspaceLayoutPersisting {
    func load() throws -> PersistedWorkspace
    func save(_ workspace: PersistedWorkspace) throws
}

struct WorkspaceLayoutStore: WorkspaceLayoutPersisting {
    let fileURL: URL

    init(fileURL: URL = Self.defaultFileURL) {
        self.fileURL = fileURL
    }

    func load() throws -> PersistedWorkspace {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return PersistedWorkspace(sessions: [], selectedSessionID: nil)
        }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        return try decoder.decode(PersistedWorkspace.self, from: data)
    }

    func save(_ workspace: PersistedWorkspace) throws {
        let fileManager = FileManager.default
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: directoryURL.path
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(workspace)
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: fileURL.path
        )
    }

    static var defaultFileURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        return applicationSupport
            .appendingPathComponent("Terly", isDirectory: true)
            .appendingPathComponent("workspace-layout.json", isDirectory: false)
    }
}

extension TerminalPaneLayout {
    var persisted: PersistedPaneLayout {
        switch self {
        case let .pane(pane):
            return .pane(PersistedPane(
                id: pane.id,
                alias: pane.alias,
                skippedAutomaticStartup: pane.startupState == .skipped
            ))
        case let .split(id, axis, first, second):
            return .split(id: id, axis: axis, first: first.persisted, second: second.persisted)
        }
    }
}

extension PersistedPaneLayout {
    func restore(
        builder: SSHLaunchPlanBuilder,
        startupProfiles: [String: StartupFlowProfile]
    ) throws -> TerminalPaneLayout {
        switch self {
        case let .pane(persistedPane):
            let profile = startupProfiles[persistedPane.alias]
            let pane = try builder.makePane(
                id: persistedPane.id,
                alias: persistedPane.alias,
                startupProfile: profile,
                skipStartup: persistedPane.skippedAutomaticStartup
            )
            return .pane(pane)
        case let .split(id, axis, first, second):
            let restoredFirst = try first.restore(builder: builder, startupProfiles: startupProfiles)
            let restoredSecond = try second.restore(builder: builder, startupProfiles: startupProfiles)
            return .split(id: id, axis: axis, first: restoredFirst, second: restoredSecond)
        }
    }
}
