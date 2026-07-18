import Foundation

// MARK: - Protocol

protocol FolderTransferExecuting: AnyObject {
    @discardableResult
    func start(
        item: TransferItem,
        onProgress: @escaping @Sendable (SCPTransferProgressUpdate) -> Void,
        completion: @escaping @Sendable (SCPTransferCompletion) -> Void
    ) throws -> any SCPTransferProcess
}

// MARK: - SFTP Folder Transfer Runner

/// Transfers directories using SFTP batch commands (`put -r` / `get -r`).
/// Requires the sftp-server subsystem to be enabled on the remote host.
final class SFTPFolderTransferRunner: FolderTransferExecuting {
    private let sftpURL: URL
    private let environment: [String: String]
    private let processClient: any SSHProcessExecuting
    private let errorClassifier = SSHErrorClassifier()

    init(
        sftpURL: URL = URL(fileURLWithPath: "/usr/bin/sftp"),
        environment: [String: String] = SSHProcessEnvironment.interactiveAuth(),
        processClient: any SSHProcessExecuting = SSHProcessClient()
    ) {
        self.sftpURL = sftpURL
        self.environment = environment
        self.processClient = processClient
    }

    @discardableResult
    func start(
        item: TransferItem,
        onProgress: @escaping @Sendable (SCPTransferProgressUpdate) -> Void,
        completion: @escaping @Sendable (SCPTransferCompletion) -> Void
    ) throws -> any SCPTransferProcess {
        let alias = item.alias.trimmingCharacters(in: .whitespacesAndNewlines)
        let progressParser = SCPTransferProgressParser()
        let errorClassifier = errorClassifier

        let batch: String
        switch item.direction {
        case .upload:
            let quoted = SFTPFolderTransferRunner.quote(item.localURL.path)
            let remote = SFTPFolderTransferRunner.quote(item.remotePath)
            batch = "put -r \(quoted) \(remote)\n"
        case .download:
            let remote = SFTPFolderTransferRunner.quote(item.remotePath)
            let local = SFTPFolderTransferRunner.quote(item.localURL.path)
            batch = "get -r \(remote) \(local)\n"
        }

        let request = SSHProcessRequest(
            executableURL: sftpURL,
            arguments: ["-q", "-b", "-", "--", alias],
            environment: environment,
            standardInput: Data(batch.utf8)
        )

        let task = try processClient.start(request) { _, data in
            if let progress = progressParser.consume(data) {
                onProgress(progress)
            }
        } completion: { result in
            DispatchQueue.main.async {
                switch result {
                case let .success(r) where r.terminationStatus == 0:
                    completion(.succeeded(SCPTransferOutput(
                        standardOutput: r.standardOutput,
                        standardError: r.standardError
                    )))
                case let .success(r):
                    let classified = errorClassifier.classify(output: r.combinedOutput)
                    completion(.failed(SCPTransferError.processFailed(
                        exitCode: r.terminationStatus,
                        output: classified.userFacingDescription
                    ).localizedDescription))
                case let .failure(error):
                    completion(.failed(errorClassifier.classify(
                        output: "",
                        processError: error
                    ).userFacingDescription))
                }
            }
        }
        return SFTPFolderProcessHandle(task: task)
    }

    private static func quote(_ path: String) -> String {
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

private final class SFTPFolderProcessHandle: SCPTransferProcess {
    private let task: any SSHProcessTask
    init(task: any SSHProcessTask) { self.task = task }
    func cancel() { task.cancel() }
}


