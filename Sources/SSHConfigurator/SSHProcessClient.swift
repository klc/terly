import Foundation

enum SSHProcessStream: Sendable {
    case standardOutput
    case standardError
}

struct SSHProcessRequest: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let currentDirectoryURL: URL?
    let standardInput: Data?
    let timeout: TimeInterval?

    init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String] = SSHProcessEnvironment.tool(),
        currentDirectoryURL: URL? = FileManager.default.homeDirectoryForCurrentUser,
        standardInput: Data? = nil,
        timeout: TimeInterval? = nil
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.currentDirectoryURL = currentDirectoryURL
        self.standardInput = standardInput
        self.timeout = timeout
    }

    init(configuration: TerminalProcessConfiguration, timeout: TimeInterval? = nil) {
        self.init(
            executableURL: configuration.executableURL,
            arguments: configuration.arguments,
            environment: configuration.environment,
            currentDirectoryURL: configuration.currentDirectoryURL,
            timeout: timeout
        )
    }
}

struct SSHProcessResult: Equatable, Sendable {
    let terminationStatus: Int32
    let standardOutput: String
    let standardError: String
    let duration: TimeInterval

    var combinedOutput: String {
        [standardError, standardOutput]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

enum SSHProcessClientError: LocalizedError, Equatable, Sendable {
    case launchFailed(String)
    case timedOut(TimeInterval)
    case cancelled

    var errorDescription: String? {
        switch self {
        case let .launchFailed(message):
            return String(localized: "SSH tool failed to launch: \(message)")
        case let .timedOut(seconds):
            return String(localized: "Operation did not complete within \(seconds.formatted(.number.precision(.fractionLength(0 ... 1)))) seconds.")
        case .cancelled:
            return String(localized: "Operation was cancelled.")
        }
    }
}

protocol SSHProcessTask: AnyObject, Sendable {
    func cancel()
}

protocol SSHProcessExecuting: Sendable {
    @discardableResult
    func start(
        _ request: SSHProcessRequest,
        onOutput: @escaping @Sendable (SSHProcessStream, Data) -> Void,
        completion: @escaping @Sendable (Result<SSHProcessResult, SSHProcessClientError>) -> Void
    ) throws -> any SSHProcessTask
}

extension SSHProcessExecuting {
    func execute(_ request: SSHProcessRequest) async throws -> SSHProcessResult {
        let taskBox = SSHProcessTaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled, !taskBox.isCancelled else {
                    continuation.resume(throwing: SSHProcessClientError.cancelled)
                    return
                }

                do {
                    let task = try start(request, onOutput: { _, _ in }) { result in
                        continuation.resume(with: result)
                    }
                    taskBox.install(task)
                } catch let error as SSHProcessClientError {
                    continuation.resume(throwing: error)
                } catch {
                    continuation.resume(throwing: SSHProcessClientError.launchFailed(error.localizedDescription))
                }
            }
        } onCancel: {
            taskBox.cancel()
        }
    }
}

enum SSHProcessEnvironment {
    static let fallbackPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    static func tool(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = interactive(base: base)
        environment["LC_ALL"] = "C"
        return environment
    }

    static func interactive(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base
        if environment["PATH", default: ""].isEmpty {
            environment["PATH"] = fallbackPath
        }
        return environment
    }

    /// Environment for SSH-family processes that may need to prompt for a
    /// password/passphrase or a host-key confirmation instead of failing
    /// closed with `BatchMode=yes`. Points `SSH_ASKPASS` at the bundled
    /// `terly-askpass.sh` helper and forces its use with
    /// `SSH_ASKPASS_REQUIRE=force` (so it fires even though the process has
    /// no controlling terminal); `DISPLAY` is set because some OpenSSH
    /// builds still gate askpass usage on it being present.
    ///
    /// If the helper can't be located (e.g. running under `swift test`,
    /// where there is no app bundle), none of the three variables are set —
    /// callers get the same behaviour as `tool()`, just without
    /// `BatchMode=yes`.
    static func interactiveAuth(
        base: [String: String] = ProcessInfo.processInfo.environment,
        askpassURL: URL? = AskpassHelperLocator.helperURL()
    ) -> [String: String] {
        var environment = tool(base: base)
        if let askpassURL {
            environment["SSH_ASKPASS"] = askpassURL.path
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["DISPLAY"] = ":0"
        }
        return environment
    }
}

final class SSHProcessClient: SSHProcessExecuting, @unchecked Sendable {
    static let maximumCapturedOutputBytes = 1_048_576

    @discardableResult
    func start(
        _ request: SSHProcessRequest,
        onOutput: @escaping @Sendable (SSHProcessStream, Data) -> Void,
        completion: @escaping @Sendable (Result<SSHProcessResult, SSHProcessClientError>) -> Void
    ) throws -> any SSHProcessTask {
        let process = Process()
        process.executableURL = request.executableURL
        process.arguments = request.arguments
        process.environment = request.environment
        process.currentDirectoryURL = request.currentDirectoryURL

        let standardInput = request.standardInput.map { _ in Pipe() }
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError

        let lifecycle = SSHProcessLifecycle(
            process: process,
            standardOutput: standardOutput,
            standardError: standardError,
            timeout: request.timeout,
            maximumCapturedOutputBytes: Self.maximumCapturedOutputBytes,
            onOutput: onOutput,
            completion: completion
        )
        lifecycle.installHandlers()

        do {
            try process.run()
        } catch {
            lifecycle.abortLaunch()
            throw SSHProcessClientError.launchFailed(error.localizedDescription)
        }

        lifecycle.didStart()
        if let data = request.standardInput, let standardInput {
            standardInput.fileHandleForWriting.write(data)
            try? standardInput.fileHandleForWriting.close()
        }
        return lifecycle
    }
}

