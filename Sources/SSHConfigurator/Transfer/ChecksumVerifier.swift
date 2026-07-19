import Foundation

/// Computes and compares SHA-256 digests for a completed single-file
/// transfer. Runs through the shared `SSHProcessExecuting` layer so it gets
/// the same timeout/cancellation/output-collection behaviour as every other
/// SSH-adjacent process in the app.
protocol ChecksumVerifying: Sendable {
    func verify(localURL: URL, alias: String, remotePath: String) async -> ChecksumVerificationState
}

/// Local hashing runs `/usr/bin/shasum` (always present on macOS). Remote
/// hashing runs a small script over `ssh` that tries `shasum` first, then
/// `sha256sum`, and prints a neutral marker if neither tool exists — a
/// missing remote tool is reported as "unavailable", not as a failure.
///
/// The remote path is never concatenated into the command string directly;
/// it is quoted with the same centralized POSIX single-quoting helper the
/// Startup Flow builder uses (`StartupShellQuoter`), and the resulting
/// script is passed to `ssh` as a single argv element — never assembled by
/// joining raw arguments through a local shell.
struct TransferChecksumVerifier: ChecksumVerifying {
    private static let unavailableMarker = "SSHCFG_CHECKSUM_UNAVAILABLE"

    private let localShasumURL: URL
    private let sshURL: URL
    private let processClient: any SSHProcessExecuting
    private let timeout: TimeInterval

    init(
        localShasumURL: URL = URL(fileURLWithPath: "/usr/bin/shasum"),
        sshURL: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
        processClient: any SSHProcessExecuting = SSHProcessClient(),
        timeout: TimeInterval = 120
    ) {
        self.localShasumURL = localShasumURL
        self.sshURL = sshURL
        self.processClient = processClient
        self.timeout = timeout
    }

    func verify(localURL: URL, alias: String, remotePath: String) async -> ChecksumVerificationState {
        async let localResult = localDigest(path: localURL.path)
        async let remoteResult = remoteDigest(alias: alias, path: remotePath)

        guard let local = await localResult else {
            return .unavailable(reason: String(localized: "Local checksum could not be computed."))
        }
        switch await remoteResult {
        case let .unavailable(reason):
            return .unavailable(reason: reason)
        case let .digest(remote):
            return local.caseInsensitiveCompare(remote) == .orderedSame ? .verified : .mismatch
        }
    }

    // MARK: - Local digest

    private func localDigest(path: String) async -> String? {
        do {
            let result = try await processClient.execute(SSHProcessRequest(
                executableURL: localShasumURL,
                arguments: ["-a", "256", "--", path],
                timeout: timeout
            ))
            guard result.terminationStatus == 0 else { return nil }
            return Self.firstToken(of: result.standardOutput)
        } catch {
            return nil
        }
    }

    // MARK: - Remote digest

    private enum RemoteDigestResult {
        case digest(String)
        case unavailable(reason: String?)
    }

    private func remoteDigest(alias: String, path: String) async -> RemoteDigestResult {
        let script = Self.remoteScript(for: path)
        do {
            let result = try await processClient.execute(SSHProcessRequest(
                executableURL: sshURL,
                arguments: [
                    "-o", "ConnectTimeout=15",
                    "--", alias, script,
                ],
                environment: SSHProcessEnvironment.interactiveAuth(),
                timeout: timeout
            ))
            guard result.terminationStatus == 0 else {
                return .unavailable(reason: String(localized: "Remote checksum could not be computed."))
            }
            let output = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !output.contains(Self.unavailableMarker) else {
                return .unavailable(reason: String(localized: "shasum or sha256sum was not found on the server."))
            }
            guard let digest = Self.firstToken(of: output) else {
                return .unavailable(reason: String(localized: "Remote checksum output could not be parsed."))
            }
            return .digest(digest)
        } catch {
            return .unavailable(reason: String(localized: "Remote checksum could not be computed."))
        }
    }

    /// Builds the remote shell script with the path safely single-quoted.
    /// Exposed for testing.
    static func remoteScript(for path: String) -> String {
        let quotedPath = StartupShellQuoter.singleQuoted(path)
        return "if command -v shasum >/dev/null 2>&1; then shasum -a 256 -- \(quotedPath); "
            + "elif command -v sha256sum >/dev/null 2>&1; then sha256sum -- \(quotedPath); "
            + "else echo \(unavailableMarker); fi"
    }

    private static func firstToken(of output: String) -> String? {
        output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .first
            .map(String.init)
    }
}
