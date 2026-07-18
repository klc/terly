import Combine
import Foundation

protocol StartupFlowPersisting {
    func load() throws -> StartupFlowMetadataState
    func save(_ state: StartupFlowMetadataState) throws
}

struct StartupFlowStore: StartupFlowPersisting {
    let fileURL: URL

    init(fileURL: URL = Self.defaultFileURL) {
        self.fileURL = fileURL
    }

    func load() throws -> StartupFlowMetadataState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return StartupFlowMetadataState()
        }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        if let state = try? decoder.decode(StartupFlowMetadataState.self, from: data) {
            return state
        }
        // Phase 2.1'in ilk sürümü profilleri kökte bir JSON dizisi olarak yazıyordu.
        // Mevcut kullanıcı verisini transaction metadata formatına kayıpsız yükselt.
        return StartupFlowMetadataState(
            profiles: try decoder.decode([StartupFlowProfile].self, from: data)
        )
    }

    func save(_ state: StartupFlowMetadataState) throws {
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
            .appendingPathComponent("startup-flows.json", isDirectory: false)
    }
}

enum StartupFlowLibraryError: LocalizedError, Equatable {
    case invalidAlias
    case aliasAlreadyLinked(String)
    case profileNotFound
    case missingPendingFingerprint

    var errorDescription: String? {
        switch self {
        case .invalidAlias:
            "Başlangıç akışı somut bir SSH alias'ına bağlanmalıdır."
        case let .aliasAlreadyLinked(alias):
            "\(alias) alias'ına zaten başka bir başlangıç profili bağlı."
        case .profileNotFound:
            "Başlangıç profili bulunamadı."
        case .missingPendingFingerprint:
            "Config değişikliğine bağlı başlangıç profili için hedef config fingerprint'i bulunamadı."
        }
    }
}

@MainActor
final class StartupFlowLibrary: ObservableObject {
    @Published private(set) var records: [StartupFlowRecord] = []
    @Published private(set) var errorMessage: String?

    private let store: any StartupFlowPersisting
    private let builder: StartupFlowBootstrapBuilder
    private var metadata = StartupFlowMetadataState()
    private var context: StartupFlowReconciliationContext?

    init(
        store: any StartupFlowPersisting = StartupFlowStore(),
        builder: StartupFlowBootstrapBuilder = StartupFlowBootstrapBuilder()
    ) {
        self.store = store
        self.builder = builder
    }

    var orphanedRecords: [StartupFlowRecord] {
        records.filter { $0.status == .orphaned }
    }

    var pendingChanges: [StartupFlowPendingChange] {
        metadata.pendingChanges
    }

