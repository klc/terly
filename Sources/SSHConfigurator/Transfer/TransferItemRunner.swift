import Foundation

/// Executes a single `TransferItem` using either SCP (files and directories)
/// or SFTP (directories only; files fall back to SCP).
@MainActor
final class TransferItemRunner {
    private let scpExecutor: any SCPTransferExecuting
    private let sftpFolderExecutor: any FolderTransferExecuting
    private let planBuilder: SCPTransferPlanBuilder
    private var activeProcess: (any SCPTransferProcess)?

    init(
        scpExecutor: any SCPTransferExecuting = SCPTransferRunner(),
        sftpFolderExecutor: any FolderTransferExecuting = SFTPFolderTransferRunner(),
        planBuilder: SCPTransferPlanBuilder = SCPTransferPlanBuilder()
    ) {
        self.scpExecutor = scpExecutor
        self.sftpFolderExecutor = sftpFolderExecutor
        self.planBuilder = planBuilder
    }

    /// Starts the transfer and returns immediately. Progress and completion arrive via callbacks.
    /// - Returns: `true` if the process launched successfully; `false` with an error message otherwise.
    @discardableResult
    func start(
        item: TransferItem,
        onProgress: @escaping @MainActor (SCPTransferProgressUpdate) -> Void,
        onCompletion: @escaping @MainActor (SCPTransferCompletion) -> Void
    ) -> (launched: Bool, error: String?) {
        // Directory transfers via SFTP use the folder runner.
        if item.isDirectory && item.transferProtocol == .sftp {
            return startSFTPFolder(item: item, onProgress: onProgress, onCompletion: onCompletion)
        }
        // All other cases (single file SCP/SFTP, directory SCP -r) go through the plan builder.
        return startSCP(item: item, onProgress: onProgress, onCompletion: onCompletion)
    }

    func cancel() {
        activeProcess?.cancel()
        activeProcess = nil
    }

    // MARK: - SCP path

    private func startSCP(
        item: TransferItem,
        onProgress: @escaping @MainActor (SCPTransferProgressUpdate) -> Void,
        onCompletion: @escaping @MainActor (SCPTransferCompletion) -> Void
    ) -> (launched: Bool, error: String?) {
        let request = SCPTransferRequest(
            direction: item.direction,
            alias: item.alias,
            localURL: item.localURL,
            remotePath: item.remotePath,
            isDirectory: item.isDirectory
        )
        let plan: SCPTransferPlan
        do {
            plan = try planBuilder.makePlan(for: request)
        } catch {
            return (false, error.localizedDescription)
        }

        do {
            let process = try scpExecutor.start(plan: plan) { update in
                Task { @MainActor in onProgress(update) }
            } completion: { result in
                Task { @MainActor in onCompletion(result) }
            }
            activeProcess = process
            return (true, nil)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    // MARK: - SFTP folder path

    private func startSFTPFolder(
        item: TransferItem,
        onProgress: @escaping @MainActor (SCPTransferProgressUpdate) -> Void,
        onCompletion: @escaping @MainActor (SCPTransferCompletion) -> Void
    ) -> (launched: Bool, error: String?) {
        do {
            let process = try sftpFolderExecutor.start(item: item) { update in
                Task { @MainActor in onProgress(update) }
            } completion: { result in
                Task { @MainActor in onCompletion(result) }
            }
            activeProcess = process
            return (true, nil)
        } catch {
            return (false, error.localizedDescription)
        }
    }
}
