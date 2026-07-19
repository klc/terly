import Foundation

enum SSHConnectionGroupOpenMode: String, Codable, CaseIterable, Sendable {
    case separateTabs
    case splitPanes

    var label: String {
        switch self {
        case .separateTabs:
            return String(localized: "Separate tabs")
        case .splitPanes:
            return String(localized: "Split panes in one tab")
        }
    }
}

struct SSHConnectionGroup: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let aliases: [String]
    let openMode: SSHConnectionGroupOpenMode

    init(
        id: UUID = UUID(),
        name: String,
        aliases: [String],
        openMode: SSHConnectionGroupOpenMode = .separateTabs
    ) {
        self.id = id
        self.name = name
        self.aliases = aliases
        self.openMode = openMode
    }

    static func validated(
        id: UUID = UUID(),
        name: String,
        aliases: [String],
        openMode: SSHConnectionGroupOpenMode = .separateTabs
    ) throws -> SSHConnectionGroup {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw SSHConnectionGroupError.emptyName
        }

        var seenAliases: Set<String> = []
        let normalizedAliases = aliases.compactMap { alias -> String? in
            let normalizedAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            guard SSHLaunchPlanBuilder.isConcreteAlias(normalizedAlias),
                  seenAliases.insert(normalizedAlias).inserted else {
                return nil
            }
            return normalizedAlias
        }

        guard !normalizedAliases.isEmpty else {
            throw SSHConnectionGroupError.emptyConnections
        }

        return SSHConnectionGroup(
            id: id,
            name: normalizedName,
            aliases: normalizedAliases,
            openMode: openMode
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case aliases
        case openMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        aliases = try container.decode([String].self, forKey: .aliases)
        openMode = try container.decodeIfPresent(
            SSHConnectionGroupOpenMode.self,
            forKey: .openMode
        ) ?? .separateTabs
    }
}

struct SSHConnectionTarget: Equatable, Hashable, Identifiable, Sendable {
    let hostID: Int
    let alias: String

    var id: String { alias }
}

enum SSHConnectionGroupError: LocalizedError, Equatable {
    case emptyName
    case emptyConnections
    case missingConnections([String])

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return String(localized: "Enter a name for the connection group.")
        case .emptyConnections:
            return String(localized: "Add at least one connection to the group.")
        case let .missingConnections(aliases):
            return String(localized: "Connections in the group not found in the current SSH config: \(aliases.joined(separator: ", ")). Update the group settings.")
        }
    }
}

struct ConnectionGroupStore {
    let fileURL: URL

    init(fileURL: URL = Self.defaultFileURL) {
        self.fileURL = fileURL
    }

    func load() throws -> [SSHConnectionGroup] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([SSHConnectionGroup].self, from: data)
    }

    func save(_ groups: [SSHConnectionGroup]) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(groups)
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: fileURL.path
        )
    }

    private static var defaultFileURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser

        return applicationSupport
            .appendingPathComponent("Terly", isDirectory: true)
            .appendingPathComponent("connection-groups.json", isDirectory: false)
    }
}
