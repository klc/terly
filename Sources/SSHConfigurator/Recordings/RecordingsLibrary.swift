import AppKit
import Combine
import Foundation

struct CastSummary: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let sizeBytes: Int64
    let duration: TimeInterval?

    var id: String { url.path }
}

struct RecordingSummary: Identifiable, Hashable, Sendable {
    let folderURL: URL
    let name: String
    let date: Date
    let totalSize: Int64
    let casts: [CastSummary]

    var id: String { folderURL.path }
    var paneCount: Int { casts.count }
    var duration: TimeInterval? { casts.compactMap(\.duration).max() }
}

@MainActor
final class RecordingsLibrary: ObservableObject {
    @Published private(set) var recordings: [RecordingSummary] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let settings: RecordingSettings
    private let fileManager: FileManager
    private let trashHandler: (URL) throws -> Void

    init(
        settings: RecordingSettings = .shared,
        fileManager: FileManager = .default,
        trashHandler: ((URL) throws -> Void)? = nil
    ) {
        self.settings = settings
        self.fileManager = fileManager
        self.trashHandler = trashHandler ?? { url in
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        }
    }

    var rootURL: URL { settings.resolvedRootURL(fileManager: fileManager) }

    nonisolated static func scan(root: URL, fileManager: FileManager = .default) -> [RecordingSummary] {
        guard let folders = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return folders.compactMap { folderURL in
            guard
                let folderValues = try? folderURL.resourceValues(forKeys: [.isDirectoryKey, .creationDateKey, .contentModificationDateKey]),
                folderValues.isDirectory == true,
                let files = try? fileManager.contentsOfDirectory(
                    at: folderURL,
                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]
                )
            else { return nil }

            let casts = files.compactMap { fileURL -> CastSummary? in
                guard fileURL.pathExtension.lowercased() == "cast" else { return nil }
                guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else {
                    return nil
                }
                return CastSummary(
                    url: fileURL,
                    name: fileURL.deletingPathExtension().lastPathComponent,
                    sizeBytes: Int64(values.fileSize ?? 0),
                    duration: AsciicastFile.quickDuration(url: fileURL)
                )
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

            guard !casts.isEmpty else { return nil }
            return RecordingSummary(
                folderURL: folderURL,
                name: folderURL.lastPathComponent,
                date: folderValues.creationDate ?? folderValues.contentModificationDate ?? .distantPast,
                totalSize: casts.reduce(0) { $0 + $1.sizeBytes },
                casts: casts
            )
        }.sorted { $0.date > $1.date }
    }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        let root = rootURL
        Task {
            let result = await Task.detached(priority: .utility) {
                Self.scan(root: root)
            }.value
            recordings = result
            isLoading = false
        }
    }

    func rename(_ recording: RecordingSummary, to proposedName: String) {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.contains(":") else {
            errorMessage = String(localized: "Enter a valid recording name without / or : characters.")
            return
        }
        let destination = recording.folderURL.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
        guard !fileManager.fileExists(atPath: destination.path) else {
            errorMessage = String(localized: "A recording with that name already exists.")
            return
        }
        do {
            try fileManager.moveItem(at: recording.folderURL, to: destination)
            refresh()
        } catch {
            errorMessage = String(localized: "The recording could not be renamed: \(error.localizedDescription)")
        }
    }

    func delete(_ recording: RecordingSummary) {
        do {
            try trashHandler(recording.folderURL)
            recordings.removeAll { $0.id == recording.id }
        } catch {
            errorMessage = String(localized: "The recording could not be moved to the Trash: \(error.localizedDescription)")
        }
    }

    func revealInFinder(_ recording: RecordingSummary) {
        NSWorkspace.shared.activateFileViewerSelecting([recording.folderURL])
    }

    func dismissError() { errorMessage = nil }
}
