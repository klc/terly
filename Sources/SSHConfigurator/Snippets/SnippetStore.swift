import Foundation

protocol SnippetPersisting {
    func load() throws -> [Snippet]
    func save(_ snippets: [Snippet]) throws
}

struct SnippetStore: SnippetPersisting {
    let fileURL: URL

    init(fileURL: URL = Self.defaultFileURL) {
        self.fileURL = fileURL
    }

    func load() throws -> [Snippet] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        return try JSONDecoder().decode([Snippet].self, from: Data(contentsOf: fileURL))
    }

    func save(_ snippets: [Snippet]) throws {
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: directory.path
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snippets)

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
            .appendingPathComponent("snippets.json", isDirectory: false)
    }
}
