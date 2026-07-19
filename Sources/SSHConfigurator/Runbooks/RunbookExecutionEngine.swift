import Foundation

enum RunbookHostStatus: Equatable, Sendable {
    case pending
    case running(step: Int, totalSteps: Int)
    case succeeded
    case failed(String)

    var isTerminal: Bool {
        switch self {
        case .succeeded, .failed: return true
        case .pending, .running: return false
        }
    }
}

struct RunbookHostResult: Identifiable, Equatable, Sendable {
    let alias: String
    var status: RunbookHostStatus
    /// Combined stdout+stderr for every step run so far, with a header line
    /// per step, in the order the steps executed.
    var output: String

    var id: String { alias }

    init(alias: String, status: RunbookHostStatus = .pending, output: String = "") {
        self.alias = alias
        self.status = status
        self.output = output
    }
}

/// Runs a runbook's steps, in order, against one or more hosts, with a
/// concurrency limit across hosts. Each host is fully independent: a failure
/// on one host never stops or affects any other host's run (see
/// `RunbookExecutionEngineTests` for the isolation guarantee). Mirrors the
/// `@MainActor` engine-behind-a-protocol shape used by `TunnelWorkspaceModel`
/// and `TransferQueueEngine`.
@MainActor
final class RunbookExecutionEngine: ObservableObject {
    static let defaultConcurrencyLimit = 3
    static let concurrencyLimitRange = 1 ... 5

    @Published private(set) var orderedAliases: [String] = []
    @Published private(set) var results: [String: RunbookHostResult] = [:]
    @Published private(set) var isRunning = false

    private let processExecuting: any SSHProcessExecuting
    private let sshURL: URL

    private var runTask: Task<Void, Never>?
    private var lastRunbook: Runbook?
    private var lastValues: [String: String] = [:]
    private var lastConcurrencyLimit = RunbookExecutionEngine.defaultConcurrencyLimit

    init(
        processExecuting: any SSHProcessExecuting = SSHProcessClient(),
        sshURL: URL = URL(fileURLWithPath: "/usr/bin/ssh")
    ) {
        self.processExecuting = processExecuting
        self.sshURL = sshURL
    }

    var orderedResults: [RunbookHostResult] {
        orderedAliases.compactMap { results[$0] }
    }

    /// Starts a fresh run. `targets` is the fully-resolved list of host
    /// aliases to run against (a single alias, or every member alias of a
    /// connection group) — resolving that list, and getting the user's
    /// explicit go-ahead on it, is the run sheet's job, not this engine's.
    func run(runbook: Runbook, values: [String: String], targets: [String], concurrencyLimit: Int = defaultConcurrencyLimit) {
        cancel()

        let limit = min(max(concurrencyLimit, Self.concurrencyLimitRange.lowerBound), Self.concurrencyLimitRange.upperBound)
        lastRunbook = runbook
        lastValues = values
        lastConcurrencyLimit = limit

        orderedAliases = targets
        results = Dictionary(uniqueKeysWithValues: targets.map { ($0, RunbookHostResult(alias: $0)) })
        start(runbook: runbook, values: values, targets: targets, concurrencyLimit: limit)
    }

    /// Re-runs the runbook only against hosts currently in a `.failed` state,
    /// leaving already-succeeded hosts' results untouched.
    func retryFailedHosts() {
        guard let runbook = lastRunbook, !isRunning else { return }
        let failedAliases = orderedAliases.filter { alias in
            if case .failed = results[alias]?.status { return true }
            return false
        }
        guard !failedAliases.isEmpty else { return }

        for alias in failedAliases {
            results[alias] = RunbookHostResult(alias: alias)
        }
        start(runbook: runbook, values: lastValues, targets: failedAliases, concurrencyLimit: lastConcurrencyLimit)
    }

    /// Cancels every in-flight host run. Hosts still `.pending` or `.running`
    /// are marked `.failed` with a cancellation message; already-terminal
    /// hosts are left as-is.
    func cancel() {
        runTask?.cancel()
        runTask = nil
        isRunning = false
        for alias in orderedAliases {
            guard let status = results[alias]?.status, !status.isTerminal else { continue }
            results[alias]?.status = .failed(String(localized: "Cancelled."))
        }
    }

    private func start(runbook: Runbook, values: [String: String], targets: [String], concurrencyLimit: Int) {
        isRunning = true
        runTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.executeAll(runbook: runbook, values: values, targets: targets, concurrencyLimit: concurrencyLimit)
            guard !Task.isCancelled else { return }
            self.isRunning = false
        }
    }

    private func executeAll(runbook: Runbook, values: [String: String], targets: [String], concurrencyLimit: Int) async {
        await withTaskGroup(of: Void.self) { group in
            var pending = targets[...]
            var inFlight = 0

            func startNext() {
                while inFlight < concurrencyLimit, let alias = pending.first {
                    pending = pending.dropFirst()
                    inFlight += 1
                    group.addTask { [weak self] in
                        await self?.executeHost(alias: alias, runbook: runbook, values: values)
                    }
                }
            }

            startNext()
            while await group.next() != nil {
                inFlight -= 1
                startNext()
            }
        }
    }

    private func executeHost(alias: String, runbook: Runbook, values: [String: String]) async {
        guard !Task.isCancelled else { return }

        let totalSteps = runbook.steps.count
        var failureMessage: String?

        for (index, step) in runbook.steps.enumerated() {
            if Task.isCancelled {
                failureMessage = String(localized: "Cancelled.")
                break
            }
            updateStatus(alias: alias, .running(step: index + 1, totalSteps: totalSteps))

            let composedCommand: String
            do {
                composedCommand = try RunbookCommandComposer.compose(step: step, values: values)
            } catch {
                appendOutput(alias: alias, String(localized: "[Step \(index + 1)] \(error.localizedDescription)"))
                failureMessage = error.localizedDescription
                break
            }

            appendOutput(alias: alias, String(localized: "[Step \(index + 1)] \(step.command)"))

            let request = SSHProcessRequest(
                executableURL: sshURL,
                arguments: ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "--", alias, composedCommand],
                environment: SSHProcessEnvironment.tool()
            )

            do {
                let result = try await processExecuting.execute(request)
                let combined = result.combinedOutput
                if !combined.isEmpty {
                    appendOutput(alias: alias, combined)
                }
                if result.terminationStatus != 0 {
                    let message = String(localized: "Step \(index + 1) failed with exit code \(result.terminationStatus).")
                    if step.continueOnError {
                        appendOutput(alias: alias, message)
                    } else {
                        failureMessage = message
                        break
                    }
                }
            } catch {
                let message = error.localizedDescription
                appendOutput(alias: alias, String(localized: "[Step \(index + 1)] \(message)"))
                if step.continueOnError {
                    continue
                } else {
                    failureMessage = message
                    break
                }
            }
        }

        if let failureMessage {
            updateStatus(alias: alias, .failed(failureMessage))
        } else {
            updateStatus(alias: alias, .succeeded)
        }
    }

    private func updateStatus(alias: String, _ status: RunbookHostStatus) {
        results[alias]?.status = status
    }

    private func appendOutput(alias: String, _ text: String) {
        guard var result = results[alias] else { return }
        result.output += result.output.isEmpty ? text : "\n\(text)"
        results[alias] = result
    }
}
