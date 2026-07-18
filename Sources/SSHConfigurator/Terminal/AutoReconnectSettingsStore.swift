import Foundation

/// Per-host opt-in for WP7's automatic reconnect. Keyed by SSH alias (same
/// convention as `StartupFlowProfile`/quick access), not host ID, since panes
/// only ever carry the alias string — and it sidesteps grouped sessions where
/// a single `TerminalSession` mixes multiple host IDs. Default is OFF for
/// every alias not present in `enabledAliases`.
struct AutoReconnectSettingsState: Codable, Equatable {
    var enabledAliases: Set<String> = []
}

protocol AutoReconnectSettingsPersisting {
    func load() throws -> AutoReconnectSettingsState
    func save(_ state: AutoReconnectSettingsState) throws
}

/// Follows the same store pattern as `StartupFlowStore`/`QuickAccessStore`:
/// atomic JSON write under Application Support, `0700` directory / `0600`
/// file permissions.
struct AutoReconnectSettingsStore: AutoReconnectSettingsPersisting {
    let fileURL: URL

    init(fileURL: URL = Self.defaultFileURL) {
        self.fileURL = fileURL
    }

    func load() throws -> AutoReconnectSettingsState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return AutoReconnectSettingsState()
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(AutoReconnectSettingsState.self, from: data)
    }

    func save(_ state: AutoReconnectSettingsState) throws {
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: directory.path
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: fileURL.path
        )
        NotificationCenter.default.post(name: .syncableDataDidChange, object: nil)
    }

    static var defaultFileURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        return applicationSupport
            .appendingPathComponent("Terly", isDirectory: true)
            .appendingPathComponent("auto-reconnect.json", isDirectory: false)
    }
}
