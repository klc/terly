import Combine
import Foundation

@MainActor
final class SCPTransferWorkspaceModel: ObservableObject {
    @Published private(set) var state: SCPTransferState = .idle
    @Published private(set) var progress: Double?
    @Published private(set) var transferRate: String?
    @Published private(set) var errorMessage: String?

    private let planBuilder: SCPTransferPlanBuilder
    private let executor: any SCPTransferExecuting
    private var activeProcess: (any SCPTransferProcess)?

    init(
        planBuilder: SCPTransferPlanBuilder = SCPTransferPlanBuilder(),
        executor: any SCPTransferExecuting = SCPTransferRunner()
    ) {
        self.planBuilder = planBuilder
        self.executor = executor
    }

    var isTransferring: Bool {
        if case .transferring = state { return true }
        return false
    }

    @discardableResult
    func start(_ request: SCPTransferRequest, hasUnsavedChanges: Bool) -> Bool {
        guard !isTransferring else {
            errorMessage = SCPTransferError.transferAlreadyInProgress.localizedDescription
            return false
        }
        guard !hasUnsavedChanges else {
            errorMessage = SCPTransferError.unsavedChanges.localizedDescription
            return false
        }

        do {
            let plan = try planBuilder.makePlan(for: request)
            state = .transferring(request)
            progress = nil
            transferRate = nil
            errorMessage = nil
            activeProcess = try executor.start(plan: plan) { [weak self] value in
                Task { @MainActor in
                    self?.updateProgress(value)
                }
            } completion: { [weak self] result in
                Task { @MainActor in
                    self?.finish(result)
                }
            }
            return true
        } catch {
            state = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
            return false
        }
    }

    func cancel() {
        guard isTransferring else { return }
        activeProcess?.cancel()
        activeProcess = nil
        state = .cancelled
        progress = nil
        transferRate = nil
        errorMessage = nil
    }

    func dismissError() {
        errorMessage = nil
    }

    func resetStatus() {
        guard !isTransferring else { return }
        state = .idle
        progress = nil
        transferRate = nil
        errorMessage = nil
    }

    private func finish(_ result: SCPTransferCompletion) {
        guard isTransferring else { return }
        activeProcess = nil
        switch result {
        case let .succeeded(output):
            state = .succeeded(output)
            progress = 1
            errorMessage = nil
        case let .failed(error):
            state = .failed(error)
            progress = nil
            transferRate = nil
            errorMessage = error
        }
    }

    private func updateProgress(_ update: SCPTransferProgressUpdate) {
        guard isTransferring else { return }
        progress = min(max(update.fraction, 0), 1)
        if let transferRate = update.transferRate {
            self.transferRate = transferRate
        }
    }
}
