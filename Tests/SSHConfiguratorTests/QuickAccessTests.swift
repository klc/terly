import Foundation
import SSHConfigCore
import XCTest
@testable import SSHConfigurator

final class QuickAccessTests: XCTestCase {
    func testCatalogIndexesConcreteAliasHostNameUserAndGroupButExcludesPatterns() throws {
        let groupID = UUID()
        let document = SSHConfigDocument(source: """
        Host *.example.com !blocked prod-api
          HostName 10.20.30.40
          User deployer

        Host prod-api
          HostName duplicate.example.com

        Host !negative-only
          HostName hidden.example.com
        """)
        let group = SSHConnectionGroup(
            id: groupID,
            name: "Production Servers",
            aliases: ["prod-api"]
        )

        let catalog = QuickAccessCatalog(document: document, groups: [group])

        XCTAssertEqual(catalog.hosts, [
            QuickAccessHostDescriptor(
                hostID: 1,
                alias: "prod-api",
                hostName: "10.20.30.40",
                user: "deployer"
            ),
        ])
        XCTAssertFalse(catalog.hostAliases.contains("*.example.com"))
        XCTAssertFalse(catalog.hostAliases.contains("!blocked"))
        XCTAssertEqual(catalog.groups.first?.id, groupID)
        XCTAssertEqual(catalog.groups.first?.name, "Production Servers")
    }

    func testFuzzySearchMatchesAliasHostNameUserAndGroupName() {
        let host = makeHostEntry(
            alias: "prod-api-eu",
            hostName: "api.eu.example.com",
            user: "deployer"
        )
        let group = makeGroupEntry(name: "Production Servers")
        let entries = [host, group]

        XCTAssertEqual(
            QuickAccessSearchEngine.search(query: "prdapi", entries: entries).first?.entry.id,
            host.id
        )
        XCTAssertEqual(
            QuickAccessSearchEngine.search(query: "example", entries: entries).first?.entry.id,
            host.id
        )
        XCTAssertEqual(
            QuickAccessSearchEngine.search(query: "dplyr", entries: entries).first?.entry.id,
            host.id
        )
        XCTAssertEqual(
            QuickAccessSearchEngine.search(query: "prd srv", entries: entries).first?.entry.id,
            group.id
        )
    }

    func testEmptySearchOrdersFavoritesThenRecentsThenAlphabetically() {
        let now = Date(timeIntervalSince1970: 10_000)
        let favorite = makeHostEntry(alias: "z-favorite", isFavorite: true)
        let recent = makeHostEntry(alias: "b-recent", lastUsedAt: now)
        let older = makeHostEntry(alias: "a-older", lastUsedAt: now.addingTimeInterval(-100))
        let plain = makeHostEntry(alias: "a-plain")

        let results = QuickAccessSearchEngine.search(
            query: "",
            entries: [plain, older, recent, favorite]
        )

        XCTAssertEqual(results.map(\.entry.title), [
            "z-favorite", "b-recent", "a-older", "a-plain",
        ])
    }

    func testFuzzyMatcherIsCaseAndDiacriticInsensitiveAndRejectsMissingSequence() {
        XCTAssertNotNil(QuickAccessFuzzyMatcher.score(query: "IST", candidate: "İstanbul-Prod"))
        XCTAssertNotNil(QuickAccessFuzzyMatcher.score(query: "papi", candidate: "prod-api"))
        XCTAssertNil(QuickAccessFuzzyMatcher.score(query: "database", candidate: "prod-api"))
    }

    func testSearchKeepsExactResultFirstAndBoundsResultsAcrossOneThousandHosts() {
        let entries = (0..<1_000).map { index in
            makeHostEntry(alias: String(format: "node-%04d", index))
        }

        let results = QuickAccessSearchEngine.search(query: "node-0999", entries: entries)

        XCTAssertEqual(results.first?.entry.title, "node-0999")
        XCTAssertLessThanOrEqual(results.count, 80)
    }

    func testActionPolicyRoutesHostActionsAndRestrictsGroupActions() throws {
        let host = makeHostEntry(alias: "prod-api", hostID: 42)
        let groupID = UUID()
        let group = makeGroupEntry(id: groupID, name: "Prod")

        XCTAssertEqual(
            QuickAccessActionPolicy.availableActions(for: host),
            [.connect, .settings, .transfer, .diagnostics]
        )
        XCTAssertEqual(
            QuickAccessActionPolicy.route(action: .diagnostics, entry: host),
            QuickAccessRoute(
                action: .diagnostics,
                target: .host(hostID: 42, alias: "prod-api")
            )
        )
        XCTAssertEqual(
            QuickAccessActionPolicy.availableActions(for: group),
            [.connect, .settings]
        )
        XCTAssertEqual(
            QuickAccessActionPolicy.route(action: .connect, entry: group),
            QuickAccessRoute(action: .connect, target: .group(id: groupID))
        )
        XCTAssertNil(QuickAccessActionPolicy.route(action: .transfer, entry: group))
    }

