import XCTest
import Foundation
@testable import SSHConfigurator

final class MockWorkspaceLayoutStore: WorkspaceLayoutPersisting {
    var savedWorkspace: PersistedWorkspace?
    var shouldFailLoad = false
    var shouldFailSave = false

    func load() throws -> PersistedWorkspace {
        if shouldFailLoad {
            throw NSError(domain: "test", code: 1, userInfo: nil)
        }
        return savedWorkspace ?? PersistedWorkspace(sessions: [], selectedSessionID: nil)
    }

    func save(_ workspace: PersistedWorkspace) throws {
        if shouldFailSave {
            throw NSError(
                domain: "WorkspaceLayoutStoreTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "disk full"]
            )
        }
        savedWorkspace = workspace
    }
}

final class WorkspaceLayoutStoreTests: XCTestCase {
    
    func testCodableLayoutRoundTrip() throws {
        let pane = PersistedPane(id: UUID(), alias: "prod-host")
        let layout = PersistedPaneLayout.pane(pane)
        
        let splitLayout = PersistedPaneLayout.split(
            id: UUID(),
            axis: .vertical,
            ratio: 0.3,
            first: layout,
            second: .pane(PersistedPane(id: UUID(), alias: "db-host"))
        )
        
        let session = PersistedSession(
            id: UUID(),
            hostID: 10,
            alias: "prod-session",
            groupID: UUID(),
            layout: splitLayout,
            activePaneID: pane.id,
            synchronizedPaneIDs: [pane.id]
        )
        
        let workspace = PersistedWorkspace(
            sessions: [session],
            selectedSessionID: session.id
        )
        
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        let data = try encoder.encode(workspace)
        let decodedWorkspace = try decoder.decode(PersistedWorkspace.self, from: data)
        
        XCTAssertEqual(decodedWorkspace.selectedSessionID, workspace.selectedSessionID)
        XCTAssertEqual(decodedWorkspace.sessions.count, 1)
        XCTAssertEqual(decodedWorkspace.sessions[0].alias, "prod-session")
        XCTAssertEqual(decodedWorkspace.sessions[0].hostID, 10)
        XCTAssertEqual(decodedWorkspace.sessions[0].activePaneID, pane.id)
        XCTAssertFalse(decodedWorkspace.sessions[0].layout.panes[0].skippedAutomaticStartup)
        guard case let .split(_, _, ratio, _, _) = decodedWorkspace.sessions[0].layout else {
            return XCTFail("Split layout bekleniyordu")
        }
        XCTAssertEqual(ratio, 0.3)
    }

    func testLegacySplitWithoutRatioDecodesAsHalf() throws {
        let firstPaneID = UUID()
        let secondPaneID = UUID()
        let splitID = UUID()
        let data = try XCTUnwrap("""
        {
            "type": "split",
            "id": "\(splitID.uuidString)",
            "axis": "vertical",
            "first": {"type":"pane","pane":{"id":"\(firstPaneID.uuidString)","alias":"prod-host"}},
            "second": {"type":"pane","pane":{"id":"\(secondPaneID.uuidString)","alias":"db-host"}}
        }
        """.data(using: .utf8))

        let layout = try JSONDecoder().decode(PersistedPaneLayout.self, from: data)

        guard case let .split(_, _, ratio, _, _) = layout else {
            return XCTFail("Split layout bekleniyordu")
        }
        XCTAssertEqual(ratio, 0.5)
    }

    func testLegacyPersistedPaneDefaultsSkippedAutomaticStartupToFalse() throws {
        let paneID = UUID()
        let data = try XCTUnwrap("""
        {"id":"\(paneID.uuidString)","alias":"prod"}
        """.data(using: .utf8))

        let pane = try JSONDecoder().decode(PersistedPane.self, from: data)

        XCTAssertFalse(pane.skippedAutomaticStartup)
    }

    func testLegacyPersistedSessionDefaultsCustomTitleToNil() throws {
        let paneID = UUID()
        let sessionID = UUID()
        let data = try XCTUnwrap("""
        {
            "id":"\(sessionID.uuidString)",
            "hostID":1,
            "alias":"prod",
            "layout":{"type":"pane","pane":{"id":"\(paneID.uuidString)","alias":"prod"}},
            "activePaneID":"\(paneID.uuidString)",
            "synchronizedPaneIDs":[]
        }
        """.data(using: .utf8))

        let session = try JSONDecoder().decode(PersistedSession.self, from: data)

        XCTAssertNil(session.customTitle)
    }
    
