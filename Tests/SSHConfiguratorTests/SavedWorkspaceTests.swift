import Foundation
import XCTest
@testable import SSHConfigurator

// MARK: - Mocks

final class MockSavedWorkspaceStore: SavedWorkspacePersisting {
    var savedWorkspaces: [SavedWorkspace] = []
    var shouldFailLoad = false
    var shouldFailSave = false

    func load() throws -> [SavedWorkspace] {
        if shouldFailLoad {
            throw NSError(domain: "test", code: 1, userInfo: nil)
        }
        return savedWorkspaces
    }

    func save(_ workspaces: [SavedWorkspace]) throws {
        if shouldFailSave {
            throw NSError(
                domain: "SavedWorkspaceTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "disk full"]
            )
        }
        savedWorkspaces = workspaces
    }
}

// MARK: - Store

final class SavedWorkspaceStoreTests: XCTestCase {
    func testMissingFileLoadsAsEmptyList() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("workspaces.json")

        XCTAssertEqual(try SavedWorkspaceStore(fileURL: fileURL).load(), [])
    }

    func testCorruptFileThrows() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("workspaces.json")
        try Data("not json".utf8).write(to: fileURL)

        XCTAssertThrowsError(try SavedWorkspaceStore(fileURL: fileURL).load())
    }

    func testRoundTripsMultipleWorkspacesWithOwnerOnlyFileAndDirectoryPermissions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = root.appendingPathComponent("nested", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: directory.path
        )
        let fileURL = directory.appendingPathComponent("workspaces.json")
        let store = SavedWorkspaceStore(fileURL: fileURL)

        let paneID = UUID()
        let workspaceA = SavedWorkspace(
            name: "prod fleet",
            sessions: [
                SavedWorkspaceSession(
                    hostID: 1,
                    alias: "prod",
                    layout: .pane(SavedWorkspacePane(id: paneID, alias: "prod", startup: .command("htop"))),
                    activePaneID: paneID
                ),
            ]
        )
        let workspaceB = SavedWorkspace(name: "empty-ish", sessions: [])

        try store.save([workspaceA, workspaceB])

        let loaded = try store.load()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(Set(loaded.map(\.id)), Set([workspaceA.id, workspaceB.id]))
        XCTAssertEqual(loaded.first(where: { $0.id == workspaceA.id })?.name, "prod fleet")
        XCTAssertEqual(try permissions(at: fileURL), 0o600)
        XCTAssertEqual(try permissions(at: directory), 0o700)
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let posix = attributes[.posixPermissions] as? NSNumber
        return posix?.intValue ?? -1
    }
}

final class SavedWorkspacePaneLayoutCodableTests: XCTestCase {
    func testSplitWithoutRatioDecodesAsHalf() throws {
        let firstID = UUID()
        let secondID = UUID()
        let data = try XCTUnwrap("""
        {
            "type": "split",
            "axis": "vertical",
            "first": {"type":"pane","pane":{"id":"\(firstID.uuidString)","alias":"prod"}},
            "second": {"type":"pane","pane":{"id":"\(secondID.uuidString)","alias":"db"}}
        }
        """.data(using: .utf8))

        let layout = try JSONDecoder().decode(SavedWorkspacePaneLayout.self, from: data)

        guard case let .split(_, ratio, _, _) = layout else {
            return XCTFail("Split layout expected")
        }
        XCTAssertEqual(ratio, 0.5)
    }

