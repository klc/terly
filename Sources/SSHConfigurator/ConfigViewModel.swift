import Combine
import Foundation
import SSHConfigCore

enum ConfigNavigationItem: Hashable {
    case global
    case host(Int)
    case match(Int)
    case includes
    case backups
    case tunnels
    case snippets
    case runbooks
    case localTerminal
}

struct HostDraft: Equatable {
    var patterns: String
    var hostName: String
    var user: String
    var port: String
    var identityFile: String
    var proxyJump: String

    init(host: SSHHostBlock, document: SSHConfigDocument) {
        patterns = host.patterns.joined(separator: " ")
        hostName = document.directiveValue(named: "HostName", in: host) ?? ""
        user = document.directiveValue(named: "User", in: host) ?? ""
        port = document.directiveValue(named: "Port", in: host) ?? ""
        identityFile = document.directiveValue(named: "IdentityFile", in: host) ?? ""
        proxyJump = document.directiveValue(named: "ProxyJump", in: host) ?? ""
    }

    func applying(to document: SSHConfigDocument, host: SSHHostBlock) throws -> SSHConfigDocument {
        let aliases = patterns
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        var updated = try document.replacingHostPatterns(in: host, with: aliases)

        for (keyword, value) in [
            ("HostName", hostName),
            ("User", user),
            ("Port", port),
            ("IdentityFile", identityFile),
            ("ProxyJump", proxyJump),
        ] {
            guard let currentHost = updated.hostBlocks.first(where: { $0.id == host.id }) else {
                throw SSHConfigEditError.hostBlockNotFound
            }
            updated = try updated.updatingDirective(named: keyword, to: value, in: currentHost)
        }

        return updated
    }
}

@MainActor
final class ConfigViewModel: ObservableObject {
    @Published private(set) var document: SSHConfigDocument?
    @Published private(set) var snapshot: SSHConfigFileSnapshot?
    @Published private(set) var errorMessage: String?
    @Published private(set) var statusMessage: String?
    @Published private(set) var requiresMatchExecConfirmation = false
    @Published private(set) var backups: [SSHConfigBackup] = []
    @Published private(set) var previewedBackup: SSHConfigBackup?
    @Published private(set) var previewedBackupSource: String?
    @Published private(set) var connectionGroups: [SSHConnectionGroup] = []
    @Published var selectedItem: ConfigNavigationItem?

    let configURL: URL
    private let store: SSHConfigFileStore
    private let connectionGroupStore: ConnectionGroupStore
    private let validator = SSHConfigValidator()

    init(
        configURL: URL = SSHConfigFileStore.defaultConfigURL,
        store: SSHConfigFileStore = SSHConfigFileStore(),
        connectionGroupStore: ConnectionGroupStore = ConnectionGroupStore()
    ) {
        self.configURL = configURL
        self.store = store
        self.connectionGroupStore = connectionGroupStore
    }

    var hosts: [SSHHostBlock] { document?.hostBlocks ?? [] }
    var hostGroups: [SSHConfigHostGroup] { document?.hostGroups ?? [] }
    var matches: [SSHConfigMatchBlock] { document?.matchBlocks ?? [] }
    var includes: [SSHConfigInclude] { document?.includes ?? [] }
    var hasChanges: Bool { document?.source != snapshot?.source }

    var availableConnections: [SSHConnectionTarget] {
        var seenAliases: Set<String> = []
        return hosts
            .flatMap { host in
                host.patterns.compactMap { alias -> SSHConnectionTarget? in
                    guard SSHLaunchPlanBuilder.isConcreteAlias(alias),
                          seenAliases.insert(alias).inserted else {
                        return nil
                    }
                    return SSHConnectionTarget(hostID: host.id, alias: alias)
                }
            }
            .sorted { $0.alias.localizedStandardCompare($1.alias) == .orderedAscending }
    }

    var selectedHost: SSHHostBlock? {
        guard case let .host(id) = selectedItem else { return nil }
        return hosts.first { $0.id == id }
    }

    var selectedMatch: SSHConfigMatchBlock? {
        guard case let .match(id) = selectedItem else { return nil }
        return matches.first { $0.id == id }
    }

    func load() {
        do {
            let loadedSnapshot = try store.snapshot(at: configURL)
            let loadedDocument = SSHConfigDocument(source: loadedSnapshot.source)
            var connectionGroupLoadError: Error?
            do {
                connectionGroups = try connectionGroupStore.load()
            } catch {
                connectionGroups = []
                connectionGroupLoadError = error
            }
            snapshot = loadedSnapshot
            document = loadedDocument
            selectedItem = loadedDocument.hostBlocks.first.map { .host($0.id) } ?? .global
            refreshBackups()
            statusMessage = loadedSnapshot.exists ? "Config yüklendi." : "Config dosyası henüz bulunamadı; yeni dosya oluşturabilirsin."
            errorMessage = connectionGroupLoadError?.localizedDescription
        } catch {
            document = nil
            snapshot = nil
            selectedItem = nil
            backups = []
            connectionGroups = []
            previewedBackup = nil
            previewedBackupSource = nil
            errorMessage = error.localizedDescription
        }
    }

