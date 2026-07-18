import Foundation
import XCTest
@testable import SSHConfigurator

final class StartupFlowStoreTests: XCTestCase {
    func testAtomicallySavesAndLoadsStateWithOwnerOnlyFileAndDirectoryPermissions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = root.appendingPathComponent("nested", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: directory.path
        )
        let fileURL = directory.appendingPathComponent("startup-flows.json")
        let store = StartupFlowStore(fileURL: fileURL)
        let state = StartupFlowMetadataState(profiles: [
            StartupFlowProfile(
                id: UUID(),
                alias: "prod-api",
                automaticallyRun: true,
                steps: [.changeUser("deploy"), .changeDirectory("/srv/api")]
            ),
        ])

        try store.save(state)

        XCTAssertEqual(try store.load(), state)
        XCTAssertEqual(try permissions(at: fileURL), 0o600)
        XCTAssertEqual(try permissions(at: directory), 0o700)
    }

    func testMissingMetadataLoadsAsEmptyState() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("startup-flows.json")

        XCTAssertEqual(try StartupFlowStore(fileURL: fileURL).load(), StartupFlowMetadataState())
    }

    func testLoadsLegacyRootProfileArrayWithoutDataLoss() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("startup-flows.json")
        let profiles = [StartupFlowProfile(alias: "legacy", steps: [.runCommand("uptime")])]
        try JSONEncoder().encode(profiles).write(to: fileURL)

        let state = try StartupFlowStore(fileURL: fileURL).load()

        XCTAssertEqual(state.version, 2)
        XCTAssertEqual(state.profiles, profiles)
        XCTAssertTrue(state.pendingChanges.isEmpty)
    }

    @MainActor
    func testStartupOnlyEditCommitsWithoutPendingTransaction() throws {
        let original = StartupFlowProfile(alias: "prod", steps: [.runCommand("uptime")])
        let store = InMemoryStartupFlowStore(state: .init(profiles: [original]))
        let library = StartupFlowLibrary(store: store)
        library.load(context: context(working: "Host prod\n", persisted: "Host prod\n", aliases: ["prod"]))
        var edited = original
        edited.automaticallyRun = true

        XCTAssertTrue(library.save(edited))

        XCTAssertEqual(store.state.profiles, [edited])
        XCTAssertTrue(store.state.pendingChanges.isEmpty)
        XCTAssertEqual(library.profile(for: "prod"), edited)
    }

    @MainActor
    func testExistingAliasMigrationCommitsOnlyAfterSSHConfigSaveAndKeepsUUID() throws {
        let id = UUID()
        let original = StartupFlowProfile(id: id, alias: "old-prod", steps: [.changeDirectory("/srv")])
        let oldSource = "Host old-prod\n"
        let newSource = "Host new-prod\n"
        let store = InMemoryStartupFlowStore(state: .init(profiles: [original]))
        let library = StartupFlowLibrary(store: store)
        library.load(context: context(working: oldSource, persisted: oldSource, aliases: ["old-prod"]))
        var migrated = original
        migrated.alias = "new-prod"

        XCTAssertTrue(library.save(
            migrated,
            pendingUntilConfigFingerprint: StartupFlowConfigFingerprint.make(newSource)
        ))
        XCTAssertEqual(store.state.profiles, [original], "Config kaydedilmeden committed metadata değişmemeli")
        XCTAssertEqual(store.state.pendingChanges.count, 1)

        XCTAssertTrue(library.reconcile(context: context(
            working: newSource,
            persisted: oldSource,
            aliases: ["new-prod"],
            persistedAliases: ["old-prod"]
        )))
        XCTAssertEqual(library.profile(for: "new-prod")?.id, id)
        XCTAssertEqual(store.state.profiles, [original])

        XCTAssertTrue(library.reconcile(context: context(
            working: newSource,
            persisted: newSource,
            aliases: ["new-prod"]
        )))
        XCTAssertEqual(store.state.profiles.first?.alias, "new-prod")
        XCTAssertEqual(store.state.profiles.first?.id, id)
        XCTAssertTrue(store.state.pendingChanges.isEmpty)
    }

    @MainActor
    func testRollbackOrLoadOfOldConfigCancelsPendingAliasMigration() throws {
        let original = StartupFlowProfile(alias: "old-prod", steps: [.runCommand("uptime")])
        let oldSource = "Host old-prod\n"
        let newSource = "Host new-prod\n"
        let store = InMemoryStartupFlowStore(state: .init(profiles: [original]))
        let library = StartupFlowLibrary(store: store)
        library.load(context: context(working: oldSource, persisted: oldSource, aliases: ["old-prod"]))
        var migrated = original
        migrated.alias = "new-prod"
        XCTAssertTrue(library.save(
            migrated,
            pendingUntilConfigFingerprint: StartupFlowConfigFingerprint.make(newSource)
        ))
        XCTAssertTrue(library.reconcile(context: context(
            working: newSource,
            persisted: oldSource,
            aliases: ["new-prod"],
            persistedAliases: ["old-prod"]
        )))

        XCTAssertTrue(library.reconcile(context: context(
            working: oldSource,
            persisted: oldSource,
            aliases: ["old-prod"]
        )))

        XCTAssertEqual(store.state.profiles, [original])
        XCTAssertTrue(store.state.pendingChanges.isEmpty)
        XCTAssertEqual(library.profile(for: "old-prod"), original)
        XCTAssertNil(library.profile(for: "new-prod"))
    }

    @MainActor
    func testNewHostProfileIsRemovedWhenUnsavedConfigChangeIsUndone() throws {
        let oldSource = "Host existing\n"
        let newSource = oldSource + "Host new-prod\n"
        let profile = StartupFlowProfile(alias: "new-prod", steps: [.runCommand("uptime")])
        let store = InMemoryStartupFlowStore()
        let library = StartupFlowLibrary(store: store)
        library.load(context: context(working: oldSource, persisted: oldSource, aliases: ["existing"]))

        XCTAssertTrue(library.save(
            profile,
            pendingUntilConfigFingerprint: StartupFlowConfigFingerprint.make(newSource)
        ))
        XCTAssertTrue(library.reconcile(context: context(
            working: newSource,
            persisted: oldSource,
            aliases: ["existing", "new-prod"],
            persistedAliases: ["existing"]
        )))
        XCTAssertNotNil(library.profile(for: "new-prod"))

        XCTAssertTrue(library.reconcile(context: context(
            working: oldSource,
            persisted: oldSource,
            aliases: ["existing"]
        )))
        XCTAssertNil(library.profile(for: "new-prod"))
        XCTAssertTrue(store.state.profiles.isEmpty)
        XCTAssertTrue(store.state.pendingChanges.isEmpty)
    }

    @MainActor
    func testCrashRecoveryCommitsPersistedPendingMetadataOnNextLoad() throws {
        let old = StartupFlowProfile(alias: "old-prod", steps: [.runCommand("uptime")])
        var migrated = old
        migrated.alias = "new-prod"
        let newSource = "Host new-prod\n"
        let pending = StartupFlowPendingChange(
            before: old,
            after: migrated,
            expectedConfigFingerprint: StartupFlowConfigFingerprint.make(newSource)
        )
        let store = InMemoryStartupFlowStore(state: .init(
            profiles: [old],
            pendingChanges: [pending]
        ))

        let libraryAfterRestart = StartupFlowLibrary(store: store)
        libraryAfterRestart.load(context: context(
            working: newSource,
            persisted: newSource,
            aliases: ["new-prod"]
        ))

        XCTAssertEqual(store.state.profiles, [migrated])
        XCTAssertTrue(store.state.pendingChanges.isEmpty)
        XCTAssertEqual(libraryAfterRestart.profile(for: "new-prod"), migrated)
    }

    @MainActor
    func testUnrelatedWorkingEditKeepsStagedAliasMigrationPending() throws {
        let original = StartupFlowProfile(alias: "old-prod", steps: [.runCommand("uptime")])
        var migrated = original
        migrated.alias = "new-prod"
        let oldSource = "Host old-prod\n"
        let expectedSource = "Host new-prod\n"
        let extendedWorkingSource = "ServerAliveInterval 30\n" + expectedSource
        let store = InMemoryStartupFlowStore(state: .init(profiles: [original]))
        let library = StartupFlowLibrary(store: store)
        library.load(context: context(working: oldSource, persisted: oldSource, aliases: ["old-prod"]))
        XCTAssertTrue(library.save(
            migrated,
            pendingUntilConfigFingerprint: StartupFlowConfigFingerprint.make(expectedSource)
        ))

        XCTAssertTrue(library.reconcile(context: context(
            working: extendedWorkingSource,
            persisted: oldSource,
            aliases: ["new-prod"],
            persistedAliases: ["old-prod"]
        )))

        XCTAssertEqual(store.state.profiles, [original])
        XCTAssertEqual(store.state.pendingChanges.count, 1)
        XCTAssertEqual(library.profile(for: "new-prod"), migrated)
    }

    @MainActor
    func testSavingExtendedSourceCommitsPendingAliasDespiteFingerprintDifference() throws {
        let original = StartupFlowProfile(alias: "old-prod", steps: [.runCommand("uptime")])
        var migrated = original
        migrated.alias = "new-prod"
        let oldSource = "Host old-prod\n"
        let expectedSource = "Host new-prod\n"
        let extendedSource = "ServerAliveInterval 30\n" + expectedSource
        let store = InMemoryStartupFlowStore(state: .init(profiles: [original]))
        let library = StartupFlowLibrary(store: store)
        library.load(context: context(working: oldSource, persisted: oldSource, aliases: ["old-prod"]))
        XCTAssertTrue(library.save(
            migrated,
            pendingUntilConfigFingerprint: StartupFlowConfigFingerprint.make(expectedSource)
        ))

        XCTAssertTrue(library.reconcile(context: context(
            working: extendedSource,
            persisted: extendedSource,
            aliases: ["new-prod"]
        )))

        XCTAssertEqual(store.state.profiles, [migrated])
        XCTAssertTrue(store.state.pendingChanges.isEmpty)
    }

    @MainActor
    func testRestartCommitsPendingWhenPersistedTargetAliasExistsWithDifferentFingerprint() throws {
        let original = StartupFlowProfile(alias: "old-prod", steps: [.runCommand("uptime")])
        var migrated = original
        migrated.alias = "new-prod"
        let expectedSource = "Host new-prod\n"
        let persistedSource = "ServerAliveInterval 30\n" + expectedSource
        let pending = StartupFlowPendingChange(
            before: original,
            after: migrated,
            expectedConfigFingerprint: StartupFlowConfigFingerprint.make(expectedSource)
        )
        let store = InMemoryStartupFlowStore(state: .init(
            profiles: [original],
            pendingChanges: [pending]
        ))

        let library = StartupFlowLibrary(store: store)
        library.load(context: context(
            working: persistedSource,
            persisted: persistedSource,
            aliases: ["new-prod"]
        ))

        XCTAssertEqual(store.state.profiles, [migrated])
        XCTAssertTrue(store.state.pendingChanges.isEmpty)
        XCTAssertEqual(library.profile(for: "new-prod"), migrated)
    }

    @MainActor
    func testStablePersistedAliasCommitsStartupProfileBeforeHostNameConfigSave() throws {
        let currentSource = "Host prod\n  HostName old.example.com\n"
        let preparedSource = "Host prod\n  HostName new.example.com\n"
        let profile = StartupFlowProfile(alias: "prod", steps: [.runCommand("uptime")])
        let store = InMemoryStartupFlowStore()
        let library = StartupFlowLibrary(store: store)
        library.load(context: context(
            working: currentSource,
            persisted: currentSource,
            aliases: ["prod"]
        ))
        var didCommitWorkingCopy = false

        XCTAssertTrue(StartupFlowHostEditService().apply(
            preparedConfigSource: preparedSource,
            profile: profile,
            newAlias: "prod",
            persistedAliases: ["prod"],
            library: library
        ) {
            didCommitWorkingCopy = true
        })

        XCTAssertTrue(didCommitWorkingCopy)
        XCTAssertEqual(store.state.profiles, [profile])
        XCTAssertTrue(store.state.pendingChanges.isEmpty)
    }

    @MainActor
    func testSecondAliasChangeCanBeUndoneBackThroughFirstPendingAlias() throws {
        let original = StartupFlowProfile(alias: "alias-a", steps: [.runCommand("uptime")])
        var aliasB = original
        aliasB.alias = "alias-b"
        var aliasC = original
        aliasC.alias = "alias-c"
        let sourceA = "Host alias-a\n"
        let sourceB = "Host alias-b\n"
        let sourceC = "Host alias-c\n"
        let store = InMemoryStartupFlowStore(state: .init(profiles: [original]))
        let library = StartupFlowLibrary(store: store)
        library.load(context: context(working: sourceA, persisted: sourceA, aliases: ["alias-a"]))

        XCTAssertTrue(library.save(
            aliasB,
            pendingUntilConfigFingerprint: StartupFlowConfigFingerprint.make(sourceB)
        ))
        XCTAssertTrue(library.reconcile(context: context(
            working: sourceB,
            persisted: sourceA,
            aliases: ["alias-b"],
            persistedAliases: ["alias-a"]
        )))
        XCTAssertTrue(library.save(
            aliasC,
            pendingUntilConfigFingerprint: StartupFlowConfigFingerprint.make(sourceC)
        ))
        XCTAssertTrue(library.reconcile(context: context(
            working: sourceC,
            persisted: sourceA,
            aliases: ["alias-c"],
            persistedAliases: ["alias-a"]
        )))
        XCTAssertEqual(store.state.pendingChanges.map(\.after.alias), ["alias-b", "alias-c"])
        XCTAssertEqual(library.profile(for: "alias-c"), aliasC)

        XCTAssertTrue(library.reconcile(context: context(
            working: sourceB,
            persisted: sourceA,
            aliases: ["alias-b"],
            persistedAliases: ["alias-a"]
        )))
        XCTAssertEqual(store.state.pendingChanges.map(\.after.alias), ["alias-b"])
        XCTAssertEqual(library.profile(for: "alias-b"), aliasB)

        XCTAssertTrue(library.reconcile(context: context(
            working: sourceA,
            persisted: sourceA,
            aliases: ["alias-a"]
        )))
        XCTAssertTrue(store.state.pendingChanges.isEmpty)
        XCTAssertEqual(library.profile(for: "alias-a"), original)
    }

    @MainActor
    func testMetadataFailureDoesNotMutateConfigWorkingCopyOrLibrary() throws {
        let source = "Host prod\n"
        let profile = StartupFlowProfile(alias: "prod", steps: [.runCommand("uptime")])
        let store = InMemoryStartupFlowStore(failOnSave: true)
        let library = StartupFlowLibrary(store: store)
        library.load(context: context(working: source, persisted: source, aliases: ["prod"]))
        var didCommitConfig = false

        let succeeded = StartupFlowHostEditService().apply(
            preparedConfigSource: source,
            profile: profile,
            newAlias: "prod",
            persistedAliases: ["prod"],
            library: library
        ) {
            didCommitConfig = true
        }

        XCTAssertFalse(succeeded)
        XCTAssertFalse(didCommitConfig)
        XCTAssertTrue(store.state.profiles.isEmpty)
        XCTAssertNil(library.profile(for: "prod"))
        XCTAssertNotNil(library.errorMessage)
    }

    @MainActor
    func testDocumentMutationReconciliationPolicyCoversRawEditDeleteUndoAndRestore() throws {
        let target = "Host new-prod\n"
        let change = StartupFlowPendingChange(
            before: nil,
            after: StartupFlowProfile(alias: "new-prod"),
            expectedConfigFingerprint: StartupFlowConfigFingerprint.make(target)
        )

        let workingTarget = context(
            working: target,
            persisted: "Host old-prod\n",
            aliases: ["new-prod"],
            persistedAliases: ["old-prod"]
        )
        XCTAssertEqual(StartupFlowReconciliationPolicy.decision(for: change, context: workingTarget), .keep)

        let matchingFingerprintWithoutConcreteAlias = context(
            working: target,
            persisted: "Host old-prod\n",
            aliases: [],
            persistedAliases: ["old-prod"]
        )
        XCTAssertEqual(
            StartupFlowReconciliationPolicy.decision(
                for: change,
                context: matchingFingerprintWithoutConcreteAlias
            ),
            .rollback
        )

        for source in ["", "Host raw-edit\n", "Host old-prod\n"] {
            let mutation = context(working: source, persisted: "Host old-prod\n", aliases: [])
            XCTAssertEqual(
                StartupFlowReconciliationPolicy.decision(for: change, context: mutation),
                .rollback
            )
        }

        let savedTarget = context(working: target, persisted: target, aliases: ["new-prod"])
        XCTAssertEqual(StartupFlowReconciliationPolicy.decision(for: change, context: savedTarget), .commit)
    }

    @MainActor
    func testExternalAliasLossBecomesOrphanAndCanBeReassigned() throws {
        let id = UUID()
        let profile = StartupFlowProfile(
            id: id,
            alias: "removed-prod",
            steps: [.runCommand("uptime")]
        )
        let store = InMemoryStartupFlowStore(state: .init(profiles: [profile]))
        let library = StartupFlowLibrary(store: store)
        library.load(context: context(
            working: "Host replacement-prod\n",
            persisted: "Host replacement-prod\n",
            aliases: ["replacement-prod"]
        ))
        XCTAssertEqual(library.orphanedRecords.map(\.id), [id])

        XCTAssertTrue(library.reassign(profileID: id, to: "replacement-prod"))

        XCTAssertTrue(library.orphanedRecords.isEmpty)
        XCTAssertEqual(library.profile(for: "replacement-prod")?.id, id)
    }

    @MainActor
    func testOrphanReassignmentToUnsavedAliasWaitsForConfigSave() throws {
        let profile = StartupFlowProfile(alias: "removed-prod", steps: [.runCommand("uptime")])
        let persistedSource = "Host existing\n"
        let workingSource = persistedSource + "Host replacement-prod\n"
        let store = InMemoryStartupFlowStore(state: .init(profiles: [profile]))
        let library = StartupFlowLibrary(store: store)
        library.load(context: context(
            working: workingSource,
            persisted: persistedSource,
            aliases: ["existing", "replacement-prod"],
            persistedAliases: ["existing"]
        ))

        XCTAssertTrue(library.reassign(profileID: profile.id, to: "replacement-prod"))

        XCTAssertEqual(store.state.profiles, [profile])
        XCTAssertEqual(store.state.pendingChanges.first?.after.alias, "replacement-prod")

        XCTAssertTrue(library.reconcile(context: context(
            working: persistedSource,
            persisted: persistedSource,
            aliases: ["existing"]
        )))
        XCTAssertEqual(store.state.profiles, [profile])
        XCTAssertTrue(store.state.pendingChanges.isEmpty)
    }

    func testStartupEditorPolicyRejectsWildcardAndNegativeOnlyHosts() {
        XCTAssertEqual(
            StartupFlowEditingPolicy.availability(for: ["*.example.com", "!blocked"]),
            .unavailable(
                message: "Başlangıç akışı yalnızca somut bir Host alias'ına bağlanabilir. Wildcard veya olumsuz desen için önce somut bir alias ekle."
            )
        )
        XCTAssertEqual(
            StartupFlowEditingPolicy.availability(for: ["*.example.com", "prod-api"]),
            .available(alias: "prod-api")
        )
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        return permissions.intValue & 0o777
    }

    private func context(
        working: String,
        persisted: String,
        aliases: Set<String>,
        persistedAliases: Set<String>? = nil
    ) -> StartupFlowReconciliationContext {
        StartupFlowReconciliationContext(
            workingSource: working,
            persistedSource: persisted,
            workingAliases: aliases,
            persistedAliases: persistedAliases ?? aliases
        )
    }
}

private final class InMemoryStartupFlowStore: StartupFlowPersisting {
    enum TestError: Error {
        case saveFailed
    }

    var state: StartupFlowMetadataState
    var failOnSave: Bool

    init(
        state: StartupFlowMetadataState = StartupFlowMetadataState(),
        failOnSave: Bool = false
    ) {
        self.state = state
        self.failOnSave = failOnSave
    }

    func load() throws -> StartupFlowMetadataState {
        state
    }

    func save(_ state: StartupFlowMetadataState) throws {
        if failOnSave {
            throw TestError.saveFailed
        }
        self.state = state
    }
}