    func testEachOverrideCaseRoundTripsThroughTheSnapshotLayout() throws {
        let flowProfile = StartupFlowProfile(alias: "prod", automaticallyRun: false, steps: [.runCommand("echo hi")])
        let panes = [
            SavedWorkspacePane(id: UUID(), alias: "prod", startup: .command("htop")),
            SavedWorkspacePane(id: UUID(), alias: "prod", startup: .flow(flowProfile)),
            SavedWorkspacePane(id: UUID(), alias: "prod", startup: .suppressed),
            SavedWorkspacePane(id: UUID(), alias: "prod"),
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for pane in panes {
            let layout = SavedWorkspacePaneLayout.pane(pane)
            let data = try encoder.encode(layout)
            let decoded = try decoder.decode(SavedWorkspacePaneLayout.self, from: data)
            XCTAssertEqual(decoded, layout)
        }
    }
}

// MARK: - Capture

final class SavedWorkspaceCaptureTests: XCTestCase {
    func testCaptureSplitSessionWithPerPaneOverridesSyncSetAndCustomTitle() throws {
        let builder = makeLaunchPlanBuilder()
        let firstPane = try builder.makePane(alias: "prod", startupOverride: .command("htop"))
        let secondPane = try builder.makePane(alias: "db", startupOverride: .suppressed)
        var session = TerminalSession(
            hostID: 1,
            alias: "prod",
            initialPane: firstPane,
            customTitle: "My fleet"
        )
        session.layout = .split(id: UUID(), axis: .vertical, ratio: 0.4, first: .pane(firstPane), second: .pane(secondPane))
        session.activePaneID = secondPane.id
        session.synchronizedPaneIDs = [firstPane.id, secondPane.id]
        session.zoomedPaneID = firstPane.id

        let workspace = SavedWorkspace.capture(name: "Snapshot", from: [session])

        XCTAssertEqual(workspace.name, "Snapshot")
        XCTAssertEqual(workspace.sessions.count, 1)
        let savedSession = workspace.sessions[0]
        XCTAssertEqual(savedSession.hostID, 1)
        XCTAssertEqual(savedSession.alias, "prod")
        XCTAssertEqual(savedSession.customTitle, "My fleet")
        XCTAssertEqual(savedSession.activePaneID, secondPane.id)
        XCTAssertEqual(Set(savedSession.synchronizedPaneIDs), [firstPane.id, secondPane.id])

        guard case let .split(axis, ratio, first, second) = savedSession.layout else {
            return XCTFail("Split layout expected")
        }
        XCTAssertEqual(axis, .vertical)
        XCTAssertEqual(ratio, 0.4, accuracy: 0.0001)
        guard case let .pane(savedFirst) = first, case let .pane(savedSecond) = second else {
            return XCTFail("Pane leaves expected")
        }
        XCTAssertEqual(savedFirst.id, firstPane.id)
        XCTAssertEqual(savedFirst.alias, "prod")
        XCTAssertEqual(savedFirst.startup, .command("htop"))
        XCTAssertEqual(savedSecond.id, secondPane.id)
        XCTAssertEqual(savedSecond.startup, .suppressed)

        XCTAssertEqual(workspace.tabCount, 1)
        XCTAssertEqual(workspace.paneCount, 2)
    }

    func testCaptureIncludesExitedPaneAndDropsZoom() throws {
        let builder = makeLaunchPlanBuilder()
        var pane = try builder.makePane(alias: "prod")
        pane.status = .exited(1)
        var session = TerminalSession(hostID: 1, alias: "prod", initialPane: pane)
        session.zoomedPaneID = pane.id

        let workspace = SavedWorkspace.capture(name: "Snapshot", from: [session])

        XCTAssertEqual(workspace.sessions.count, 1)
        XCTAssertEqual(workspace.sessions[0].layout.panes.count, 1)
        XCTAssertEqual(workspace.sessions[0].layout.panes[0].id, pane.id)
        // No zoom field exists anywhere on the snapshot types — capture simply
        // never looks at `zoomedPaneID`.
    }
}

// MARK: - Library

@MainActor
final class SavedWorkspaceLibraryTests: XCTestCase {
    func testSaveInsertsNewWorkspace() {
        let store = MockSavedWorkspaceStore()
        let library = SavedWorkspaceLibrary(store: store)
        let workspace = SavedWorkspace(name: "First", sessions: [])

        XCTAssertTrue(library.save(workspace))

        XCTAssertEqual(library.workspaces.count, 1)
        XCTAssertEqual(library.workspaces[0].id, workspace.id)
        XCTAssertEqual(store.savedWorkspaces.count, 1)
    }

    func testSaveWithSameIDReplacesAndBumpsUpdatedAt() {
        let store = MockSavedWorkspaceStore()
        let library = SavedWorkspaceLibrary(store: store)
        let originalDate = Date(timeIntervalSince1970: 0)
        let workspace = SavedWorkspace(name: "First", createdAt: originalDate, updatedAt: originalDate, sessions: [])
        XCTAssertTrue(library.save(workspace))

        var renamed = workspace
        renamed.name = "Renamed"
        XCTAssertTrue(library.save(renamed))

        XCTAssertEqual(library.workspaces.count, 1)
        XCTAssertEqual(library.workspaces[0].name, "Renamed")
        XCTAssertGreaterThan(library.workspaces[0].updatedAt, originalDate)
    }

