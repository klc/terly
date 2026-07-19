import Foundation
import XCTest
@testable import SSHConfigurator

final class UploadPreflightTests: XCTestCase {
    func testReportsOnlyDestinationsThatAlreadyExistRemotely() async throws {
        let listing = StubRemoteDirectoryListing(snapshot: RemoteDirectorySnapshot(
            path: "/srv/uploads",
            entries: [
                remoteEntry(name: "existing.txt"),
                remoteEntry(name: "unrelated.txt")
            ]
        ))
        let preflight = UploadPreflight(listingService: listing)
        let items = [
            uploadItem(localName: "existing.txt", remotePath: "/srv/uploads/existing.txt"),
            uploadItem(localName: "new.txt", remotePath: "/srv/uploads/new.txt")
        ]

        let result = try await preflight.inspect(
            alias: "prod",
            remoteDirectory: "/srv/uploads",
            items: items
        )

        XCTAssertEqual(result.existingRemoteNames, ["existing.txt"])
        XCTAssertTrue(result.requiresOverwriteConfirmation)
        XCTAssertEqual(listing.requestedAlias, "prod")
        XCTAssertEqual(listing.requestedPath, "/srv/uploads")
    }

    func testDuplicateDestinationNamesAreDetectedBeforeRemoteListing() {
        let items = [
            uploadItem(localName: "first/report.txt", remotePath: "/srv/uploads/report.txt"),
            uploadItem(localName: "second/report.txt", remotePath: "/srv/uploads/report.txt"),
            uploadItem(localName: "unique.txt", remotePath: "/srv/uploads/unique.txt")
        ]

        XCTAssertEqual(UploadPreflight.duplicateDestinationNames(in: items), ["report.txt"])
    }

    private func uploadItem(localName: String, remotePath: String) -> TransferItem {
        TransferItem(
            direction: .upload,
            alias: "prod",
            localURL: URL(fileURLWithPath: "/tmp").appendingPathComponent(localName),
            remotePath: remotePath,
            isDirectory: false,
            transferProtocol: .scp
        )
    }

    private func remoteEntry(name: String) -> RemoteFileEntry {
        RemoteFileEntry(
            name: name,
            path: "/srv/uploads/\(name)",
            kind: .file,
            size: nil,
            modificationDescription: ""
        )
    }
}

private final class StubRemoteDirectoryListing: RemoteDirectoryListing, @unchecked Sendable {
    private let snapshot: RemoteDirectorySnapshot
    private(set) var requestedAlias: String?
    private(set) var requestedPath: String?

    init(snapshot: RemoteDirectorySnapshot) {
        self.snapshot = snapshot
    }

    func listDirectory(alias: String, path: String) async throws -> RemoteDirectorySnapshot {
        requestedAlias = alias
        requestedPath = path
        return snapshot
    }
}
