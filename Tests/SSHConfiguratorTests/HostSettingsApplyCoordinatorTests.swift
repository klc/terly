import Foundation
import XCTest
@testable import SSHConfigurator

final class HostSettingsApplyCoordinatorTests: XCTestCase {
    @MainActor
    func testQuickAccessMigrationFailureDoesNotStartStartupOrCommitConfig() throws {
        let quickStore = CoordinatorQuickAccessStore()
        let quickAccess = QuickAccessLibrary(store: quickStore)
        let catalogA = catalog(alias: "alias-a")
        quickAccess.load(catalog: catalogA)
        let entry = try XCTUnwrap(quickAccess.entries(for: catalogA).first)
        XCTAssertTrue(quickAccess.toggleFavorite(entryID: entry.id))

        let startupStore = CoordinatorStartupFlowStore()
        let startupFlows = startupLibrary(store: startupStore, alias: "alias-a")
        let startupSaveAttempts = startupStore.saveAttempts
        quickStore.failOnSaveAttempts.insert(quickStore.saveAttempts + 1)
        var configCommitCount = 0

        let succeeded = coordinator.apply(
            preparedConfigSource: "Host alias-b\n",
            profile: profile(alias: "alias-a"),
            oldAlias: "alias-a",
            newAlias: "alias-b",
            persistedAliases: ["alias-a"],
            rollbackCatalog: catalogA,
            startupFlows: startupFlows,
            quickAccess: quickAccess
        ) {
            configCommitCount += 1
        }

        XCTAssertFalse(succeeded)
        XCTAssertEqual(configCommitCount, 0)
        XCTAssertEqual(startupStore.saveAttempts, startupSaveAttempts)
        XCTAssertEqual(quickAccess.entries(for: catalogA).first?.id, entry.id)
        XCTAssertTrue(quickAccess.entries(for: catalogA).first?.isFavorite == true)
        XCTAssertNotNil(quickAccess.errorMessage)
    }

    @MainActor
    func testStartupMetadataFailureRollsQuickAccessBackBeforeConfigCommit() throws {
        let quickStore = CoordinatorQuickAccessStore()
        let quickAccess = QuickAccessLibrary(store: quickStore)
        let catalogA = catalog(alias: "alias-a")
        quickAccess.load(catalog: catalogA)
        let original = try XCTUnwrap(quickAccess.entries(for: catalogA).first)
        XCTAssertTrue(quickAccess.toggleFavorite(entryID: original.id))

        let startupStore = CoordinatorStartupFlowStore()
        let startupFlows = startupLibrary(store: startupStore, alias: "alias-a")
        startupStore.failOnSave = true
        var configCommitCount = 0

        let succeeded = coordinator.apply(
            preparedConfigSource: "Host alias-b\n",
            profile: profile(alias: "alias-a"),
            oldAlias: "alias-a",
            newAlias: "alias-b",
            persistedAliases: ["alias-a"],
            rollbackCatalog: catalogA,
            startupFlows: startupFlows,
            quickAccess: quickAccess
        ) {
            configCommitCount += 1
        }

        XCTAssertFalse(succeeded)
        XCTAssertEqual(configCommitCount, 0)
        let rolledBack = try XCTUnwrap(quickAccess.entries(for: catalogA).first)
        XCTAssertEqual(rolledBack.id, original.id)
        XCTAssertTrue(rolledBack.isFavorite)
        XCTAssertEqual(rolledBack.alias, "alias-a")
        XCTAssertFalse(quickStore.state.records.contains { $0.alias == "alias-b" })
        XCTAssertNotNil(startupFlows.errorMessage)
        XCTAssertNil(quickAccess.errorMessage)
    }

