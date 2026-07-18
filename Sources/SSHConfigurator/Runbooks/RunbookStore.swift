import Foundation

protocol RunbookPersisting {
    func load() throws -> [Runbook]
    func save(_ runbooks: [Runbook]) throws
}

/// JSON persistence for runbooks, mirroring `SnippetStore`: stored under
/// Application Support/Terly/runbooks.json, written atomically,
/// directory at 0700 and file at 0600. Runbook parameter *values* used for a
/// run are never part of this model (see `RunbookParameter`), so nothing
/// secret-shaped is expected to land in this file — but it is still treated
/// with the same care as every other metadata store in the app.
struct RunbookStore: RunbookPersisting {
    let fileURL: URL

    init(fileURL: URL = Self.defaultFileURL) {
        self.fileURL = fileURL
    }

    func load() throws -> [Runbook] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        return try JSONDecoder().decode([Runbook].self, from: Data(contentsOf: fileURL))
    }

    func save(_ runbooks: [Runbook]) throws {
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: directory.path
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(runbooks)

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
            .appendingPathComponent("runbooks.json", isDirectory: false)
    }
}
