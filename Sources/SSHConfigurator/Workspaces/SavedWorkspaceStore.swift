import Foundation

protocol SavedWorkspacePersisting {
    func load() throws -> [SavedWorkspace]
    func save(_ workspaces: [SavedWorkspace]) throws
}

/// Follows the same store pattern as `WorkspaceLayoutStore`: atomic JSON
/// write under Application Support, `0700` directory / `0600` file
/// permissions, missing file loads as an empty list.
struct SavedWorkspaceStore: SavedWorkspacePersisting {
    let fileURL: URL

    init(fileURL: URL = Self.defaultFileURL) {
        self.fileURL = fileURL
    }

    func load() throws -> [SavedWorkspace] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([SavedWorkspace].self, from: data)
    }

    func save(_ workspaces: [SavedWorkspace]) throws {
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
        let data = try encoder.encode(workspaces)
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
            .appendingPathComponent("workspaces.json", isDirectory: false)
    }
}
