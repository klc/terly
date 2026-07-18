import Foundation

protocol TunnelPersisting {
    func load() throws -> [TunnelDefinition]
    func save(_ tunnels: [TunnelDefinition]) throws
}

struct TunnelStore: TunnelPersisting {
    let fileURL: URL
    
    init(fileURL: URL = Self.defaultFileURL) {
        self.fileURL = fileURL
    }
    
    func load() throws -> [TunnelDefinition] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        return try JSONDecoder().decode([TunnelDefinition].self, from: Data(contentsOf: fileURL))
    }
    
    func save(_ tunnels: [TunnelDefinition]) throws {
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: directory.path
        )
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(tunnels)
        
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
            .appendingPathComponent("tunnels.json", isDirectory: false)
    }
}
