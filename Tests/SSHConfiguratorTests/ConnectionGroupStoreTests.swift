import Foundation
import XCTest
@testable import SSHConfigurator

final class ConnectionGroupStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testMissingStoreLoadsAsAnEmptyCollection() throws {
        let store = ConnectionGroupStore(fileURL: root.appendingPathComponent("groups.json"))

        XCTAssertEqual(try store.load(), [])
    }

    func testSavesAndLoadsConnectionGroups() throws {
        let store = ConnectionGroupStore(fileURL: root.appendingPathComponent("groups.json"))
        let groups = [
            try SSHConnectionGroup.validated(
                id: UUID(uuidString: "4A102E53-51F0-4C12-B09C-8DF1EC2A7DB9")!,
                name: "Prod Servers",
                aliases: ["prod-api", "prod-worker", "prod-db"],
                openMode: .splitPanes
            ),
        ]

        try store.save(groups)

        XCTAssertEqual(try store.load(), groups)
    }

    func testLegacyGroupWithoutOpenModeDefaultsToSeparateTabs() throws {
        let storeURL = root.appendingPathComponent("groups.json")
        let store = ConnectionGroupStore(fileURL: storeURL)
        let legacyJSON = """
        [
          {
            "id": "4A102E53-51F0-4C12-B09C-8DF1EC2A7DB9",
            "name": "Prod Servers",
            "aliases": ["prod-api", "prod-db"]
          }
        ]
        """
        try Data(legacyJSON.utf8).write(to: storeURL)

        let group = try XCTUnwrap(store.load().first)

        XCTAssertEqual(group.openMode, .separateTabs)
    }

    func testValidationTrimsAndDeduplicatesAliases() throws {
        let group = try SSHConnectionGroup.validated(
            name: "  Prod Servers  ",
            aliases: [" prod-api ", "prod-api", "*.example.com", "prod-db"]
        )

        XCTAssertEqual(group.name, "Prod Servers")
        XCTAssertEqual(group.aliases, ["prod-api", "prod-db"])
        XCTAssertEqual(group.openMode, .separateTabs)
    }

    func testValidationRequiresANameAndAtLeastOneConnection() {
        XCTAssertThrowsError(
            try SSHConnectionGroup.validated(name: "   ", aliases: ["prod-api"])
        ) { error in
            XCTAssertEqual(error as? SSHConnectionGroupError, .emptyName)
        }

        XCTAssertThrowsError(
            try SSHConnectionGroup.validated(name: "Prod Servers", aliases: ["*.example.com"])
        ) { error in
            XCTAssertEqual(error as? SSHConnectionGroupError, .emptyConnections)
        }
    }

    func testSavesAndLoadsConnectionGroupWithStartupProfileAndOverrideSetting() throws {
        let store = ConnectionGroupStore(fileURL: root.appendingPathComponent("groups.json"))
        let startupProfile = StartupFlowProfile(
            alias: "Prod Servers",
            automaticallyRun: true,
            steps: [.changeDirectory("/var/log"), .runCommand("ls -la")]
        )
        let groups = [
            try SSHConnectionGroup.validated(
                id: UUID(uuidString: "4A102E53-51F0-4C12-B09C-8DF1EC2A7DB9")!,
                name: "Prod Servers",
                aliases: ["prod-api", "prod-worker"],
                openMode: .splitPanes,
                startupProfile: startupProfile,
                overrideHostStartupFlows: false
            ),
        ]

        try store.save(groups)
        let loaded = try store.load()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.startupProfile, startupProfile)
        XCTAssertEqual(loaded.first?.overrideHostStartupFlows, false)
    }

    func testLegacyGroupWithoutStartupProfileDefaultsToNilProfileAndTrueOverride() throws {
        let storeURL = root.appendingPathComponent("groups.json")
        let store = ConnectionGroupStore(fileURL: storeURL)
        let legacyJSON = """
        [
          {
            "id": "4A102E53-51F0-4C12-B09C-8DF1EC2A7DB9",
            "name": "Legacy Group",
            "aliases": ["legacy-host"]
          }
        ]
        """
        try Data(legacyJSON.utf8).write(to: storeURL)

        let group = try XCTUnwrap(store.load().first)

        XCTAssertNil(group.startupProfile)
        XCTAssertTrue(group.overrideHostStartupFlows)
    }
}