    func testDeleteRemovesWorkspace() {
        let store = MockSavedWorkspaceStore()
        let library = SavedWorkspaceLibrary(store: store)
        let workspace = SavedWorkspace(name: "First", sessions: [])
        library.save(workspace)

        XCTAssertTrue(library.delete(id: workspace.id))

        XCTAssertTrue(library.workspaces.isEmpty)
        XCTAssertTrue(store.savedWorkspaces.isEmpty)
    }

    func testStoreErrorSetsErrorMessage() {
        let store = MockSavedWorkspaceStore()
        store.shouldFailSave = true
        let library = SavedWorkspaceLibrary(store: store)

        XCTAssertFalse(library.save(SavedWorkspace(name: "First", sessions: [])))

        XCTAssertNotNil(library.errorMessage)
    }

    func testLoadSurfacesStoreError() {
        let store = MockSavedWorkspaceStore()
        store.shouldFailLoad = true
        let library = SavedWorkspaceLibrary(store: store)

        library.load()

        XCTAssertNotNil(library.errorMessage)
    }
}

// MARK: - Open

@MainActor
final class SavedWorkspaceOpenTests: XCTestCase {
    func testOpenAppendsAfterExistingSessionsWithoutTouchingThemAndSelectsFirstAppended() {
        let model = TerminalWorkspaceModel(
            launchPlanBuilder: makeLaunchPlanBuilder(),
            workspaceStore: MockWorkspaceLayoutStore()
        )
        XCTAssertTrue(model.openConnection(hostID: 1, alias: "existing", hasUnsavedChanges: false))
        let existingSessionID = try! XCTUnwrap(model.selectedSessionID)

        let paneID = UUID()
        let workspace = SavedWorkspace(
            name: "Snapshot",
            sessions: [
                SavedWorkspaceSession(
                    hostID: 2,
                    alias: "prod",
                    layout: .pane(SavedWorkspacePane(id: paneID, alias: "prod")),
                    activePaneID: paneID
                ),
            ]
        )

        let outcome = model.openSavedWorkspace(workspace, hasUnsavedChanges: false)

        XCTAssertNotNil(outcome)
        XCTAssertEqual(outcome?.skippedAliases, [])
        XCTAssertEqual(model.sessions.count, 2)
        XCTAssertEqual(model.sessions[0].id, existingSessionID)
        XCTAssertEqual(model.sessions[0].alias, "existing")
        let appendedSession = model.sessions[1]
        XCTAssertEqual(appendedSession.alias, "prod")
        XCTAssertEqual(model.selectedSessionID, appendedSession.id)
        XCTAssertEqual(outcome?.openedSessionIDs, [appendedSession.id])
    }

    func testSameHostTwoPanesWithDifferentCommandOverridesProduceDistinctBootstrapArgvs() {
        let model = TerminalWorkspaceModel(
            launchPlanBuilder: makeLaunchPlanBuilder(),
            workspaceStore: MockWorkspaceLayoutStore()
        )
        let firstID = UUID()
        let secondID = UUID()
        let workspace = SavedWorkspace(
            name: "Snapshot",
            sessions: [
                SavedWorkspaceSession(
                    hostID: 1,
                    alias: "prod",
                    layout: .split(
                        axis: .vertical,
                        ratio: 0.5,
                        first: .pane(SavedWorkspacePane(id: firstID, alias: "prod", startup: .command("htop"))),
                        second: .pane(SavedWorkspacePane(id: secondID, alias: "prod", startup: .command("iotop")))
                    ),
                    activePaneID: firstID
                ),
            ]
        )

        let outcome = model.openSavedWorkspace(workspace, hasUnsavedChanges: false)

        XCTAssertNotNil(outcome)
        let panes = model.sessions[0].panes
        XCTAssertEqual(panes.count, 2)
        let argvs = panes.map { $0.process.arguments.last ?? "" }
        XCTAssertTrue(argvs.contains { $0.contains("htop") })
        XCTAssertTrue(argvs.contains { $0.contains("iotop") })
    }