    @MainActor
    func testWorkspaceAutoSavesOnMutations() {
        let mockStore = MockWorkspaceLayoutStore()
        let model = TerminalWorkspaceModel(
            launchPlanBuilder: SSHLaunchPlanBuilder(
                sshURL: URL(fileURLWithPath: "/usr/bin/ssh"),
                baseEnvironment: ["PATH": "/usr/bin:/bin"],
                currentDirectoryURL: URL(fileURLWithPath: "/tmp")
            ),
            workspaceStore: mockStore
        )
        
        XCTAssertNil(mockStore.savedWorkspace)
        
        // Open connection -> schedules a debounced save; flush to observe it
        XCTAssertTrue(model.openConnection(hostID: 1, alias: "prod", hasUnsavedChanges: false))
        model.flushPendingSave()
        XCTAssertNotNil(mockStore.savedWorkspace)
        XCTAssertEqual(mockStore.savedWorkspace?.sessions.count, 1)
        XCTAssertEqual(mockStore.savedWorkspace?.sessions[0].alias, "prod")

        // Split active pane -> schedules a debounced save
        let sessionID = try! XCTUnwrap(model.selectedSessionID)
        XCTAssertTrue(model.splitActivePane(in: sessionID, axis: .vertical))
        model.flushPendingSave()
        XCTAssertEqual(mockStore.savedWorkspace?.sessions[0].layout.panes.count, 2)

        // Select session changes -> schedules a debounced save
        model.selectedSessionID = nil
        model.flushPendingSave()
        XCTAssertNil(mockStore.savedWorkspace?.selectedSessionID)
    }
    
    @MainActor
    func testWorkspaceRestoration() {
        let mockStore = MockWorkspaceLayoutStore()
        
        let paneID = UUID()
        let sessionID = UUID()
        let groupID = UUID()
        let persistedSession = PersistedSession(
            id: sessionID,
            hostID: 5,
            alias: "stage",
            groupID: groupID,
            layout: .pane(PersistedPane(id: paneID, alias: "stage")),
            activePaneID: paneID,
            synchronizedPaneIDs: [paneID]
        )
        let savedWorkspace = PersistedWorkspace(
            sessions: [persistedSession],
            selectedSessionID: sessionID
        )
        mockStore.savedWorkspace = savedWorkspace
        
        let model = TerminalWorkspaceModel(
            launchPlanBuilder: SSHLaunchPlanBuilder(
                sshURL: URL(fileURLWithPath: "/usr/bin/ssh"),
                baseEnvironment: ["PATH": "/usr/bin:/bin"],
                currentDirectoryURL: URL(fileURLWithPath: "/tmp")
            ),
            workspaceStore: mockStore
        )
        
        XCTAssertTrue(model.sessions.isEmpty)
        
        model.restoreWorkspace(startupProfiles: [:])
        
        XCTAssertEqual(model.sessions.count, 1)
        XCTAssertEqual(model.selectedSessionID, sessionID)
        let restoredSession = model.sessions[0]
        XCTAssertEqual(restoredSession.alias, "stage")
        XCTAssertEqual(restoredSession.hostID, 5)
        XCTAssertEqual(restoredSession.groupID, groupID)
        XCTAssertEqual(restoredSession.activePaneID, paneID)
        XCTAssertEqual(restoredSession.synchronizedPaneIDs, [paneID])
        XCTAssertEqual(restoredSession.panes.count, 1)
        XCTAssertEqual(restoredSession.panes[0].id, paneID)
        XCTAssertEqual(restoredSession.panes[0].alias, "stage")
    }

