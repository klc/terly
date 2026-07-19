import Foundation

struct UploadPreflightResult: Equatable, Sendable {
    let existingRemoteNames: [String]

    var requiresOverwriteConfirmation: Bool {
        !existingRemoteNames.isEmpty
    }
}

/// Performs the safety checks shared by the transfer form and terminal file-drop
/// upload path. The remote listing is deliberately fail-closed: callers should
/// surface the error instead of silently overwriting an unknown destination.
struct UploadPreflight: Sendable {
    private let listingService: any RemoteDirectoryListing

    init(listingService: any RemoteDirectoryListing = SFTPDirectoryListingService()) {
        self.listingService = listingService
    }

    func inspect(
        alias: String,
        remoteDirectory: String,
        items: [TransferItem]
    ) async throws -> UploadPreflightResult {
        let snapshot = try await listingService.listDirectory(alias: alias, path: remoteDirectory)
        let destinationNames = Set(items.map { Self.destinationName(for: $0) })
        let existingNames = snapshot.entries
            .map(\.name)
            .filter(destinationNames.contains)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return UploadPreflightResult(existingRemoteNames: existingNames)
    }

    static func duplicateDestinationNames(in items: [TransferItem]) -> [String] {
        let grouped = Dictionary(grouping: items, by: \.remotePath)
        return grouped
            .filter { $0.value.count > 1 }
            .map { destinationName(for: $0.value[0]) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func destinationName(for item: TransferItem) -> String {
        item.remotePath.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init)
            ?? item.localURL.lastPathComponent
    }
}
