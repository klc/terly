import Foundation
import XCTest
@testable import SSHConfigurator

final class SFTPBatchPathQuotingTests: XCTestCase {
    func testQuotesPlainPathInDoubleQuotes() throws {
        XCTAssertEqual(try SFTPBatchPathQuoting.quote("/home/deploy/report.txt"), "\"/home/deploy/report.txt\"")
    }

    func testPreservesEmbeddedSpaces() throws {
        XCTAssertEqual(try SFTPBatchPathQuoting.quote("/home/deploy/report final.pdf"), "\"/home/deploy/report final.pdf\"")
    }

    func testEscapesDoubleQuotes() throws {
        XCTAssertEqual(try SFTPBatchPathQuoting.quote("/tmp/say \"hi\".txt"), "\"/tmp/say \\\"hi\\\".txt\"")
    }

    func testEscapesBackslashes() throws {
        XCTAssertEqual(try SFTPBatchPathQuoting.quote(#"/tmp/back\slash"#), "\"/tmp/back\\\\slash\"")
    }

    func testEscapesBackslashBeforeDoubleQuoteInTheCorrectOrder() throws {
        // If the backslash escape ran second, "\"" would double-escape into "\\\"" wrongly.
        // Verify the round trip: one literal backslash immediately followed by one literal quote.
        let quoted = try SFTPBatchPathQuoting.quote(#"/tmp/\"#)
        XCTAssertEqual(quoted, "\"/tmp/\\\\\"")
    }

    func testSingleQuotesPassThroughUnescaped() throws {
        // sftp's batch tokenizer only treats double quotes specially for our chosen
        // quoting style; a single quote inside a double-quoted token is a literal character.
        XCTAssertEqual(try SFTPBatchPathQuoting.quote("/tmp/O'Brien's file"), "\"/tmp/O'Brien's file\"")
    }

    func testUnicodePassesThroughUnescaped() throws {
        XCTAssertEqual(try SFTPBatchPathQuoting.quote("/home/deploy/İşler/résumé_😀.txt"), "\"/home/deploy/İşler/résumé_😀.txt\"")
    }

    func testRejectsEmbeddedNewline() {
        XCTAssertThrowsError(try SFTPBatchPathQuoting.quote("/tmp/foo\nbar")) { error in
            XCTAssertEqual(error as? SFTPBatchPathQuoting.EmbeddedNewlineError, SFTPBatchPathQuoting.EmbeddedNewlineError())
        }
    }

    func testRejectsEmbeddedCarriageReturn() {
        XCTAssertThrowsError(try SFTPBatchPathQuoting.quote("/tmp/foo\rbar"))
    }
}

final class RemoteFileNameValidatorTests: XCTestCase {
    func testRejectsEmptyOrWhitespaceOnlyName() {
        XCTAssertFalse(RemoteFileNameValidator.isValid(""))
        XCTAssertFalse(RemoteFileNameValidator.isValid("   "))
    }

    func testRejectsNameContainingSlash() {
        XCTAssertFalse(RemoteFileNameValidator.isValid("sub/dir"))
    }

    func testRejectsDotAndDotDot() {
        XCTAssertFalse(RemoteFileNameValidator.isValid("."))
        XCTAssertFalse(RemoteFileNameValidator.isValid(".."))
    }

    func testAcceptsOrdinaryNamesIncludingSpacesAndUnicode() {
        XCTAssertTrue(RemoteFileNameValidator.isValid("releases"))
        XCTAssertTrue(RemoteFileNameValidator.isValid("report final.pdf"))
        XCTAssertTrue(RemoteFileNameValidator.isValid("İşler_😀"))
        XCTAssertTrue(RemoteFileNameValidator.isValid(".hidden"))
    }
}

final class SFTPDirectoryListingServiceTests: XCTestCase {
    func testCreateDirectorySendsMkdirWithQuotedPath() async throws {
        let executor = FakeSFTPProcessExecutor { _ in
            SSHProcessResult(terminationStatus: 0, standardOutput: "", standardError: "", duration: 0.001)
        }
        let service = SFTPDirectoryListingService(processClient: executor)

        try await service.createDirectory(alias: "prod-api", path: "/home/deploy/new folder")

        XCTAssertEqual(executor.lastBatch, "mkdir \"/home/deploy/new folder\"\n")
    }

    func testRenameSendsRenameWithBothQuotedPaths() async throws {
        let executor = FakeSFTPProcessExecutor { _ in
            SSHProcessResult(terminationStatus: 0, standardOutput: "", standardError: "", duration: 0.001)
        }
        let service = SFTPDirectoryListingService(processClient: executor)

        try await service.rename(alias: "prod-api", from: "/home/deploy/old name.txt", to: "/home/deploy/new name.txt")

        XCTAssertEqual(executor.lastBatch, "rename \"/home/deploy/old name.txt\" \"/home/deploy/new name.txt\"\n")
    }

    func testDeleteFileSendsRm() async throws {
        let executor = FakeSFTPProcessExecutor { _ in
            SSHProcessResult(terminationStatus: 0, standardOutput: "", standardError: "", duration: 0.001)
        }
        let service = SFTPDirectoryListingService(processClient: executor)

        try await service.delete(alias: "prod-api", path: "/home/deploy/report.txt", kind: .file)

        XCTAssertEqual(executor.lastBatch, "rm \"/home/deploy/report.txt\"\n")
    }

    func testDeleteSymbolicLinkAlsoSendsRmNotRmdir() async throws {
        let executor = FakeSFTPProcessExecutor { _ in
            SSHProcessResult(terminationStatus: 0, standardOutput: "", standardError: "", duration: 0.001)
        }
        let service = SFTPDirectoryListingService(processClient: executor)

        try await service.delete(alias: "prod-api", path: "/home/deploy/current.log", kind: .symbolicLink)

        XCTAssertEqual(executor.lastBatch, "rm \"/home/deploy/current.log\"\n")
    }

    func testDeleteEmptyDirectorySendsRmdir() async throws {
        let executor = FakeSFTPProcessExecutor { _ in
            SSHProcessResult(terminationStatus: 0, standardOutput: "", standardError: "", duration: 0.001)
        }
        let service = SFTPDirectoryListingService(processClient: executor)

        try await service.delete(alias: "prod-api", path: "/home/deploy/empty-dir", kind: .directory)

        XCTAssertEqual(executor.lastBatch, "rmdir \"/home/deploy/empty-dir\"\n")
    }

    func testDeleteNonEmptyDirectorySurfacesDirectoryNotEmptyMessage() async {
        // OpenSSH's sftp-server maps ENOTEMPTY to the same generic SSH2_FX_FAILURE as
        // any other unmapped errno, which the sftp CLI renders as the bare word
        // "Failure" — the service must turn that into an honest, specific message
        // using the fact that it knows an rmdir was attempted.
        let executor = FakeSFTPProcessExecutor { _ in
            SSHProcessResult(
                terminationStatus: 1,
                standardOutput: "",
                standardError: "remote rmdir \"/home/deploy/uploads\": Failure",
                duration: 0.001
            )
        }
        let service = SFTPDirectoryListingService(processClient: executor)

        do {
            try await service.delete(alias: "prod-api", path: "/home/deploy/uploads", kind: .directory)
            XCTFail("Expected delete to throw")
        } catch let RemoteFileBrowserError.processFailed(message) {
            XCTAssertTrue(message.contains("boş değil"), message)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRenameToExistingDestinationSurfacesAlreadyExistsMessage() async {
        let executor = FakeSFTPProcessExecutor { _ in
            SSHProcessResult(
                terminationStatus: 1,
                standardOutput: "",
                standardError: "remote rename \"/home/deploy/a\" to \"/home/deploy/b\": Failure",
                duration: 0.001
            )
        }
        let service = SFTPDirectoryListingService(processClient: executor)

        do {
            try await service.rename(alias: "prod-api", from: "/home/deploy/a", to: "/home/deploy/b")
            XCTFail("Expected rename to throw")
        } catch let RemoteFileBrowserError.processFailed(message) {
            XCTAssertTrue(message.contains("zaten kullanılıyor"), message)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMissingSourceSurfacesNotFoundMessage() async {
        let executor = FakeSFTPProcessExecutor { _ in
            SSHProcessResult(
                terminationStatus: 1,
                standardOutput: "",
                standardError: "remote rmdir \"/home/deploy/gone\": No such file",
                duration: 0.001
            )
        }
        let service = SFTPDirectoryListingService(processClient: executor)

        do {
            try await service.delete(alias: "prod-api", path: "/home/deploy/gone", kind: .directory)
            XCTFail("Expected delete to throw")
        } catch let RemoteFileBrowserError.processFailed(message) {
            XCTAssertTrue(message.contains("bulunamadı"), message)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRenameRejectsInvalidAlias() async {
        let executor = FakeSFTPProcessExecutor { _ in
            SSHProcessResult(terminationStatus: 0, standardOutput: "", standardError: "", duration: 0.001)
        }
        let service = SFTPDirectoryListingService(processClient: executor)

        do {
            try await service.rename(alias: "*", from: "/a", to: "/b")
            XCTFail("Expected invalidAlias")
        } catch {
            XCTAssertEqual(error as? RemoteFileBrowserError, .invalidAlias)
        }
        XCTAssertTrue(executor.requests.isEmpty)
    }

    func testDeleteRejectsEmptyPath() async {
        let executor = FakeSFTPProcessExecutor { _ in
            SSHProcessResult(terminationStatus: 0, standardOutput: "", standardError: "", duration: 0.001)
        }
        let service = SFTPDirectoryListingService(processClient: executor)

        do {
            try await service.delete(alias: "prod-api", path: "   ", kind: .file)
            XCTFail("Expected invalidPath")
        } catch {
            XCTAssertEqual(error as? RemoteFileBrowserError, .invalidPath)
        }
        XCTAssertTrue(executor.requests.isEmpty)
    }
}

// MARK: - Fake

private final class FakeSFTPProcessExecutor: SSHProcessExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [SSHProcessRequest] = []
    private let responder: @Sendable (SSHProcessRequest) -> SSHProcessResult

    var requests: [SSHProcessRequest] { lock.withLock { storedRequests } }
    var lastBatch: String? {
        guard let data = requests.last?.standardInput else { return nil }
        return String(data: data, encoding: .utf8)
    }

    init(responder: @escaping @Sendable (SSHProcessRequest) -> SSHProcessResult) {
        self.responder = responder
    }

    func start(
        _ request: SSHProcessRequest,
        onOutput: @escaping @Sendable (SSHProcessStream, Data) -> Void,
        completion: @escaping @Sendable (Result<SSHProcessResult, SSHProcessClientError>) -> Void
    ) throws -> any SSHProcessTask {
        lock.withLock { storedRequests.append(request) }
        completion(.success(responder(request)))
        return FakeSFTPProcessTask()
    }
}

private final class FakeSFTPProcessTask: SSHProcessTask, @unchecked Sendable {
    func cancel() {}
}
