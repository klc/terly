import XCTest
@testable import SSHConfigurator

final class SFTPDirectoryListingParserTests: XCTestCase {
    func testParsesRemoteDirectoryAndSortsFoldersBeforeFiles() throws {
        let output = """
        Remote working directory: /home/deploy/uploads
        -rw-r--r--    ? 1000 1000 2488320 Jul 15 19:42 ./report final.pdf
        drwxr-xr-x    ? 1000 1000    4096 Jul 15 20:00 ./releases
        lrwxrwxrwx    ? 1000 1000      12 Jul 14 08:15 ./current.log -> logs/app.log
        drwxr-xr-x    ? 1000 1000    4096 Jul 13 12:00 ./.
        drwxr-xr-x    ? 1000 1000    4096 Jul 13 12:00 ./..
        """

        let snapshot = try SFTPDirectoryListingParser().parse(output: output, requestedPath: ".")

        XCTAssertEqual(snapshot.path, "/home/deploy/uploads")
        XCTAssertEqual(snapshot.entries.map(\.name), ["releases", "current.log", "report final.pdf"])
        XCTAssertEqual(snapshot.entries.map(\.kind), [.directory, .symbolicLink, .file])
        XCTAssertEqual(snapshot.entries.last?.size, 2_488_320)
        XCTAssertEqual(snapshot.entries.last?.path, "/home/deploy/uploads/report final.pdf")
    }

    func testRemotePathJoinsAndFindsParentWithoutDroppingLeadingSlash() {
        XCTAssertEqual(RemotePath.appending("report.pdf", to: "/home/deploy"), "/home/deploy/report.pdf")
        XCTAssertEqual(RemotePath.appending("report.pdf", to: "/"), "/report.pdf")
        XCTAssertEqual(RemotePath.parent(of: "/home/deploy/report.pdf"), "/home/deploy")
        XCTAssertEqual(RemotePath.parent(of: "/"), "/")
    }

    func testRejectsListingWithoutAnAbsoluteWorkingDirectory() {
        XCTAssertThrowsError(
            try SFTPDirectoryListingParser().parse(output: "-rw-r--r-- 1 1 1 5 Jul 15 12:00 file.txt", requestedPath: ".")
        ) { error in
            XCTAssertEqual(error as? RemoteFileBrowserError, .unreadableListing)
        }
    }
}