private final class SSHProcessTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: (any SSHProcessTask)?
    private var wasCancelled = false

    func install(_ task: any SSHProcessTask) {
        let shouldCancel = lock.withLock {
            self.task = task
            return wasCancelled
        }
        if shouldCancel { task.cancel() }
    }

    var isCancelled: Bool {
        lock.withLock { wasCancelled }
    }

    func cancel() {
        let task = lock.withLock {
            wasCancelled = true
            return self.task
        }
        task?.cancel()
    }
}

private final class SSHProcessLifecycle: SSHProcessTask, @unchecked Sendable {
    private enum StopReason {
        case cancelled
        case timedOut(TimeInterval)
    }

    private let lock = NSLock()
    private let process: Process
    private let standardOutput: Pipe
    private let standardError: Pipe
    private let timeout: TimeInterval?
    private let maximumCapturedOutputBytes: Int
    private let onOutput: @Sendable (SSHProcessStream, Data) -> Void
    private let completion: @Sendable (Result<SSHProcessResult, SSHProcessClientError>) -> Void
    private let startedAt = Date()
    private var outputData = Data()
    private var errorData = Data()
    private var timer: DispatchSourceTimer?
    private var stopReason: StopReason?
    private var isFinished = false

    init(
        process: Process,
        standardOutput: Pipe,
        standardError: Pipe,
        timeout: TimeInterval?,
        maximumCapturedOutputBytes: Int,
        onOutput: @escaping @Sendable (SSHProcessStream, Data) -> Void,
        completion: @escaping @Sendable (Result<SSHProcessResult, SSHProcessClientError>) -> Void
    ) {
        self.process = process
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.timeout = timeout
        self.maximumCapturedOutputBytes = maximumCapturedOutputBytes
        self.onOutput = onOutput
        self.completion = completion
    }

    func installHandlers() {
        standardOutput.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData, from: .standardOutput)
        }
        standardError.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData, from: .standardError)
        }
        process.terminationHandler = { [weak self] process in
            self?.finish(terminationStatus: process.terminationStatus)
        }
    }

    func didStart() {
        guard let timeout, timeout > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in
            self?.stop(reason: .timedOut(timeout))
        }
        let didInstall = lock.withLock {
            guard !isFinished else { return false }
            self.timer = timer
            timer.resume()
            return true
        }
        if !didInstall {
            // A suspended dispatch source must be resumed before release.
            timer.resume()
            timer.cancel()
        }
    }

    func abortLaunch() {
        standardOutput.fileHandleForReading.readabilityHandler = nil
        standardError.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        lock.withLock { isFinished = true }
    }

    func cancel() {
        stop(reason: .cancelled)
    }

    private func consume(_ data: Data, from stream: SSHProcessStream) {
        guard !data.isEmpty else { return }

        lock.withLock {
            guard !isFinished else { return }

            switch stream {
            case .standardOutput:
                let remainingBytes = maximumCapturedOutputBytes - outputData.count
                if remainingBytes > 0 {
                    outputData.append(data.prefix(min(data.count, remainingBytes)))
                }
            case .standardError:
                let remainingBytes = maximumCapturedOutputBytes - errorData.count
                if remainingBytes > 0 {
                    errorData.append(data.prefix(min(data.count, remainingBytes)))
                }
            }
        }
        onOutput(stream, data)
    }

    private func stop(reason: StopReason) {
        let shouldTerminate = lock.withLock {
            guard !isFinished, stopReason == nil else { return false }
            stopReason = reason
            return true
        }
        guard shouldTerminate else { return }
        terminateForStopReason()
    }

    private func terminateForStopReason() {
        if process.isRunning {
            process.terminate()
        } else {
            finish(terminationStatus: process.terminationStatus)
        }
    }

    private func finish(terminationStatus: Int32) {
        standardOutput.fileHandleForReading.readabilityHandler = nil
        standardError.fileHandleForReading.readabilityHandler = nil
        consume(standardOutput.fileHandleForReading.readDataToEndOfFile(), from: .standardOutput)
        consume(standardError.fileHandleForReading.readDataToEndOfFile(), from: .standardError)

        let completionValue: Result<SSHProcessResult, SSHProcessClientError>? = lock.withLock {
            guard !isFinished else { return nil }
            isFinished = true
            timer?.cancel()
            timer = nil
            let reason = stopReason
            let result = SSHProcessResult(
                terminationStatus: terminationStatus,
                standardOutput: String(decoding: outputData, as: UTF8.self),
                standardError: String(decoding: errorData, as: UTF8.self),
                duration: Date().timeIntervalSince(startedAt)
            )
            switch reason {
            case .cancelled:
                return .failure(.cancelled)
            case let .timedOut(seconds):
                return .failure(.timedOut(seconds))
            case nil:
                return .success(result)
            }
        }

        process.terminationHandler = nil
        if let completionValue { completion(completionValue) }
    }
}