    @MainActor
    func testSuccessfulMetadataPreparationCommitsConfigOnceAndKeepsStableIdentity() throws {
        let quickStore = CoordinatorQuickAccessStore()
        let quickAccess = QuickAccessLibrary(store: quickStore)
        let catalogA = catalog(alias: "alias-a")
        let catalogB = catalog(alias: "alias-b")
        quickAccess.load(catalog: catalogA)
        let original = try XCTUnwrap(quickAccess.entries(for: catalogA).first)
        XCTAssertTrue(quickAccess.toggleFavorite(entryID: original.id))

        let startupStore = CoordinatorStartupFlowStore()
        let startupFlows = startupLibrary(store: startupStore, alias: "alias-a")
        var configCommitCount = 0

        let succeeded = coordinator.apply(
            preparedConfigSource: "Host alias-b\n",
            profile: profile(alias: "alias-a"),
            oldAlias: "alias-a",
            newAlias: "alias-b",
            persistedAliases: ["alias-a"],
            rollbackCatalog: catalogA,
            startupFlows: startupFlows,
            quickAccess: quickAccess
        ) {
            configCommitCount += 1
        }

        XCTAssertTrue(succeeded)
        XCTAssertEqual(configCommitCount, 1)
        let migrated = try XCTUnwrap(quickAccess.entries(for: catalogB).first)
        XCTAssertEqual(migrated.id, original.id)
        XCTAssertTrue(migrated.isFavorite)
        XCTAssertEqual(migrated.alias, "alias-b")
        XCTAssertEqual(startupStore.state.pendingChanges.first?.after.alias, "alias-b")
    }

    @MainActor
    func testRollbackPersistenceFailureRemainsVisible() throws {
        let quickStore = CoordinatorQuickAccessStore()
        let quickAccess = QuickAccessLibrary(store: quickStore)
        let catalogA = catalog(alias: "alias-a")
        quickAccess.load(catalog: catalogA)
        let original = try XCTUnwrap(quickAccess.entries(for: catalogA).first)
        XCTAssertTrue(quickAccess.toggleFavorite(entryID: original.id))
        // Sonraki save migration, onu izleyen save rollback'tir.
        quickStore.failOnSaveAttempts.insert(quickStore.saveAttempts + 2)

        let startupStore = CoordinatorStartupFlowStore()
        let startupFlows = startupLibrary(store: startupStore, alias: "alias-a")
        startupStore.failOnSave = true

        XCTAssertFalse(coordinator.apply(
            preparedConfigSource: "Host alias-b\n",
            profile: profile(alias: "alias-a"),
            oldAlias: "alias-a",
            newAlias: "alias-b",
            persistedAliases: ["alias-a"],
            rollbackCatalog: catalogA,
            startupFlows: startupFlows,
            quickAccess: quickAccess,
            commitConfigWorkingCopy: { XCTFail("Config commit edilmemeli") }
        ))

        XCTAssertNotNil(quickAccess.errorMessage)
    }

    @MainActor
    private var coordinator: HostSettingsApplyCoordinator {
        HostSettingsApplyCoordinator()
    }

    private func catalog(alias: String) -> QuickAccessCatalog {
        QuickAccessCatalog(
            hosts: [.init(hostID: 1, alias: alias, hostName: nil, user: nil)],
            groups: []
        )
    }

    private func profile(alias: String) -> StartupFlowProfile {
        StartupFlowProfile(alias: alias, steps: [.runCommand("uptime")])
    }

    @MainActor
    private func startupLibrary(
        store: CoordinatorStartupFlowStore,
        alias: String
    ) -> StartupFlowLibrary {
        let library = StartupFlowLibrary(store: store)
        let source = "Host \(alias)\n"
        library.load(context: StartupFlowReconciliationContext(
            workingSource: source,
            persistedSource: source,
            workingAliases: [alias],
            persistedAliases: [alias]
        ))
        return library
    }
}

private final class CoordinatorQuickAccessStore: QuickAccessPersisting {
    enum Failure: Error { case save }

    var state = QuickAccessMetadataState()
    var saveAttempts = 0
    var failOnSaveAttempts: Set<Int> = []

    func load() throws -> QuickAccessMetadataState { state }

    func save(_ state: QuickAccessMetadataState) throws {
        saveAttempts += 1
        if failOnSaveAttempts.contains(saveAttempts) { throw Failure.save }
        self.state = state
    }
}

private final class CoordinatorStartupFlowStore: StartupFlowPersisting {
    enum Failure: Error { case save }

    var state = StartupFlowMetadataState()
    var saveAttempts = 0
    var failOnSave = false

    func load() throws -> StartupFlowMetadataState { state }

    func save(_ state: StartupFlowMetadataState) throws {
        saveAttempts += 1
        if failOnSave { throw Failure.save }
        self.state = state
    }
}
