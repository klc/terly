import XCTest
@testable import SSHConfigCore

final class SSHConfigDocumentTests: XCTestCase {
    func testKeepsOriginalSourceVerbatim() {
        let source = "# Personal hosts\r\nHost prod staging\r\n  HostName example.com\r\n  User deploy\r\n"

        let document = SSHConfigDocument(source: source)

        XCTAssertEqual(document.rendered, source)
    }

    func testFindsHostBlocksAndClosesAtMatch() {
        let source = """
        Host prod staging
          HostName example.com
        Host *.internal
          User ops
        Match host bastion
          User tunnel
        """

        let document = SSHConfigDocument(source: source)

        XCTAssertEqual(document.hostBlocks.count, 2)
        XCTAssertEqual(document.hostBlocks[0].patterns, ["prod", "staging"])
        XCTAssertEqual(document.hostBlocks[0].lineRange, 1...2)
        XCTAssertTrue(document.hostBlocks[1].isPattern)
        XCTAssertEqual(document.hostBlocks[1].lineRange, 3...4)
    }

    func testPreservesUnknownDirectivesAsDirectives() {
        let document = SSHConfigDocument(source: "Host demo\n  CustomFutureOption enabled\n")

        guard case let .directive(keyword, value) = document.lines[1].kind else {
            return XCTFail("Beklenen directive satırı ayrıştırılamadı")
        }

        XCTAssertEqual(keyword, "CustomFutureOption")
        XCTAssertEqual(value, "enabled")
    }

    func testUpdatesOnlyTheSelectedDirectiveAndKeepsComment() throws {
        let source = """
        Host prod
          HostName old.example.com # legacy endpoint
          User deploy
        """
        let document = SSHConfigDocument(source: source)
        let updated = try document.updatingDirective(
            named: "HostName",
            to: "new.example.com",
            in: try XCTUnwrap(document.hostBlocks.first)
        )

        XCTAssertEqual(
            updated.source,
            "Host prod\n  HostName new.example.com # legacy endpoint\n  User deploy"
        )
    }

    func testAddsDirectiveAndCanDeleteHostBlock() throws {
        let document = SSHConfigDocument(source: "Host demo\n  User ops\n")
        let host = try XCTUnwrap(document.hostBlocks.first)
        let withPort = try document.updatingDirective(named: "Port", to: "2222", in: host)

        XCTAssertEqual(withPort.directiveValue(named: "Port", in: try XCTUnwrap(withPort.hostBlocks.first)), "2222")

        let deleted = try withPort.deletingHostBlock(try XCTUnwrap(withPort.hostBlocks.first))
        XCTAssertEqual(deleted.source, "")
    }

    func testDuplicatesHostBlockWithNewPatternsAndPreservesItsContents() throws {
        let document = SSHConfigDocument(source: "Host prod # primary\n  HostName prod.example.com # endpoint\n  User deploy\n")

        let duplicated = try document.duplicatingHostBlock(
            try XCTUnwrap(document.hostBlocks.first),
            with: ["prod-copy"]
        )

        XCTAssertEqual(
            duplicated.source,
            "Host prod # primary\n  HostName prod.example.com # endpoint\n  User deploy\n\nHost prod-copy # primary\n  HostName prod.example.com # endpoint\n  User deploy\n"
        )
    }

    func testRecognizesMatchExecBeforeExternalValidation() {
        let document = SSHConfigDocument(source: "Match exec \"/usr/bin/true\"\n  User safe\n")

        XCTAssertTrue(document.containsMatchExec)
    }

    func testOpenSSHValidationUsesTemporaryConfigWithoutNetworkAccess() {
        let document = SSHConfigDocument(source: "Host validation-fixture\n  HostName example.com\n  User tester\n")

        XCTAssertEqual(
            SSHConfigValidator().validate(document, forHost: "validation-fixture"),
            .valid
        )
    }

