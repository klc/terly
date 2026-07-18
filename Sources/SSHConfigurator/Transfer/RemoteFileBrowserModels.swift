import Foundation

enum RemoteFileKind: String, Sendable {
    case directory
    case file
    case symbolicLink
}

struct RemoteFileEntry: Identifiable, Equatable, Hashable, Sendable {
    let name: String
    let path: String
    let kind: RemoteFileKind
    let size: Int64?
    let modificationDescription: String

    var id: String { path }
}

struct RemoteDirectorySnapshot: Equatable, Sendable {
    let path: String
    let entries: [RemoteFileEntry]
}

enum RemoteFileBrowserMode: Sendable {
    case directory
    case file
}

enum RemoteFileBrowserSelection: Sendable {
    case directory(RemoteDirectorySnapshot)
    case file(RemoteFileEntry)
}

struct RemotePathBreadcrumb: Identifiable, Equatable, Sendable {
    let label: String
    let path: String

    var id: String { path }
}

enum RemoteFileBrowserError: LocalizedError, Equatable {
    case invalidAlias
    case invalidPath
    case invalidName
    case processFailed(String)
    case unreadableListing

    var errorDescription: String? {
        switch self {
        case .invalidAlias:
            return String(localized: "Select a specific SSH alias to list remote files.")
        case .invalidPath:
            return String(localized: "The remote folder path isn't valid.")
        case .invalidName:
            return String(localized: "Name can't be empty, can't contain \"/\", and can't be \".\" or \"..\".")
        case let .processFailed(message):
            return message.isEmpty ? String(localized: "Couldn't list remote files.") : message
        case .unreadableListing:
            return String(localized: "Couldn't read the SFTP folder output.")
        }
    }
}

/// Validates a user-entered file/folder **name** — a single path component typed into
/// the "Yeni Klasör" or "Yeniden Adlandır" dialog, as opposed to a full remote path.
enum RemoteFileNameValidator {
    /// Returns `true` if `name` (after trimming whitespace) is non-empty, contains no
    /// `/` (which would let it escape the current directory when appended to a path),
    /// and is not the special `.`/`..` component.
    static func isValid(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.contains("/") && trimmed != "." && trimmed != ".."
    }
}

enum RemotePath {
    static func appending(_ name: String, to directory: String) -> String {
        if directory == "/" { return "/\(name)" }
        return "\(directory.hasSuffix("/") ? String(directory.dropLast()) : directory)/\(name)"
    }

    static func parent(of path: String) -> String {
        guard path != "/" else { return "/" }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        return parent.isEmpty ? "/" : parent
    }
}
