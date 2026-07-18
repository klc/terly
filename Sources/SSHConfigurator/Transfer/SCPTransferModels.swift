import Foundation

enum SCPTransferDirection: String, CaseIterable, Identifiable, Codable, Sendable {
    case upload
    case download

    var id: String { rawValue }

    var label: String {
        switch self {
        case .upload:
            return "Yükle"
        case .download:
            return "İndir"
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
            return "Devam eden aktarım bitmeden yeni bir aktarım başlatılamaz."
        case .unsavedChanges:
            return "Aktarımı başlatmadan önce değişiklikleri kaydet. SCP diskteki ~/.ssh/config dosyasını kullanır."
        case .noConcreteAlias:
            return "Dosya aktarımı için somut bir SSH alias'ı seç."
        case .missingLocalFile:
            return "Seçilen yerel dosya bulunamadı."
        case .localFileIsDirectory:
            return "Bu sürümde yalnızca tek bir dosya aktarılabilir; klasör seçilemez."
        case .missingDestinationDirectory:
            return "Yerel hedef klasör bulunamadı."
        case .invalidRemotePath:
            return "Uzak dosya yolu boş olamaz ve satır sonu içeremez."
        case let .processFailed(_, output):
            return output.isEmpty ? "SCP aktarımı tamamlanamadı." : output
        }
    }
}
