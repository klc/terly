import Foundation

enum SCPTransferDirection: String, CaseIterable, Identifiable, Codable, Sendable {
    case upload
    case download

    var id: String { rawValue }

    var label: String {
        switch self {
        case .upload:
            return String(localized: "Upload")
        case .download:
            return String(localized: "Download")
        }
    }
}

struct SCPTransferRequest: Equatable, Sendable {
    let direction: SCPTransferDirection
    let alias: String
    let localURL: URL
    let remotePath: String
    /// True when the local source (upload) or destination (download) is a directory.
    /// When true, the plan builder will emit `scp -r`.
    let isDirectory: Bool

    init(
        direction: SCPTransferDirection,
        alias: String,
        localURL: URL,
        remotePath: String,
        isDirectory: Bool = false
    ) {
        self.direction = direction
        self.alias = alias
        self.localURL = localURL
        self.remotePath = remotePath
        self.isDirectory = isDirectory
    }
}

struct SCPTransferPlan: Equatable, Sendable {
    let request: SCPTransferRequest
    let process: TerminalProcessConfiguration
}

struct SCPTransferOutput: Equatable, Sendable {
    let standardOutput: String
    let standardError: String
}

struct SCPTransferProgressUpdate: Equatable, Sendable {
    let fraction: Double
    let transferRate: String?
}

enum SCPTransferCompletion: Sendable {
    case succeeded(SCPTransferOutput)
    case failed(String)
}

enum SCPTransferState: Equatable, Sendable {
    case idle
    case transferring(SCPTransferRequest)
    case succeeded(SCPTransferOutput)
    case failed(String)
    case cancelled
}

enum SCPTransferError: LocalizedError, Equatable {
    case transferAlreadyInProgress
    case unsavedChanges
    case noConcreteAlias
    case missingLocalFile
    case localFileIsDirectory
    case missingDestinationDirectory
    case invalidRemotePath
    case processFailed(exitCode: Int32, output: String)

    var errorDescription: String? {
        switch self {
        case .transferAlreadyInProgress:
            return String(localized: "A new transfer can't start until the current one finishes.")
        case .unsavedChanges:
            return String(localized: "Save your changes before starting the transfer. SCP uses the ~/.ssh/config file on disk.")
        case .noConcreteAlias:
            return String(localized: "Select a specific SSH alias for the file transfer.")
        case .missingLocalFile:
            return String(localized: "The selected local file could not be found.")
        case .localFileIsDirectory:
            return String(localized: "Only a single file can be transferred in this version; folders aren't supported.")
        case .missingDestinationDirectory:
            return String(localized: "The local destination folder could not be found.")
        case .invalidRemotePath:
            return String(localized: "The remote file path can't be empty or contain a line break.")
        case let .processFailed(_, output):
            return output.isEmpty ? String(localized: "The SCP transfer could not complete.") : output
        }
    }
}
