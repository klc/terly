import Foundation

protocol SCPTransferProcess: AnyObject {
    func cancel()
}

protocol SCPTransferExecuting: AnyObject {
    @discardableResult
    func start(
        plan: SCPTransferPlan,
        onProgress: @escaping @Sendable (SCPTransferProgressUpdate) -> Void,
        completion: @escaping @Sendable (SCPTransferCompletion) -> Void
    ) throws -> any SCPTransferProcess
}

final class SCPTransferRunner: SCPTransferExecuting {
    private let scriptURL: URL
    private let processClient: any SSHProcessExecuting
    private let errorClassifier = SSHErrorClassifier()

    init(
        scriptURL: URL = URL(fileURLWithPath: "/usr/bin/script"),
        processClient: any SSHProcessExecuting = SSHProcessClient()
    ) {
        self.scriptURL = scriptURL
        self.processClient = processClient
    }

    @discardableResult
    func start(
        plan: SCPTransferPlan,
        onProgress: @escaping @Sendable (SCPTransferProgressUpdate) -> Void,
        completion: @escaping @Sendable (SCPTransferCompletion) -> Void
    ) throws -> any SCPTransferProcess {
        let progressParser = SCPTransferProgressParser()
        let request = SSHProcessRequest(
            executableURL: scriptURL,
            arguments: ["-q", "-e", "/dev/null", plan.process.executableURL.path] + plan.process.arguments,
            environment: plan.process.environment,
            currentDirectoryURL: plan.process.currentDirectoryURL
        )
        let errorClassifier = errorClassifier
        let task = try processClient.start(request) { _, data in
            if let progress = progressParser.consume(data) {
                onProgress(progress)
            }
        } completion: { result in
            DispatchQueue.main.async {
                switch result {
                case let .success(result) where result.terminationStatus == 0:
                    completion(.succeeded(SCPTransferOutput(
                        standardOutput: result.standardOutput,
                        standardError: result.standardError
                    )))
                case let .success(result):
                    let classified = errorClassifier.classify(output: result.combinedOutput)
                    completion(.failed(SCPTransferError.processFailed(
                        exitCode: result.terminationStatus,
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
        return SCPTransferProcessHandle(task: task)
    }
}

private final class SCPTransferProcessHandle: SCPTransferProcess {
    private let task: any SSHProcessTask

    init(task: any SSHProcessTask) {
        self.task = task
    }

    func cancel() {
        task.cancel()
    }
}

final class SCPTransferProgressParser: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""

    func consume(_ data: Data) -> SCPTransferProgressUpdate? {
        lock.withLock {
            buffer += String(decoding: data, as: UTF8.self)
            defer { buffer = String(buffer.suffix(1_024)) }

            let pattern = #"(?:^|\s)(\d{1,3})%\s+\S+\s+([0-9.]+[KMGTPE]?B/s)"#
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
            let range = NSRange(buffer.startIndex..., in: buffer)
            guard let match = expression.matches(in: buffer, range: range).last,
                  let percentageRange = Range(match.range(at: 1), in: buffer),
                  let percentage = Double(buffer[percentageRange]),
                  (0 ... 100).contains(percentage) else {
                return nil
            }
            let transferRate = Range(match.range(at: 2), in: buffer).map { String(buffer[$0]) }
            return SCPTransferProgressUpdate(
                fraction: percentage / 100,
                transferRate: transferRate
            )
        }
    }
}
