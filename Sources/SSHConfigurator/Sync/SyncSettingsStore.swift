import Foundation

/// Persisted sync preferences — the remote URL and whether push happens
/// automatically after a commit. Deliberately holds no credentials: the
/// remote URL is just an address, auth is left to the user's own SSH
/// key/credential helper (see `GitCommandRunner`).
struct SyncSettings: Codable, Equatable, Sendable {
    var remoteURL: String?
    var autoPushEnabled: Bool
    var lastSyncedAt: Date?

    init(remoteURL: String? = nil, autoPushEnabled: Bool = false, lastSyncedAt: Date? = nil) {
        self.remoteURL = remoteURL
        self.autoPushEnabled = autoPushEnabled
        self.lastSyncedAt = lastSyncedAt
    }
}

protocol SyncSettingsPersisting {
    func load() throws -> SyncSettings
    func save(_ settings: SyncSettings) throws
}

struct SyncSettingsStore: SyncSettingsPersisting {
    let fileURL: URL

    init(fileURL: URL = Self.defaultFileURL) {
        self.fileURL = fileURL
    }

    func load() throws -> SyncSettings {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return SyncSettings()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SyncSettings.self, from: Data(contentsOf: fileURL))
    }

    func save(_ settings: SyncSettings) throws {
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: directory.path
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(settings)

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
            .appendingPathComponent("sync-settings.json", isDirectory: false)
    }
}