    @MainActor
    func testWorkspaceRestorationFiltersInvalidAliases() {
        let mockStore = MockWorkspaceLayoutStore()
        
        let paneID1 = UUID()
        let sessionID1 = UUID()
        let persistedSession1 = PersistedSession(
            id: sessionID1,
            hostID: 5,
            alias: "stage",
            groupID: nil,
            layout: .pane(PersistedPane(id: paneID1, alias: "stage")),
            activePaneID: paneID1,
            synchronizedPaneIDs: [paneID1]
        )
        
        let paneID2 = UUID()
        let sessionID2 = UUID()
        let persistedSession2 = PersistedSession(
            id: sessionID2,
            hostID: 6,
            alias: "invalid-host",
            groupID: nil,
            layout: .pane(PersistedPane(id: paneID2, alias: "invalid-host")),
            activePaneID: paneID2,
            synchronizedPaneIDs: [paneID2]
        )
        
        let paneID3 = UUID()
        let sessionID3 = UUID()
        let persistedSession3 = PersistedSession(
            id: sessionID3,
            hostID: -1,
            alias: "Yerel Terminal",
            groupID: nil,
            layout: .pane(PersistedPane(id: paneID3, alias: "Yerel Terminal")),
            activePaneID: paneID3,
            synchronizedPaneIDs: [paneID3]
        )

        let savedWorkspace = PersistedWorkspace(
            sessions: [persistedSession1, persistedSession2, persistedSession3],
            selectedSessionID: sessionID1
        )
        mockStore.savedWorkspace = savedWorkspace
        
        let model = TerminalWorkspaceModel(
            launchPlanBuilder: SSHLaunchPlanBuilder(
                sshURL: URL(fileURLWithPath: "/usr/bin/ssh"),
                baseEnvironment: ["PATH": "/usr/bin:/bin"],
                currentDirectoryURL: URL(fileURLWithPath: "/tmp")
            ),
            workspaceStore: mockStore
        )
        
        XCTAssertTrue(model.sessions.isEmpty)
        
        model.restoreWorkspace(startupProfiles: [:], validAliases: ["stage"])
        
        XCTAssertEqual(model.sessions.count, 2)
        XCTAssertEqual(model.sessions.map(\.alias).sorted(), ["Yerel Terminal", "stage"].sorted())
    }

    @MainActor
    func testWorkspaceRestorationPreservesSkippedAutomaticStartup() {
        let mockStore = MockWorkspaceLayoutStore()
        let initialModel = TerminalWorkspaceModel(
            launchPlanBuilder: makeLaunchPlanBuilder(),
            workspaceStore: mockStore
        )
        let profile = StartupFlowProfile(
            alias: "stage",
            automaticallyRun: true,
            steps: [.runCommand("uptime")]
        )

        XCTAssertTrue(initialModel.openConnection(
            hostID: 5,
            alias: "stage",
            hasUnsavedChanges: false,
            startupProfile: profile,
            skipStartup: true
        ))
        initialModel.flushPendingSave()
        XCTAssertTrue(mockStore.savedWorkspace?.sessions[0].layout.panes[0].skippedAutomaticStartup == true)

        let restoredModel = TerminalWorkspaceModel(
            launchPlanBuilder: makeLaunchPlanBuilder(),
            workspaceStore: mockStore
        )
        restoredModel.restoreWorkspace(startupProfiles: ["stage": profile])

        XCTAssertEqual(restoredModel.selectedSession?.activePane?.startupState, .skipped)
        XCTAssertEqual(restoredModel.selectedSession?.activePane?.process.arguments, ["--", "stage"])
    }
    
    @MainActor
    func testReconnectPane() {
        let mockStore = MockWorkspaceLayoutStore()
        let model = TerminalWorkspaceModel(
            launchPlanBuilder: SSHLaunchPlanBuilder(
                sshURL: URL(fileURLWithPath: "/usr/bin/ssh"),
                baseEnvironment: ["PATH": "/usr/bin:/bin"],
                currentDirectoryURL: URL(fileURLWithPath: "/tmp")
            ),
            workspaceStore: mockStore
        )
        
        XCTAssertTrue(model.openConnection(hostID: 1, alias: "prod", hasUnsavedChanges: false))
        let sessionID = try! XCTUnwrap(model.selectedSessionID)
        let paneID = try! XCTUnwrap(model.selectedSession?.activePaneID)
        
        model.processDidExit(sessionID: sessionID, paneID: paneID, exitCode: 1)
        XCTAssertEqual(model.selectedSession?.activePane?.status, .exited(1))
        
        // Reconnect
        XCTAssertTrue(model.reconnectPane(paneID, in: sessionID, startupProfile: nil))
        XCTAssertEqual(model.selectedSession?.activePane?.status, .running)
        let newPaneID = try! XCTUnwrap(model.selectedSession?.activePaneID)
        XCTAssertNotEqual(newPaneID, paneID) // ID must change to force SwiftUI update
    }
}

private func makeLaunchPlanBuilder() -> SSHLaunchPlanBuilder {
    SSHLaunchPlanBuilder(
        sshURL: URL(fileURLWithPath: "/usr/bin/ssh"),
        baseEnvironment: ["PATH": "/usr/bin:/bin"],
        currentDirectoryURL: URL(fileURLWithPath: "/tmp")
    )
}

private extension PersistedPaneLayout {
    var panes: [PersistedPane] {
        switch self {
        case let .pane(pane):
            return [pane]
        case let .split(_, _, _, first, second):
            return first.panes + second.panes
        }
    }
}