    func load(context: StartupFlowReconciliationContext) {
        do {
            metadata = try store.load()
            self.context = context
            try reconcileMetadata(context: context)
            errorMessage = nil
        } catch {
            self.context = context
            rebuildRecords()
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func reconcile(context: StartupFlowReconciliationContext) -> Bool {
        do {
            self.context = context
            try reconcileMetadata(context: context)
            errorMessage = nil
            return true
        } catch {
            self.context = context
            rebuildRecords()
            errorMessage = error.localizedDescription
            return false
        }
    }

    func profile(for alias: String) -> StartupFlowProfile? {
        records.first {
            $0.status == .linked && $0.profile.alias == alias
        }?.profile
    }

    func editableProfile(for alias: String) -> StartupFlowProfile {
        profile(for: alias) ?? StartupFlowProfile(alias: alias)
    }

    @discardableResult
    func save(
        _ profile: StartupFlowProfile,
        pendingUntilConfigFingerprint fingerprint: String? = nil
    ) -> Bool {
        do {
            let normalized = try normalizedProfile(profile)
            if !normalized.steps.isEmpty {
                _ = try builder.build(profile: normalized)
            }
            if let conflict = effectiveProfiles().first(where: {
                $0.alias == normalized.alias && $0.id != normalized.id
            }) {
                throw StartupFlowLibraryError.aliasAlreadyLinked(conflict.alias)
            }

            var updated = metadata
            if let fingerprint {
                let sameTarget = updated.pendingChanges.last {
                    $0.profileID == normalized.id && $0.after.alias == normalized.alias
                }
                updated.pendingChanges.removeAll {
                    $0.profileID == normalized.id && $0.after.alias == normalized.alias
                }
                let before = sameTarget?.before
                    ?? effectiveProfiles().first { $0.id == normalized.id }
                updated.pendingChanges.append(
                    StartupFlowPendingChange(
                        before: before,
                        after: normalized,
                        expectedConfigFingerprint: fingerprint
                    )
                )
            } else {
                updated.pendingChanges.removeAll { $0.profileID == normalized.id }
                Self.upsert(normalized, into: &updated.profiles)
            }

            try store.save(updated)
            metadata = updated
            rebuildRecords()
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func stageAliasMigration(
        from oldAlias: String,
        to newAlias: String,
        profile: StartupFlowProfile,
        expectedConfigFingerprint: String
    ) -> Bool {
        var migrated = profile
        migrated.alias = newAlias
        guard profile.alias == oldAlias || metadata.profiles.contains(where: {
            $0.id == profile.id && $0.alias == oldAlias
        }) else {
            errorMessage = StartupFlowLibraryError.profileNotFound.localizedDescription
            return false
        }
        return save(
            migrated,
            pendingUntilConfigFingerprint: expectedConfigFingerprint
        )
    }

    @discardableResult
    func reassign(profileID: UUID, to alias: String) -> Bool {
        guard let profile = metadata.profiles.first(where: { $0.id == profileID }) else {
            errorMessage = StartupFlowLibraryError.profileNotFound.localizedDescription
            return false
        }
        var reassigned = profile
        reassigned.alias = alias
        let pendingFingerprint = context.flatMap { context in
            context.persistedAliases.contains(alias)
                ? nil
                : context.workingConfigFingerprint
        }
        return save(
            reassigned,
            pendingUntilConfigFingerprint: pendingFingerprint
        )
    }

    func dismissError() {
        errorMessage = nil
    }

    private func reconcileMetadata(
        context: StartupFlowReconciliationContext
    ) throws {
        var updated = metadata
        var remaining: [StartupFlowPendingChange] = []

        let grouped = Dictionary(grouping: metadata.pendingChanges, by: \.profileID)
        let profileOrder = metadata.pendingChanges.map(\.profileID).reduce(into: [UUID]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        for profileID in profileOrder {
            let changes = grouped[profileID] ?? []
            let decisions = changes.map {
                StartupFlowReconciliationPolicy.decision(for: $0, context: context)
            }
            for (index, change) in changes.enumerated() {
                switch decisions[index] {
                case .keep:
                    remaining.append(change)
                case .commit:
                    Self.upsert(change.after, into: &updated.profiles)
                case .rollback:
                    // Daha yeni bir çalışma-kopyası hedefi aktifken önceki alias adımını
                    // undo zinciri için sakla. Yeni adım geri alınırsa bu adım tekrar görünür.
                    if decisions.dropFirst(index + 1).contains(.keep) {
                        remaining.append(change)
                    }
                }
            }
        }
        updated.pendingChanges = remaining

        if updated != metadata {
            try store.save(updated)
            metadata = updated
        }
        rebuildRecords()
    }

    private func rebuildRecords() {
        let aliases = context?.workingAliases ?? []
        records = effectiveProfiles().map {
            StartupFlowRecord(
                profile: $0,
                status: aliases.contains($0.alias) ? .linked : .orphaned
            )
        }
    }

    private func effectiveProfiles() -> [StartupFlowProfile] {
        var profiles = metadata.profiles
        for change in metadata.pendingChanges {
            guard let context else { continue }
            let decision = StartupFlowReconciliationPolicy.decision(for: change, context: context)
            guard decision != .rollback else { continue }
            Self.upsert(change.after, into: &profiles)
        }
        return profiles
    }

    private func normalizedProfile(_ profile: StartupFlowProfile) throws -> StartupFlowProfile {
        let alias = profile.alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SSHLaunchPlanBuilder.isConcreteAlias(alias) else {
            throw StartupFlowLibraryError.invalidAlias
        }
        var normalized = profile
        normalized.alias = alias
        return normalized
    }

    private static func upsert(
        _ profile: StartupFlowProfile,
        into profiles: inout [StartupFlowProfile]
    ) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
    }
}
