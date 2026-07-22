import Foundation
import SSHConfigCore

enum QuickAccessEntryKind: String, Codable, Equatable, Sendable {
    case host
    /// No longer produced by any current catalog/entry-building path
    /// (connection groups were removed) — kept for decode compatibility with
    /// pre-workspace quick-access.json files that may still contain
    /// `"kind":"group"` records. `reconcileMetadata` prunes any such record
    /// on load.
    case group
}

struct QuickAccessHostDescriptor: Equatable, Sendable {
    let hostID: Int
    let alias: String
    let hostName: String?
    let user: String?
}

struct QuickAccessCatalog: Equatable, Sendable {
    var hosts: [QuickAccessHostDescriptor]

    init(document: SSHConfigDocument?) {
        hosts = document.map(Self.hosts(in:)) ?? []
    }

    init(hosts: [QuickAccessHostDescriptor]) {
        self.hosts = hosts
    }

    var hostAliases: Set<String> { Set(hosts.map(\.alias)) }

    private static func hosts(in document: SSHConfigDocument) -> [QuickAccessHostDescriptor] {
        var seen: Set<String> = []
        return document.hostBlocks.flatMap { host in
            let hostName = document.directiveValue(named: "HostName", in: host)
            let user = document.directiveValue(named: "User", in: host)
            return host.patterns.compactMap { alias -> QuickAccessHostDescriptor? in
                guard SSHLaunchPlanBuilder.isConcreteAlias(alias),
                      seen.insert(alias).inserted else { return nil }
                return QuickAccessHostDescriptor(
                    hostID: host.id,
                    alias: alias,
                    hostName: hostName,
                    user: user
                )
            }
        }
    }
}

struct QuickAccessMetadataRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var kind: QuickAccessEntryKind
    var alias: String?
    var groupID: UUID?
    var aliasHistory: [String]
    var isFavorite: Bool
    var lastUsedAt: Date?

    static func host(alias: String, id: UUID = UUID()) -> Self {
        Self(
            id: id,
            kind: .host,
            alias: alias,
            groupID: nil,
            aliasHistory: [],
            isFavorite: false,
            lastUsedAt: nil
        )
    }

    /// Kept for decode compatibility with pre-workspace quick-access.json
    /// files only — nothing constructs a `.group` record anymore.
    /// `QuickAccessLibrary.reconcileMetadata` prunes any record of this kind
    /// as soon as it's loaded.
    static func group(id groupID: UUID, recordID: UUID = UUID()) -> Self {
        Self(
            id: recordID,
            kind: .group,
            alias: nil,
            groupID: groupID,
            aliasHistory: [],
            isFavorite: false,
            lastUsedAt: nil
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case alias
        case groupID
        case aliasHistory
        case isFavorite
        case lastUsedAt
    }

    init(
        id: UUID,
        kind: QuickAccessEntryKind,
        alias: String?,
        groupID: UUID?,
        aliasHistory: [String],
        isFavorite: Bool,
        lastUsedAt: Date?
    ) {
        self.id = id
        self.kind = kind
        self.alias = alias
        self.groupID = groupID
        self.aliasHistory = aliasHistory
        self.isFavorite = isFavorite
        self.lastUsedAt = lastUsedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(QuickAccessEntryKind.self, forKey: .kind)
        alias = try container.decodeIfPresent(String.self, forKey: .alias)
        groupID = try container.decodeIfPresent(UUID.self, forKey: .groupID)
        aliasHistory = try container.decodeIfPresent([String].self, forKey: .aliasHistory) ?? []
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
    }
}

struct QuickAccessMetadataState: Codable, Equatable, Sendable {
    var version: Int = 1
    var records: [QuickAccessMetadataRecord] = []
}

struct QuickAccessEntry: Equatable, Identifiable, Sendable {
    let id: UUID
    let kind: QuickAccessEntryKind
    let hostID: Int?
    let alias: String?
    let title: String
    let subtitle: String?
    let searchFields: [String]
    let isFavorite: Bool
    let lastUsedAt: Date?

    static func host(
        _ host: QuickAccessHostDescriptor,
        metadata: QuickAccessMetadataRecord
    ) -> Self {
        let details = [host.user, host.hostName]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "@")
        return Self(
            id: metadata.id,
            kind: .host,
            hostID: host.hostID,
            alias: host.alias,
            title: host.alias,
            subtitle: details.isEmpty ? nil : details,
            searchFields: [host.alias, host.hostName, host.user].compactMap { $0 },
            isFavorite: metadata.isFavorite,
            lastUsedAt: metadata.lastUsedAt
        )
    }
}
