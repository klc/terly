import CryptoKit
import Foundation

public struct SSHConfigFileSnapshot: Sendable, Equatable {
    public let url: URL
    public let source: String
    public let fingerprint: String
    public let exists: Bool

    public init(url: URL, source: String, fingerprint: String, exists: Bool) {
        self.url = url
        self.source = source
        self.fingerprint = fingerprint
        self.exists = exists
    }
}

public struct SSHConfigSaveResult: Sendable, Equatable {
    public let backupURL: URL?

    public init(backupURL: URL?) {
        self.backupURL = backupURL
    }
}

public struct SSHConfigBackup: Sendable, Equatable, Identifiable {
    public let url: URL
    public let createdAt: Date
    public let byteCount: Int

    public var id: URL { url }

    public init(url: URL, createdAt: Date, byteCount: Int) {
        self.url = url
        self.createdAt = createdAt
        self.byteCount = byteCount
    }
}

public enum SSHConfigFileStoreError: LocalizedError {
    case unreadable(URL, Error)
    case invalidEncoding(URL)
    case fileChangedExternally(URL)
    case symbolicLink(URL)
    case unableToWrite(URL)
    case invalidBackup(URL)

    public var errorDescription: String? {
        switch self {
        case let .unreadable(url, error):
            return String(localized: "The config file couldn't be read: \(url.path) (\(error.localizedDescription))", bundle: .core)
        case let .invalidEncoding(url):
            return String(localized: "The config file couldn't be read as UTF-8: \(url.path)", bundle: .core)
        case let .fileChangedExternally(url):
            return String(localized: "The config file was changed externally while the app was open: \(url.path)", bundle: .core)
        case let .symbolicLink(url):
            return String(localized: "For safety, config files that are symbolic links can't be written to directly: \(url.path)", bundle: .core)
        case let .unableToWrite(url):
            return String(localized: "The config file couldn't be written: \(url.path)", bundle: .core)
        case let .invalidBackup(url):
            return String(localized: "The selected backup isn't in the safe backup folder: \(url.path)", bundle: .core)
        }
    }
}

public struct SSHConfigFileStore: Sendable {
    public static var defaultConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh", isDirectory: true)
            .appendingPathComponent("config", isDirectory: false)
    }

    public let backupDirectory: URL

    /// Her config mutasyonu bir yedek ürettiği için yedek klasörü sınırsız
    /// büyümesin diye yalnızca en yeni `retentionLimit` yedek saklanır.
    public let retentionLimit: Int

    public init(backupDirectory: URL? = nil, retentionLimit: Int = 50) {
        self.backupDirectory = backupDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Terly", isDirectory: true)
            .appendingPathComponent("Backups", isDirectory: true)
        self.retentionLimit = max(1, retentionLimit)
    }

    public func load(from url: URL) throws -> SSHConfigDocument {
        do {
            let source = try String(contentsOf: url, encoding: .utf8)
            return SSHConfigDocument(source: source)
        } catch let error as CocoaError where error.code == .fileReadInapplicableStringEncoding {
            throw SSHConfigFileStoreError.invalidEncoding(url)
        } catch {
            throw SSHConfigFileStoreError.unreadable(url, error)
        }
    }

    public func snapshot(at url: URL) throws -> SSHConfigFileSnapshot {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return SSHConfigFileSnapshot(url: url, source: "", fingerprint: Self.fingerprint(of: ""), exists: false)
        }

        let document = try load(from: url)
        return SSHConfigFileSnapshot(
            url: url,
            source: document.source,
            fingerprint: Self.fingerprint(of: document.source),
            exists: true
        )
    }

    public func save(
        _ document: SSHConfigDocument,
        expectedSnapshot: SSHConfigFileSnapshot
    ) throws -> SSHConfigSaveResult {
        let url = expectedSnapshot.url
        try rejectSymbolicLink(at: url)

        let currentSnapshot = try snapshot(at: url)
        guard currentSnapshot.fingerprint == expectedSnapshot.fingerprint,
              currentSnapshot.exists == expectedSnapshot.exists else {
            throw SSHConfigFileStoreError.fileChangedExternally(url)
        }

        let backupURL = try makeBackup(from: expectedSnapshot)
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(".config.ssh-configurator-\(UUID().uuidString).tmp")
        let data = Data(document.source.utf8)

        guard fileManager.createFile(
            atPath: temporaryURL.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw SSHConfigFileStoreError.unableToWrite(temporaryURL)
        }

        do {
            if expectedSnapshot.exists {
                _ = try fileManager.replaceItemAt(url, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: url)
            }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw SSHConfigFileStoreError.unableToWrite(url)
        }

        return SSHConfigSaveResult(backupURL: backupURL)
    }

    public func backups() throws -> [SSHConfigBackup] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: backupDirectory.path) else { return [] }

        let urls = try fileManager.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        return urls.compactMap { url in
            guard url.pathExtension == "backup",
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else {
                return nil
            }

            return SSHConfigBackup(
                url: url,
                createdAt: values.contentModificationDate ?? .distantPast,
                byteCount: values.fileSize ?? 0
            )
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    public func loadBackup(_ backup: SSHConfigBackup) throws -> SSHConfigDocument {
        try validate(backup: backup)
        return try load(from: backup.url)
    }

    /// Restoring is deliberately implemented through `save` so the current
    /// config is backed up, checked for external changes, and atomically
    /// replaced before the selected backup becomes active.
    public func restore(
        _ backup: SSHConfigBackup,
        expectedSnapshot: SSHConfigFileSnapshot
    ) throws -> SSHConfigSaveResult {
        let document = try loadBackup(backup)
        return try save(document, expectedSnapshot: expectedSnapshot)
    }

    private func makeBackup(from snapshot: SSHConfigFileSnapshot) throws -> URL? {
        guard snapshot.exists else { return nil }
        if let latest = try? backups().first,
           let source = try? String(contentsOf: latest.url, encoding: .utf8),
           Self.fingerprint(of: source) == snapshot.fingerprint {
            return nil
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: backupDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backupDirectory.path)

        let backupURL = backupDirectory.appendingPathComponent("config-\(UUID().uuidString).backup")
        try snapshot.source.write(to: backupURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
        try? pruneBackups()
        return backupURL
    }

    private func pruneBackups() throws {
        let expired = try backups().dropFirst(retentionLimit)
        for backup in expired {
            try? FileManager.default.removeItem(at: backup.url)
        }
    }

    private func validate(backup: SSHConfigBackup) throws {
        let expectedDirectory = backupDirectory.standardizedFileURL.path
        let backupDirectoryPath = backup.url.deletingLastPathComponent().standardizedFileURL.path

        guard backupDirectoryPath == expectedDirectory, backup.url.pathExtension == "backup" else {
            throw SSHConfigFileStoreError.invalidBackup(backup.url)
        }
    }

    private func rejectSymbolicLink(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values.isSymbolicLink == true {
            throw SSHConfigFileStoreError.symbolicLink(url)
        }
    }

    private static func fingerprint(of source: String) -> String {
        SHA256.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