    func testOpenSSHValidationRequiresConfirmationForMatchExec() {
        let document = SSHConfigDocument(source: "Match exec \"/usr/bin/true\"\n  User tester\n")

        XCTAssertEqual(
            SSHConfigValidator().validate(document, forHost: "validation-fixture"),
            .requiresMatchExecConfirmation
        )
    }

    func testFindsGlobalMatchAndIncludeSections() {
        let document = SSHConfigDocument(source: """
        Include ~/.ssh/conf.d/*
        Compression yes
        Host app
          Include ~/.ssh/app.conf
        Match host bastion
          Include ~/.ssh/bastion.conf
        """)

        XCTAssertEqual(document.globalDirectives.map(\.keyword), ["Include", "Compression"])
        XCTAssertEqual(document.matchBlocks.count, 1)
        XCTAssertEqual(document.matchBlocks.first?.conditions, "host bastion")
        XCTAssertEqual(document.includes.map(\.value), ["~/.ssh/conf.d/*", "~/.ssh/app.conf", "~/.ssh/bastion.conf"])
        XCTAssertEqual(document.includes.map(\.scope), [.global, .host, .match])
    }

    func testReplacesGlobalAndMatchSourceWithoutTouchingOtherSections() throws {
        let document = SSHConfigDocument(source: """
        Compression yes
        Host app
          User deploy
        Match host bastion
          User tunnel
        """)

        let withGlobalChange = document.replacingGlobalSource(with: "HashKnownHosts yes")
        let match = try XCTUnwrap(withGlobalChange.matchBlocks.first)
        let updated = withGlobalChange.replacingSource(in: match.lineRange, with: "Match host bastion\n  User new-tunnel")

        XCTAssertEqual(
            updated.source,
            "HashKnownHosts yes\nHost app\n  User deploy\nMatch host bastion\n  User new-tunnel"
        )
    }

    func testIncludeEditorValueExcludesAndPreservesInlineComment() {
        let document = SSHConfigDocument(source: "Include ~/.ssh/conf.d/* # managed fragments\n")
        let include = document.includes[0]

        let updated = document.updatingDirective(atLine: include.line, to: include.value)

        XCTAssertEqual(include.value, "~/.ssh/conf.d/*")
        XCTAssertEqual(updated.source, "Include ~/.ssh/conf.d/* # managed fragments\n")
    }

    func testGroupsHostsByFirstHyphenSeparatedAliasSegment() {
        let document = SSHConfigDocument(source: """
        Host nfs-dev
        Host nfs-staging
        Host ams-master
        Host ams-api1
        Host ams-api2
        Host dev
        Host chefm_api
        """)

        XCTAssertEqual(document.hostGroups.map(\.label), ["nfs", "ams", nil])
        XCTAssertEqual(document.hostGroups[0].hosts.map(\.displayName), ["nfs-dev", "nfs-staging"])
        XCTAssertEqual(document.hostGroups[1].hosts.map(\.displayName), ["ams-master", "ams-api1", "ams-api2"])
        XCTAssertEqual(document.hostGroups[2].hosts.map(\.displayName), ["dev", "chefm_api"])
    }

    func testGroupsHostsAcrossMultipleHyphenLevels() {
        let document = SSHConfigDocument(source: """
        Host ams-api-prod-1
        Host ams-api-prod-2
        Host ams-api-staging-1
        Host ams-cache-redis-1
        """)

        let ams = document.hostGroups[0]
        let api = ams.children[0]
        let prod = api.children[0]
        let cache = ams.children[1]

        XCTAssertEqual(ams.label, "ams")
        XCTAssertEqual(api.label, "api")
        XCTAssertEqual(prod.label, "prod")
        XCTAssertEqual(prod.hosts.map(\.displayName), ["ams-api-prod-1", "ams-api-prod-2"])
        XCTAssertEqual(api.children[1].label, "staging")
        XCTAssertEqual(cache.label, "cache")
        XCTAssertEqual(cache.children[0].label, "redis")
    }
}