    func testDoubleOpenSameWorkspaceProducesDisjointPaneAndSessionIDs() {
        let model = TerminalWorkspaceModel(
            launchPlanBuilder: makeLaunchPlanBuilder(),
            workspaceStore: MockWorkspaceLayoutStore()
        )
        let paneID = UUID()
        let workspace = SavedWorkspace(
            name: "Snapshot",
            sessions: [
                SavedWorkspaceSession(
                    hostID: 1,
                    alias: "prod",
                    layout: .pane(SavedWorkspacePane(id: paneID, alias: "prod")),
                    activePaneID: paneID
                ),
            ]
        )

        let firstOutcome = try! XCTUnwrap(model.openSavedWorkspace(workspace, hasUnsavedChanges: false))
        let secondOutcome = try! XCTUnwrap(model.openSavedWorkspace(workspace, hasUnsavedChanges: false))

        XCTAssertEqual(model.sessions.count, 2)
        XCTAssertNotEqual(firstOutcome.openedSessionIDs, secondOutcome.openedSessionIDs)
        let allPaneIDs = model.sessions.flatMap { $0.panes.map(\.id) }
        XCTAssertEqual(Set(allPaneIDs).count, allPaneIDs.count)
    }

    func testMissingAliasPrunedAndReportedAndSplitCollapses() {
        let model = TerminalWorkspaceModel(
            launchPlanBuilder: makeLaunchPlanBuilder(),
            workspaceStore: MockWorkspaceLayoutStore()
        )
        let survivingID = UUID()
        let missingID = UUID()
        let workspace = SavedWorkspace(
            name: "Snapshot",
            sessions: [
                SavedWorkspaceSession(
                    hostID: 1,
                    alias: "prod",
                    layout: .split(
                        axis: .vertical,
                        ratio: 0.5,
                        first: .pane(SavedWorkspacePane(id: survivingID, alias: "prod")),
                        second: .pane(SavedWorkspacePane(id: missingID, alias: "gone"))
                    ),
                    activePaneID: survivingID
                ),
            ]
        )

        let outcome = model.openSavedWorkspace(
            workspace,
            hasUnsavedChanges: false,
            validAliases: ["prod"]
        )

        XCTAssertNotNil(outcome)
        XCTAssertEqual(outcome?.skippedAliases, ["gone"])
        XCTAssertEqual(model.sessions.count, 1)
        let survivingSession = model.sessions[0]
        // Split collapsed to the single surviving pane.
        guard case .pane = survivingSession.layout else {
            return XCTFail("Split expected to collapse to a single pane")
        }
        XCTAssertEqual(survivingSession.panes.count, 1)
        XCTAssertEqual(survivingSession.panes[0].alias, "prod")
    }

    func testSessionFullyPrunedIsDroppedButOpenSucceedsForTheRest() {
        let model = TerminalWorkspaceModel(
            launchPlanBuilder: makeLaunchPlanBuilder(),
            workspaceStore: MockWorkspaceLayoutStore()
        )
        let goodPaneID = UUID()
        let badPaneID = UUID()
        let workspace = SavedWorkspace(
            name: "Snapshot",
            sessions: [
                SavedWorkspaceSession(
                    hostID: 1,
                    alias: "prod",
                    layout: .pane(SavedWorkspacePane(id: goodPaneID, alias: "prod")),
                    activePaneID: goodPaneID
                ),
                SavedWorkspaceSession(
                    hostID: 2,
                    alias: "gone",
                    layout: .pane(SavedWorkspacePane(id: badPaneID, alias: "gone")),
                    activePaneID: badPaneID
                ),
            ]
        )

        let outcome = model.openSavedWorkspace(
            workspace,
            hasUnsavedChanges: false,
            validAliases: ["prod"]
        )

        XCTAssertNotNil(outcome)
        XCTAssertEqual(outcome?.skippedAliases, ["gone"])
        XCTAssertEqual(model.sessions.count, 1)
        XCTAssertEqual(model.sessions[0].alias, "prod")
    }

    func testAllSessionsPrunedReturnsNilWithErrorMessage() {
        let model = TerminalWorkspaceModel(
            launchPlanBuilder: makeLaunchPlanBuilder(),
            workspaceStore: MockWorkspaceLayoutStore()
        )
        let paneID = UUID()
        let workspace = SavedWorkspace(
            name: "Snapshot",
            sessions: [
                SavedWorkspaceSession(
                    hostID: 1,
                    alias: "gone",
                    layout: .pane(SavedWorkspacePane(id: paneID, alias: "gone")),
                    activePaneID: paneID
                ),
            ]
        )

        let outcome = model.openSavedWorkspace(
            workspace,
            hasUnsavedChanges: false,
            validAliases: ["prod"]
        )

        XCTAssertNil(outcome)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.sessions.isEmpty)
    }

