import Foundation
import XCTest
@testable import SSHConfigurator

final class SyncSetResolverTests: XCTestCase {
    private var sshDir: URL!
    private var appSupportDir: URL!

    override func setUp() {
        super.setUp()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("terly-sync-resolver-\(UUID().uuidString)", isDirectory: true)
        sshDir = root.appendingPathComponent(".ssh", isDirectory: true)
        appSupportDir = root.appendingPathComponent("AppSupport", isDirectory: true)
        try? FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: sshDir.deletingLastPathComponent())
        super.tearDown()
    }

    private func makeResolver() -> SyncSetResolver {
        SyncSetResolver(sshDirectoryURL: sshDir, appSupportDirectoryURL: appSupportDir)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testResolvesTopLevelConfigAndKnownAppStores() throws {
        try write("Host a\n  HostName example.com\n", to: sshDir.appendingPathComponent("config"))
        try write("[]", to: appSupportDir.appendingPathComponent("tunnels.json"))
        try write("[]", to: appSupportDir.appendingPathComponent("snippets.json"))
        // Not in the sync set — must never be picked up.
        try write("secret", to: appSupportDir.appendingPathComponent("transfer-history.json"))

        let syncSet = makeResolver().resolve()
        let relativePaths = Set(syncSet.files.map(\.relativePath))

        XCTAssertTrue(relativePaths.contains("ssh/config"))
        XCTAssertTrue(relativePaths.contains("app/tunnels.json"))
        XCTAssertTrue(relativePaths.contains("app/snippets.json"))
        XCTAssertFalse(relativePaths.contains("app/transfer-history.json"))
    }

    func testExpandsGlobIncludeWithinSSHDirectory() throws {
        try write("Include conf.d/*.conf\n", to: sshDir.appendingPathComponent("config"))
        try write("Host work\n  HostName work.example.com\n", to: sshDir.appendingPathComponent("conf.d/work.conf"))
        try write("Host home\n  HostName home.example.com\n", to: sshDir.appendingPathComponent("conf.d/home.conf"))

        let syncSet = makeResolver().resolve()
        let relativePaths = Set(syncSet.files.map(\.relativePath))

        XCTAssertTrue(relativePaths.contains("ssh/conf.d/work.conf"))
        XCTAssertTrue(relativePaths.contains("ssh/conf.d/home.conf"))
        XCTAssertTrue(syncSet.warnings.isEmpty)
    }

    func testFollowsNestedIncludesTransitively() throws {
        try write("Include level1.conf\n", to: sshDir.appendingPathComponent("config"))
        try write("Include level2.conf\nHost l1\n  HostName l1.example.com\n", to: sshDir.appendingPathComponent("level1.conf"))
        try write("Host l2\n  HostName l2.example.com\n", to: sshDir.appendingPathComponent("level2.conf"))

        let syncSet = makeResolver().resolve()
        let relativePaths = Set(syncSet.files.map(\.relativePath))

        XCTAssertTrue(relativePaths.contains("ssh/level1.conf"))
        XCTAssertTrue(relativePaths.contains("ssh/level2.conf"))
    }

    func testSkipsIncludeThatEscapesSSHDirectoryAndWarns() throws {
        let outsideFile = sshDir.deletingLastPathComponent().appendingPathComponent("outside.conf")
        try write("Host outside\n  HostName evil.example.com\n", to: outsideFile)
        try write("Include ../outside.conf\nInclude /etc/hosts\n", to: sshDir.appendingPathComponent("config"))

        let syncSet = makeResolver().resolve()

        XCTAssertFalse(syncSet.files.contains { $0.sourceURL.standardizedFileURL == outsideFile.standardizedFileURL })
        XCTAssertFalse(syncSet.files.contains { $0.sourceURL.path == "/etc/hosts" })
        XCTAssertGreaterThanOrEqual(syncSet.warnings.count, 1)
        XCTAssertTrue(syncSet.warnings.contains { $0.message.contains("dışına çıkıyor") })
    }

    func testDoesNotHangOnCyclicIncludes() throws {
        try write("Include cycle-a.conf\n", to: sshDir.appendingPathComponent("config"))
        try write("Include cycle-b.conf\n", to: sshDir.appendingPathComponent("cycle-a.conf"))
        try write("Include cycle-a.conf\n", to: sshDir.appendingPathComponent("cycle-b.conf"))

        // `resolve()` is synchronous, pure computation; the `visited` guard
        // must make it terminate (not spin on the a↔b cycle) for this test
        // to complete at all.
        let syncSet = makeResolver().resolve()
        let relativePaths = Set(syncSet.files.map(\.relativePath))
        XCTAssertTrue(relativePaths.contains("ssh/cycle-a.conf"))
        XCTAssertTrue(relativePaths.contains("ssh/cycle-b.conf"))
    }

    func testDeeplyNestedIncludeChainIsBoundedAndWarns() throws {
        let depth = SyncSetResolver.maxIncludeDepth + 5
        try write("Include chain0.conf\n", to: sshDir.appendingPathComponent("config"))
        for index in 0 ..< depth {
            try write("Include chain\(index + 1).conf\n", to: sshDir.appendingPathComponent("chain\(index).conf"))
        }
        try write("Host leaf\n  HostName leaf.example.com\n", to: sshDir.appendingPathComponent("chain\(depth).conf"))

        let syncSet = makeResolver().resolve()
        let relativePaths = Set(syncSet.files.map(\.relativePath))

        XCTAssertFalse(relativePaths.contains("ssh/chain\(depth).conf"))
        XCTAssertTrue(syncSet.warnings.contains { $0.message.contains("Include zinciri") })
    }

    func testIgnoresNonExistentIncludeGlobSilently() throws {
        try write("Include conf.d/*.conf\n", to: sshDir.appendingPathComponent("config"))

        let syncSet = makeResolver().resolve()
        XCTAssertTrue(syncSet.warnings.isEmpty)
    }

    func testSkipsPrivateKeyAndKnownHostsEvenWhenIncludedByGlob() throws {
        // `Include *` is a contrived but legal ssh_config line — nothing
        // stops it from matching key material sitting next to `config`.
        // Exclusion here must be structural, not just "nobody writes that".
        try write("Include *\n", to: sshDir.appendingPathComponent("config"))
        try write("PRIVATE-KEY-BYTES-NEVER-SYNC", to: sshDir.appendingPathComponent("id_ed25519"))
        try write("ssh-ed25519 AAAA... comment", to: sshDir.appendingPathComponent("id_ed25519.pub"))
        try write("github.com ssh-ed25519 AAAA...", to: sshDir.appendingPathComponent("known_hosts"))
        try write("Host safe\n  HostName safe.example.com\n", to: sshDir.appendingPathComponent("conf.d.conf"))

        let syncSet = makeResolver().resolve()
        let relativePaths = Set(syncSet.files.map(\.relativePath))

        XCTAssertFalse(relativePaths.contains("ssh/id_ed25519"))
        XCTAssertFalse(relativePaths.contains("ssh/id_ed25519.pub"))
        XCTAssertFalse(relativePaths.contains("ssh/known_hosts"))
        XCTAssertTrue(relativePaths.contains("ssh/conf.d.conf"))
        XCTAssertTrue(syncSet.warnings.contains { $0.message.contains("özel anahtar") })
    }

    func testSplitIncludeValueHonorsQuotedWhitespace() {
        let patterns = SyncSetResolver.splitIncludeValue("\"conf d/one.conf\" conf.d/two.conf")
        XCTAssertEqual(patterns, ["conf d/one.conf", "conf.d/two.conf"])
    }
}
