import Foundation
import SSHConfigCore
import XCTest
@testable import SSHConfigurator

final class QuickAccessTests: XCTestCase {
    func testCatalogIndexesConcreteAliasHostNameAndUserButExcludesPatterns() throws {
        let document = SSHConfigDocument(source: """
        Host *.example.com !blocked prod-api
          HostName 10.20.30.40
          User deployer

        Host prod-api
          HostName duplicate.example.com

        Host !negative-only
          HostName hidden.example.com
        """)

        let catalog = QuickAccessCatalog(document: document)

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
    }

    func testFuzzySearchMatchesAliasHostNameAndUser() {
        let host = makeHostEntry(
            alias: "prod-api-eu",
            hostName: "api.eu.example.com",
            user: "deployer"
        )
        let otherHost = makeHostEntry(alias: "stage-worker", hostID: 2)
        let entries = [host, otherHost]

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
            QuickAccessSearchEngine.search(query: "stgwrkr", entries: entries).first?.entry.id,
            otherHost.id
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

    func testActionPolicyRoutesHostActionsAndBlocksDeprecatedGroupKind() throws {
        let host = makeHostEntry(alias: "prod-api", hostID: 42)

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

        // `.group`-kind entries only exist as decode-compat leftovers now —
        // no catalog/entry-building path constructs one — so the policy
        // must never route anything for them.
        let deprecatedGroupEntry = QuickAccessEntry(
            id: UUID(),
            kind: .group,
            hostID: nil,
            alias: nil,
            title: "Legacy Group",
            subtitle: nil,
            searchFields: [],
            isFavorite: false,
            lastUsedAt: nil
        )
        XCTAssertTrue(QuickAccessActionPolicy.availableActions(for: deprecatedGroupEntry).isEmpty)
        XCTAssertNil(QuickAccessActionPolicy.route(action: .connect, entry: deprecatedGroupEntry))
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

    /// Pre-workspace quick-access.json files may still carry a `.group`-kind
    /// record (connection groups were removed in Phase D). `QuickAccessMetadataRecord`
    /// keeps the ability to decode `"kind":"group"` so those old files don't
    /// fail to load outright, and `QuickAccessLibrary.load` prunes any such
    /// record the first time it reconciles against a (group-less) catalog.
    @MainActor
    func testLegacyGroupKindRecordDecodesThenIsPrunedOnReconcile() throws {
        let groupID = UUID()
        let recordID = UUID()
        let json = """
        {
            "version": 1,
            "records": [
                {
                    "id": "\(recordID.uuidString)",
                    "kind": "group",
                    "groupID": "\(groupID.uuidString)",
                    "aliasHistory": [],
                    "isFavorite": true
                },
                {
                    "id": "\(UUID().uuidString)",
                    "kind": "host",
                    "alias": "prod-api",
                    "aliasHistory": [],
                    "isFavorite": false
                }
            ]
        }
        """
        let decoded = try JSONDecoder().decode(
            QuickAccessMetadataState.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.records.count, 2)
        XCTAssertEqual(decoded.records.first?.kind, .group)
        XCTAssertEqual(decoded.records.first?.groupID, groupID)

        let store = InMemoryQuickAccessStore()
        store.state = decoded
        let library = QuickAccessLibrary(store: store)

        library.load(catalog: catalog(hosts: ["prod-api"]))

        XCTAssertFalse(library.metadata.records.contains { $0.kind == .group })
        XCTAssertTrue(library.metadata.records.contains { $0.kind == .host && $0.alias == "prod-api" })
        // The prune must actually be written back, not just reflected
        // in-memory, so a re-launch never re-reads the pruned record.
        XCTAssertFalse(store.state.records.contains { $0.kind == .group })
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
        QuickAccessCatalog(hosts: aliases.map(host))
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