    func testHasUnsavedChangesReturnsNilWithErrorMessage() {
        let model = TerminalWorkspaceModel(
            launchPlanBuilder: makeLaunchPlanBuilder(),
            workspaceStore: MockWorkspaceLayoutStore()
        )
        let paneID = UUID()
        let workspace = SavedWorkspace(
            name: "Snapshot",
            sessions: [
                SavedWorkspaceSession(
                    hostID: 1,
                    alias: "prod",
                    layout: .pane(SavedWorkspacePane(id: paneID, alias: "prod")),
                    activePaneID: paneID
                ),
            ]
        )

        let outcome = model.openSavedWorkspace(workspace, hasUnsavedChanges: true)

        XCTAssertNil(outcome)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.sessions.isEmpty)
    }

    func testSkipAllStartupsMarksPanesSkippedMatchingMakePaneSemantics() {
        let model = TerminalWorkspaceModel(
            launchPlanBuilder: makeLaunchPlanBuilder(),
            workspaceStore: MockWorkspaceLayoutStore()
        )
        let paneID = UUID()
        let workspace = SavedWorkspace(
            name: "Snapshot",
            sessions: [
                SavedWorkspaceSession(
                    hostID: 1,
                    alias: "prod",
                    layout: .pane(SavedWorkspacePane(id: paneID, alias: "prod", startup: .command("htop"))),
                    activePaneID: paneID
                ),
            ]
        )

        let outcome = model.openSavedWorkspace(workspace, hasUnsavedChanges: false, skipAllStartups: true)

        XCTAssertNotNil(outcome)
        let pane = model.sessions[0].panes[0]
        XCTAssertEqual(pane.startupState, .skipped)
        XCTAssertFalse(pane.process.arguments.last?.contains("htop") == true)
    }

    func testSyncSetRemapsWhenBothSurviveAndClearsWhenOnlyOneSurvives() {
        let modelBothSurvive = TerminalWorkspaceModel(
            launchPlanBuilder: makeLaunchPlanBuilder(),
            workspaceStore: MockWorkspaceLayoutStore()
        )
        let firstID = UUID()
        let secondID = UUID()
        let bothSurviveWorkspace = SavedWorkspace(
            name: "Snapshot",
            sessions: [
                SavedWorkspaceSession(
                    hostID: 1,
                    alias: "prod",
                    layout: .split(
                        axis: .vertical,
                        ratio: 0.5,
                        first: .pane(SavedWorkspacePane(id: firstID, alias: "prod")),
                        second: .pane(SavedWorkspacePane(id: secondID, alias: "prod"))
                    ),
                    activePaneID: firstID,
                    synchronizedPaneIDs: [firstID, secondID]
                ),
            ]
        )

        modelBothSurvive.openSavedWorkspace(bothSurviveWorkspace, hasUnsavedChanges: false)

        let survivingSession = modelBothSurvive.sessions[0]
        XCTAssertEqual(survivingSession.synchronizedPaneIDs.count, 2)
        XCTAssertEqual(Set(survivingSession.panes.map(\.id)), survivingSession.synchronizedPaneIDs)

        let modelOneSurvives = TerminalWorkspaceModel(
            launchPlanBuilder: makeLaunchPlanBuilder(),
            workspaceStore: MockWorkspaceLayoutStore()
        )
        let goodID = UUID()
        let badID = UUID()
        let oneSurvivesWorkspace = SavedWorkspace(
            name: "Snapshot",
            sessions: [
                SavedWorkspaceSession(
                    hostID: 1,
                    alias: "prod",
                    layout: .split(
                        axis: .vertical,
                        ratio: 0.5,
                        first: .pane(SavedWorkspacePane(id: goodID, alias: "prod")),
                        second: .pane(SavedWorkspacePane(id: badID, alias: "gone"))
                    ),
                    activePaneID: goodID,
                    synchronizedPaneIDs: [goodID, badID]
                ),
            ]
        )

        modelOneSurvives.openSavedWorkspace(
            oneSurvivesWorkspace,
            hasUnsavedChanges: false,
            validAliases: ["prod"]
        )

        XCTAssertTrue(modelOneSurvives.sessions[0].synchronizedPaneIDs.isEmpty)
    }
}

private func makeLaunchPlanBuilder() -> SSHLaunchPlanBuilder {
    SSHLaunchPlanBuilder(
        sshURL: URL(fileURLWithPath: "/usr/bin/ssh"),
        baseEnvironment: ["PATH": "/usr/bin:/bin"],
        currentDirectoryURL: URL(fileURLWithPath: "/tmp")
    )
}
