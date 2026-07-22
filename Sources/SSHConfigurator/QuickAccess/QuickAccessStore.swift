import Combine
import Foundation

protocol QuickAccessPersisting {
    func load() throws -> QuickAccessMetadataState
    func save(_ state: QuickAccessMetadataState) throws
}

struct QuickAccessStore: QuickAccessPersisting {
    let fileURL: URL

    init(fileURL: URL = Self.defaultFileURL) {
        self.fileURL = fileURL
    }

    func load() throws -> QuickAccessMetadataState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return QuickAccessMetadataState()
        }
        return try JSONDecoder().decode(
            QuickAccessMetadataState.self,
            from: Data(contentsOf: fileURL)
        )
    }

    func save(_ state: QuickAccessMetadataState) throws {
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
            .appendingPathComponent("quick-access.json", isDirectory: false)
    }
}

@MainActor
final class QuickAccessLibrary: ObservableObject {
    @Published private(set) var metadata = QuickAccessMetadataState()
    @Published private(set) var errorMessage: String?

    private let store: any QuickAccessPersisting
    private var catalog = QuickAccessCatalog(hosts: [])

    init(store: any QuickAccessPersisting = QuickAccessStore()) {
        self.store = store
    }

    func load(catalog: QuickAccessCatalog) {
        do {
            metadata = try store.load()
            self.catalog = catalog
            try reconcileMetadata(with: catalog)
            errorMessage = nil
        } catch {
            self.catalog = catalog
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func reconcile(catalog: QuickAccessCatalog) -> Bool {
        do {
            self.catalog = catalog
            try reconcileMetadata(with: catalog)
            errorMessage = nil
            return true
        } catch {
            self.catalog = catalog
            errorMessage = error.localizedDescription
            return false
        }
    }

    func entries(for catalog: QuickAccessCatalog) -> [QuickAccessEntry] {
        let hostPairs: [(String, QuickAccessMetadataRecord)] = metadata.records.compactMap { record in
            guard record.kind == .host, let alias = record.alias else { return nil }
            return (alias, record)
        }
        let hostRecords = hostPairs.reduce(into: [String: QuickAccessMetadataRecord]()) {
            records, pair in
            if records[pair.0] == nil { records[pair.0] = pair.1 }
        }

        return catalog.hosts.compactMap { host in
            hostRecords[host.alias].map { QuickAccessEntry.host(host, metadata: $0) }
        }
    }

    @discardableResult
    func toggleFavorite(entryID: UUID) -> Bool {
        updateRecord(id: entryID) { $0.isFavorite.toggle() }
    }

    @discardableResult
    func markHostUsed(alias: String, at date: Date = Date()) -> Bool {
        markUsed(hostAliases: [alias], at: date)
    }

    @discardableResult
    func markUsed(
        hostAliases: [String],
        at date: Date = Date()
    ) -> Bool {
        let aliases = Set(hostAliases)
        var updated = metadata
        var changed = false
        for index in updated.records.indices {
            let isHost = updated.records[index].kind == .host
                && updated.records[index].alias.map(aliases.contains) == true
            guard isHost else { continue }
            updated.records[index].lastUsedAt = date
            changed = true
        }
        guard changed else { return false }
        return persist(updated)
    }

    @discardableResult
    func migrateHostAlias(from oldAlias: String?, to newAlias: String?) -> Bool {
        guard let oldAlias, let newAlias, oldAlias != newAlias else { return true }
        guard let oldIndex = metadata.records.firstIndex(where: {
            $0.kind == .host && $0.alias == oldAlias
        }) else { return true }

        var updated = metadata
        var record = updated.records[oldIndex]
        if !record.aliasHistory.contains(oldAlias) {
            record.aliasHistory.append(oldAlias)
        }
        record.aliasHistory.removeAll { $0 == newAlias }
        record.alias = newAlias

        if let targetIndex = updated.records.firstIndex(where: {
            $0.kind == .host && $0.alias == newAlias && $0.id != record.id
        }) {
            let target = updated.records[targetIndex]
            record.isFavorite = record.isFavorite || target.isFavorite
            record.lastUsedAt = [record.lastUsedAt, target.lastUsedAt]
                .compactMap { $0 }
                .max()
            for alias in target.aliasHistory where !record.aliasHistory.contains(alias) {
                record.aliasHistory.append(alias)
            }
            updated.records.remove(at: targetIndex)
            if targetIndex < oldIndex {
                updated.records[oldIndex - 1] = record
            } else {
                updated.records[oldIndex] = record
            }
        } else {
            updated.records[oldIndex] = record
        }
        return persist(updated)
    }

    func dismissError() {
        errorMessage = nil
    }

    private func reconcileMetadata(with catalog: QuickAccessCatalog) throws {
        var updated = metadata
        let aliases = catalog.hostAliases

        for index in updated.records.indices where updated.records[index].kind == .host {
            guard let currentAlias = updated.records[index].alias,
                  !aliases.contains(currentAlias),
                  let restoredAlias = updated.records[index].aliasHistory.reversed().first(
                    where: aliases.contains
                  ),
                  !updated.records.contains(where: {
                    $0.kind == .host && $0.alias == restoredAlias && $0.id != updated.records[index].id
                  }) else { continue }
            updated.records[index].aliasHistory.removeAll { $0 == restoredAlias }
            if !updated.records[index].aliasHistory.contains(currentAlias) {
                updated.records[index].aliasHistory.append(currentAlias)
            }
            updated.records[index].alias = restoredAlias
        }

        let linkedAliases = Set(updated.records.compactMap {
            $0.kind == .host ? $0.alias : nil
        })
        for alias in aliases.subtracting(linkedAliases).sorted() {
            updated.records.append(.host(alias: alias))
        }

        // Connection groups were removed (Phase D); a pre-workspace
        // quick-access.json may still carry `.group`-kind records, which
        // `QuickAccessMetadataRecord` keeps the ability to decode. Prune them
        // here so old files self-clean the first time they're loaded.
        updated.records.removeAll { $0.kind == .group }

        guard updated != metadata else { return }
        try store.save(updated)
        metadata = updated
    }

    private func updateRecord(
        id: UUID,
        mutation: (inout QuickAccessMetadataRecord) -> Void
    ) -> Bool {
        updateRecord(where: { $0.id == id }, mutation: mutation)
    }

    private func updateRecord(
        where predicate: (QuickAccessMetadataRecord) -> Bool,
        mutation: (inout QuickAccessMetadataRecord) -> Void
    ) -> Bool {
        guard let index = metadata.records.firstIndex(where: predicate) else { return false }
        var updated = metadata
        mutation(&updated.records[index])
        return persist(updated)
    }

    private func persist(_ updated: QuickAccessMetadataState) -> Bool {
        do {
            try store.save(updated)
            metadata = updated
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
