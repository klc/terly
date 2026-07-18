import Foundation
import XCTest
@testable import SSHConfigurator

final class SCPTransferPlanBuilderTests: XCTestCase {
    func testBuildsUploadCommandWithSSHConfigAlias() throws {
        let sourceURL = try makeTemporaryFile(named: "report.txt")
        defer { try? FileManager.default.removeItem(at: sourceURL.deletingLastPathComponent()) }

        let builder = SCPTransferPlanBuilder(
            scpURL: URL(fileURLWithPath: "/usr/bin/scp"),
            baseEnvironment: ["PATH": "/usr/bin:/bin"],
            currentDirectoryURL: URL(fileURLWithPath: "/tmp")
        )

        let plan = try builder.makePlan(for: SCPTransferRequest(
            direction: .upload,
            alias: "  prod-api ",
            localURL: sourceURL,
            remotePath: " /var/tmp/report.txt "
        ))

        XCTAssertEqual(plan.process.executableURL.path, "/usr/bin/scp")
        XCTAssertEqual(plan.process.arguments, [
            "--",
            sourceURL.path,
            "prod-api:/var/tmp/report.txt",
        ])
        XCTAssertEqual(plan.process.currentDirectoryURL?.path, "/tmp")
    }

    func testNeverPassesBatchModeFlag() throws {
        let sourceURL = try makeTemporaryFile(named: "report.txt")
        defer { try? FileManager.default.removeItem(at: sourceURL.deletingLastPathComponent()) }

        let builder = SCPTransferPlanBuilder(baseEnvironment: ["PATH": "/usr/bin:/bin"])

        let plan = try builder.makePlan(for: SCPTransferRequest(
            direction: .upload,
            alias: "prod-api",
            localURL: sourceURL,
            remotePath: "/var/tmp/report.txt"
        ))

        // No "-B" anywhere in the argument list — scp must be allowed to
        // prompt (via SSH_ASKPASS) instead of failing closed when no agent
        // identity is available. See SSHProcessClientTests for coverage of
        // the SSH_ASKPASS/SSH_ASKPASS_REQUIRE/DISPLAY environment itself.
        XCTAssertFalse(plan.process.arguments.contains("-B"))
        XCTAssertFalse(plan.process.arguments.contains(where: { $0.contains("BatchMode") }))
    }

    func testBuildsDownloadCommandToSelectedLocalPath() throws {
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("scp-download-\(UUID().uuidString).txt")
        let builder = SCPTransferPlanBuilder(baseEnvironment: ["PATH": "/usr/bin:/bin"])

        let plan = try builder.makePlan(for: SCPTransferRequest(
            direction: .download,
            alias: "prod-api",
            localURL: destinationURL,
            remotePath: "/srv/reports/today.txt"
        ))

        XCTAssertEqual(plan.process.arguments, [
            "--",
            "prod-api:/srv/reports/today.txt",
            destinationURL.path,
        ])
    }

    func testRejectsUnsafeAliasAndRemotePath() throws {
        let sourceURL = try makeTemporaryFile(named: "report.txt")
        defer { try? FileManager.default.removeItem(at: sourceURL.deletingLastPathComponent()) }
        let builder = SCPTransferPlanBuilder()

        XCTAssertThrowsError(try builder.makePlan(for: SCPTransferRequest(
            direction: .upload,
            alias: "*.example.com",
            localURL: sourceURL,
            remotePath: "/var/tmp/report.txt"
        ))) { error in
            XCTAssertEqual(error as? SCPTransferError, .noConcreteAlias)
        }

        XCTAssertThrowsError(try builder.makePlan(for: SCPTransferRequest(
            direction: .upload,
            alias: "prod-api",
            localURL: sourceURL,
            remotePath: "/var/tmp/report\n.txt"
        ))) { error in
            XCTAssertEqual(error as? SCPTransferError, .invalidRemotePath)
        }
    }

    func testRejectsDirectoryAsUploadSourceWhenNotFlagged() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("scp-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        // isDirectory defaults to false → directory upload should still be rejected.
        XCTAssertThrowsError(try SCPTransferPlanBuilder().makePlan(for: SCPTransferRequest(
            direction: .upload,
            alias: "prod-api",
            localURL: directoryURL,
            remotePath: "/var/tmp/folder",
            isDirectory: false
        ))) { error in
            XCTAssertEqual(error as? SCPTransferError, .localFileIsDirectory)
        }
    }

    func testBuildsUploadCommandForDirectoryWithRecursiveFlag() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("scp-dir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let builder = SCPTransferPlanBuilder(baseEnvironment: ["PATH": "/usr/bin:/bin"])
        let plan = try builder.makePlan(for: SCPTransferRequest(
            direction: .upload,
            alias: "prod-api",
            localURL: directoryURL,
            remotePath: "/var/tmp/folder",
            isDirectory: true
        ))

        XCTAssertEqual(plan.process.arguments, [
            "-r",
            "--",
            directoryURL.standardizedFileURL.path,
            "prod-api:/var/tmp/folder",
        ])
    }

    private func makeTemporaryFile(named name: String) throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("scp-transfer-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let fileURL = directoryURL.appendingPathComponent(name)
        try Data("test".utf8).write(to: fileURL)
        return fileURL
    }
}