    func testKeyboardPolicyCoversCommandKNavigationEnterAndEscapeWithoutConflict() {
        XCTAssertEqual(
            QuickAccessKeyboardPolicy.command(for: .init(
                key: .character("k"),
                commandModifier: true
            )),
            .present
        )
        XCTAssertNil(QuickAccessKeyboardPolicy.command(for: .init(
            key: .character("k"),
            commandModifier: false
        )))
        XCTAssertEqual(
            QuickAccessKeyboardPolicy.command(for: .init(key: .up, commandModifier: false)),
            .moveSelection(-1)
        )
        XCTAssertEqual(
            QuickAccessKeyboardPolicy.command(for: .init(key: .down, commandModifier: false)),
            .moveSelection(1)
        )
        XCTAssertEqual(
            QuickAccessKeyboardPolicy.command(for: .init(key: .enter, commandModifier: false)),
            .performPrimaryAction
        )
        XCTAssertEqual(
            QuickAccessKeyboardPolicy.command(for: .init(key: .escape, commandModifier: false)),
            .dismiss
        )
    }

    func testStoreUsesAtomicOwnerOnlyMetadataFileAndSecuresExistingParent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: root.path
        )
        let fileURL = root.appendingPathComponent("quick-access.json")
        let state = QuickAccessMetadataState(records: [
            .host(alias: "prod-api"),
            .group(id: UUID()),
        ])
        let store = QuickAccessStore(fileURL: fileURL)

        try store.save(state)

        XCTAssertEqual(try store.load(), state)
        XCTAssertEqual(try permissions(at: fileURL), 0o600)
        XCTAssertEqual(try permissions(at: root), 0o700)
    }

    func testMissingQuickAccessStoreLoadsEmptyWithoutTouchingStartupMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let quickURL = root.appendingPathComponent("quick-access.json")
        let startupURL = root.appendingPathComponent("startup-flows.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let startupBytes = Data("startup-metadata".utf8)
        try startupBytes.write(to: startupURL)

        XCTAssertEqual(try QuickAccessStore(fileURL: quickURL).load(), QuickAccessMetadataState())
        XCTAssertEqual(try Data(contentsOf: startupURL), startupBytes)
    }

    @MainActor
    func testFavoriteRecentAndStableIdentitySurviveRenameUndoAndReload() throws {
        let store = InMemoryQuickAccessStore()
        let library = QuickAccessLibrary(store: store)
        let catalogA = catalog(hosts: ["alias-a"])
        library.load(catalog: catalogA)
        let originalEntry = try XCTUnwrap(library.entries(for: catalogA).first)
        let usedAt = Date(timeIntervalSince1970: 123_456)
        XCTAssertTrue(library.toggleFavorite(entryID: originalEntry.id))
        XCTAssertTrue(library.markHostUsed(alias: "alias-a", at: usedAt))

        XCTAssertTrue(library.migrateHostAlias(from: "alias-a", to: "alias-b"))
        let catalogB = catalog(hosts: ["alias-b"])
        XCTAssertTrue(library.reconcile(catalog: catalogB))
        let renamed = try XCTUnwrap(library.entries(for: catalogB).first)
        XCTAssertEqual(renamed.id, originalEntry.id)
        XCTAssertTrue(renamed.isFavorite)
        XCTAssertEqual(renamed.lastUsedAt, usedAt)

        XCTAssertTrue(library.reconcile(catalog: catalogA))
        let undone = try XCTUnwrap(library.entries(for: catalogA).first)
        XCTAssertEqual(undone.id, originalEntry.id)
        XCTAssertTrue(undone.isFavorite)

        let reloaded = QuickAccessLibrary(store: store)
        reloaded.load(catalog: catalogA)
        XCTAssertEqual(reloaded.entries(for: catalogA).first?.id, originalEntry.id)
    }

    @MainActor
    func testExternalAliasLossHidesResultButRetainsMetadataAndRefreshAddsNewAlias() throws {
        let store = InMemoryQuickAccessStore()
        let library = QuickAccessLibrary(store: store)
        let oldCatalog = catalog(hosts: ["old-prod"])
        library.load(catalog: oldCatalog)
        let oldID = try XCTUnwrap(library.entries(for: oldCatalog).first?.id)

        let emptyCatalog = catalog(hosts: [])
        XCTAssertTrue(library.reconcile(catalog: emptyCatalog))
        XCTAssertTrue(library.entries(for: emptyCatalog).isEmpty)
        XCTAssertTrue(store.state.records.contains(where: { $0.id == oldID }))

        let refreshedCatalog = catalog(hosts: ["new-prod"])
        XCTAssertTrue(library.reconcile(catalog: refreshedCatalog))
        let refreshed = library.entries(for: refreshedCatalog)
        XCTAssertEqual(refreshed.map(\.title), ["new-prod"])
        XCTAssertNotEqual(refreshed.first?.id, oldID, "Dış rename güvenli biçimde tahmin edilmemeli")
    }

    @MainActor
    func testGroupFavoriteAndBatchRecentUpdateUseStableGroupIdentity() throws {
        let groupID = UUID()
        let catalog = QuickAccessCatalog(
            hosts: [host("prod-api"), host("prod-db")],
            groups: [.init(id: groupID, name: "Prod", aliases: ["prod-api", "prod-db"])]
        )
        let store = InMemoryQuickAccessStore()
        let library = QuickAccessLibrary(store: store)
        library.load(catalog: catalog)
        let groupEntry = try XCTUnwrap(
            library.entries(for: catalog).first(where: { $0.kind == .group })
        )
        XCTAssertTrue(library.toggleFavorite(entryID: groupEntry.id))
        let usedAt = Date(timeIntervalSince1970: 99)

        XCTAssertTrue(library.markUsed(
            hostAliases: ["prod-api", "prod-db"],
            groupID: groupID,
            at: usedAt
        ))

        let entries = library.entries(for: catalog)
        XCTAssertEqual(entries.filter { $0.lastUsedAt == usedAt }.count, 3)
        XCTAssertTrue(entries.first(where: { $0.kind == .group })?.isFavorite == true)
        XCTAssertEqual(store.saveCount, 3, "load, favorite ve batch recent için birer atomik save")
    }

    @MainActor
    func testPersistenceFailureDoesNotMutateFavoriteState() throws {
        let store = InMemoryQuickAccessStore()
        let library = QuickAccessLibrary(store: store)
        let catalog = catalog(hosts: ["prod"])
        library.load(catalog: catalog)
        let entry = try XCTUnwrap(library.entries(for: catalog).first)
        store.failOnSave = true

        XCTAssertFalse(library.toggleFavorite(entryID: entry.id))

        XCTAssertFalse(library.entries(for: catalog).first?.isFavorite == true)
        XCTAssertNotNil(library.errorMessage)
    }

    private func catalog(hosts aliases: [String]) -> QuickAccessCatalog {
        QuickAccessCatalog(hosts: aliases.map(host), groups: [])
    }

    private func host(_ alias: String) -> QuickAccessHostDescriptor {
        QuickAccessHostDescriptor(hostID: alias.hashValue, alias: alias, hostName: nil, user: nil)
    }

    private func makeHostEntry(
        alias: String,
        hostID: Int = 1,
        hostName: String? = nil,
        user: String? = nil,
        isFavorite: Bool = false,
        lastUsedAt: Date? = nil
    ) -> QuickAccessEntry {
        var metadata = QuickAccessMetadataRecord.host(alias: alias)
        metadata.isFavorite = isFavorite
        metadata.lastUsedAt = lastUsedAt
        return .host(
            .init(hostID: hostID, alias: alias, hostName: hostName, user: user),
            metadata: metadata
        )
    }

    private func makeGroupEntry(
        id: UUID = UUID(),
        name: String,
        isFavorite: Bool = false,
        lastUsedAt: Date? = nil
    ) -> QuickAccessEntry {
        var metadata = QuickAccessMetadataRecord.group(id: id)
        metadata.isFavorite = isFavorite
        metadata.lastUsedAt = lastUsedAt
        return .group(
            .init(id: id, name: name, aliases: ["prod-api"]),
            metadata: metadata
        )
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        return permissions.intValue & 0o777
    }
}

private final class InMemoryQuickAccessStore: QuickAccessPersisting {
    enum Failure: Error {
        case save
    }

    var state = QuickAccessMetadataState()
    var failOnSave = false
    var saveCount = 0

    func load() throws -> QuickAccessMetadataState {
        state
    }

    func save(_ state: QuickAccessMetadataState) throws {
        if failOnSave { throw Failure.save }
        self.state = state
        saveCount += 1
    }
}