    func restoreSnapshot() {
        guard let snapshot else { return }
        document = SSHConfigDocument(source: snapshot.source)
        selectedItem = document?.hostBlocks.first.map { .host($0.id) } ?? .global
        statusMessage = "Kaydedilmemiş değişiklikler geri alındı."
    }

    @discardableResult
    func apply(_ draft: HostDraft, to host: SSHHostBlock) -> Bool {
        guard let prepared = prepare(draft, for: host) else { return false }
        applyPreparedHostDocument(prepared)
        return true
    }

    func prepare(_ draft: HostDraft, for host: SSHHostBlock) -> SSHConfigDocument? {
        guard let document else { return nil }
        do {
            let prepared = try draft.applying(to: document, host: host)
            errorMessage = nil
            return prepared
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func applyPreparedHostDocument(_ prepared: SSHConfigDocument) {
        document = prepared
        errorMessage = nil
        persistWorkingCopy(successMessage: "Host düzenlemesi kaydedildi.")
    }

    /// Updates only the `IdentityFile` directive for `host`, going through
    /// the same prepare/apply write-through path as the host settings form
    /// (`prepare(_:for:)` + `applyPreparedHostDocument`). Used by the key
    /// setup wizard (WP3) after a new key pair has been generated and
    /// copied to the server, when the user explicitly opts in to pointing
    /// the host at it.
    @discardableResult
    func updateIdentityFile(for host: SSHHostBlock, path: String) -> Bool {
        guard let document else { return false }
        var draft = HostDraft(host: host, document: document)
        draft.identityFile = path
        guard let prepared = prepare(draft, for: host) else { return false }
        applyPreparedHostDocument(prepared)
        return true
    }

    // Kaydet/Geri al UI'ı kalktı; her mutasyon doğrudan ~/.ssh/config'e yazılır.
    // save() başarısızsa (ör. dış değişiklik çakışması) errorMessage alert'i gösterir,
    // çalışma kopyası bellekte kalır.
    @discardableResult
    private func persistWorkingCopy(successMessage: String) -> Bool {
        guard save() else { return false }
        statusMessage = successMessage
        NotificationCenter.default.post(name: .syncableDataDidChange, object: nil)
        return true
    }

    func addHost() {
        guard let document else { return }
        do {
            let updated = try document.appendingHost(patterns: ["new-host"])
            self.document = updated
            selectedItem = updated.hostBlocks.last.map { .host($0.id) }
            statusMessage = "Yeni Host eklendi; alias ve bağlantı alanlarını doldur."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func duplicateHost(_ host: SSHHostBlock) {
        guard let document else { return }
        do {
            let duplicatedPatterns = duplicatePatterns(for: host)
            let updated = try document.duplicatingHostBlock(host, with: duplicatedPatterns)
            self.document = updated
            selectedItem = updated.hostBlocks.last.map { .host($0.id) }
            errorMessage = nil
            persistWorkingCopy(successMessage: "\(host.displayName) bağlantısı kopyalandı ve kaydedildi.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteSelectedHost() {
        guard let document, let selectedHost else { return }
        do {
            let updated = try document.deletingHostBlock(selectedHost)
            self.document = updated
            selectedItem = updated.hostBlocks.first.map { .host($0.id) } ?? .global
            persistWorkingCopy(successMessage: "Host silindi ve ~/.ssh/config güncellendi.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func duplicatePatterns(for host: SSHHostBlock) -> [String] {
        let existingPatterns = Set(hosts.flatMap(\.patterns))
        var copyNumber = 1

        while true {
            let suffix = copyNumber == 1 ? "-copy" : "-copy_\(copyNumber)"
            let duplicatedPatterns = host.patterns.map { "\($0)\(suffix)" }
            if Set(duplicatedPatterns).isDisjoint(with: existingPatterns) {
                return duplicatedPatterns
            }
            copyNumber += 1
        }
    }

    func replaceSource(with source: String) {
        document = SSHConfigDocument(source: source)
        selectedItem = document?.hostBlocks.first.map { .host($0.id) } ?? .global
        persistWorkingCopy(successMessage: "Ham config değişikliği kaydedildi.")
    }

    func replaceGlobalSource(with source: String) {
        guard let document else { return }
        self.document = document.replacingGlobalSource(with: source)
        selectedItem = .global
        persistWorkingCopy(successMessage: "Global ayarlar kaydedildi.")
    }

    func replaceMatchSource(_ match: SSHConfigMatchBlock, with source: String) {
        guard let document else { return }
        self.document = document.replacingSource(in: match.lineRange, with: source)
        selectedItem = .match(match.id)
        persistWorkingCopy(successMessage: "Match bloğu kaydedildi.")
    }

    func addInclude(path: String) {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty, let document else { return }
        self.document = document.appendingGlobalDirective(SSHConfigDirective(keyword: "Include", value: trimmedPath))
        selectedItem = .includes
        persistWorkingCopy(successMessage: "Include satırı eklendi ve kaydedildi.")
    }

    func updateInclude(_ include: SSHConfigInclude, path: String) {
        guard let document else { return }
        self.document = document.updatingDirective(atLine: include.line, to: path)
        selectedItem = .includes
        persistWorkingCopy(successMessage: "Include satırı güncellendi ve kaydedildi.")
    }

    func removeInclude(_ include: SSHConfigInclude) {
        guard let document else { return }
        self.document = document.removingDirective(atLine: include.line)
        selectedItem = .includes
        persistWorkingCopy(successMessage: "Include satırı kaldırıldı ve kaydedildi.")
    }

    @discardableResult
    func saveConnectionGroup(
        id: UUID?,
        name: String,
        aliases: [String],
        openMode: SSHConnectionGroupOpenMode
    ) -> Bool {
        do {
            let group = try SSHConnectionGroup.validated(
                id: id ?? UUID(),
                name: name,
                aliases: aliases,
                openMode: openMode
            )
            var updatedGroups = connectionGroups
            if let index = updatedGroups.firstIndex(where: { $0.id == group.id }) {
                updatedGroups[index] = group
            } else {
                updatedGroups.append(group)
            }

            try connectionGroupStore.save(updatedGroups)
            connectionGroups = updatedGroups
            statusMessage = id == nil ? "Bağlantı grubu oluşturuldu." : "Bağlantı grubu güncellendi."
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func deleteConnectionGroup(_ group: SSHConnectionGroup) -> Bool {
        do {
            let updatedGroups = connectionGroups.filter { $0.id != group.id }
            try connectionGroupStore.save(updatedGroups)
            connectionGroups = updatedGroups
            statusMessage = "Bağlantı grubu silindi."
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func connections(in group: SSHConnectionGroup) -> [SSHConnectionTarget]? {
        let connectionsByAlias = Dictionary(
            uniqueKeysWithValues: availableConnections.map { ($0.alias, $0) }
        )
        let missingAliases = group.aliases.filter { connectionsByAlias[$0] == nil }
        guard missingAliases.isEmpty else {
            errorMessage = SSHConnectionGroupError
                .missingConnections(missingAliases)
                .localizedDescription
            return nil
        }

        errorMessage = nil
        return group.aliases.compactMap { connectionsByAlias[$0] }
    }

    func refreshBackups() {
        do {
            backups = try store.backups()
            if let previewedBackup, !backups.contains(previewedBackup) {
                self.previewedBackup = nil
                previewedBackupSource = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectBackup(_ backup: SSHConfigBackup?) {
        guard let backup else {
            previewedBackup = nil
            previewedBackupSource = nil
            return
        }

        do {
            previewedBackup = backup
            previewedBackupSource = try store.loadBackup(backup).source
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restore(_ backup: SSHConfigBackup) {
        guard let snapshot else { return }

        do {
            let result = try store.restore(backup, expectedSnapshot: snapshot)
            let restoredSnapshot = try store.snapshot(at: configURL)
            self.snapshot = restoredSnapshot
            document = SSHConfigDocument(source: restoredSnapshot.source)
            refreshBackups()
            previewedBackup = nil
            previewedBackupSource = nil
            selectedItem = .backups
            statusMessage = result.backupURL.map { "Yedek geri yüklendi. Önceki sürüm yeni yedek olarak korundu: \($0.lastPathComponent)" } ?? "Yedek geri yüklendi."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func save() -> Bool {
        guard let document, let snapshot else { return false }
        do {
            let result = try store.save(document, expectedSnapshot: snapshot)
            self.snapshot = try store.snapshot(at: configURL)
            refreshBackups()
            statusMessage = result.backupURL.map { "Kaydedildi. Yedek: \($0.lastPathComponent)" } ?? "Kaydedildi."
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func validateSelectedHost(allowingMatchExec: Bool = false) {
        guard let document, let selectedHost else {
            errorMessage = "Doğrulanacak bir Host seçilmedi."
            return
        }

        guard let host = selectedHost.patterns.first(where: { !$0.contains("*") && !$0.contains("?") && !$0.contains("!") }) else {
            errorMessage = "Wildcard Host blokları için somut bir alias gerekli."
            return
        }

        switch validator.validate(document, forHost: host, allowingMatchExec: allowingMatchExec) {
        case .valid:
            statusMessage = "OpenSSH doğrulaması başarılı: \(host)"
        case .requiresMatchExecConfirmation:
            requiresMatchExecConfirmation = true
        case let .invalid(message):
            errorMessage = message
        }
    }

    func prepareForDiagnostics() -> Bool {
        guard !hasChanges else {
            errorMessage = "Bağlantıyı test etmeden önce değişiklikleri kaydet. Tanılama diskteki ~/.ssh/config dosyasını kullanır."
            return false
        }
        errorMessage = nil
        return true
    }

    func dismissError() {
        errorMessage = nil
    }

    func dismissMatchExecConfirmation() {
        requiresMatchExecConfirmation = false
    }
}
