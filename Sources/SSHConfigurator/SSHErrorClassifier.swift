import Foundation

enum SSHFailureKind: String, CaseIterable, Equatable, Sendable {
    case dnsResolution
    case connectionTimeout
    case connectionRefused
    case hostKeyMismatch
    case hostKeyUnknown
    case agentUnavailable
    case authenticationCancelled
    case permissionDenied
    case proxyJump
    case processLaunch
    case cancelled
    case remoteNotFound
    case remoteAlreadyExists
    case remoteDirectoryNotEmpty
    case remoteOperationPermissionDenied
    case unknown
}

/// Identifies which sftp batch verb produced the output being classified.
///
/// The SFTP protocol (v3, as implemented by OpenSSH's `sftp-server`) only defines a
/// handful of status codes, and most POSIX errno values that don't have a dedicated
/// code (e.g. `ENOTEMPTY` from a non-empty `rmdir`, or an existing destination from a
/// non-overwriting `rename`) collapse to the single generic `SSH2_FX_FAILURE`, which
/// the `sftp` CLI renders as the bare word "Failure" — indistinguishable by text alone
/// from any other unmapped error. Passing the verb that was attempted lets the
/// classifier turn that ambiguous "Failure" into an operation-appropriate, honest
/// explanation instead of a meaningless one.
enum SFTPOperationKind: Sendable {
    case createDirectory
    case rename
    case remove
    case removeDirectory
}

struct SSHClassifiedError: Equatable, Sendable {
    let kind: SSHFailureKind
    let title: String
    let explanation: String
    let suggestion: String

    var userFacingDescription: String {
        "\(title): \(explanation) \(suggestion)"
    }
}

struct SSHErrorClassifier: Sendable {
    func classify(
        output: String,
        processError: SSHProcessClientError? = nil,
        sftpCommand: SFTPOperationKind? = nil
    ) -> SSHClassifiedError {
        if let processError {
            switch processError {
            case .cancelled:
                return error(
                    .cancelled,
                    String(localized: "Operation cancelled"),
                    String(localized: "The connection check was stopped by the user."),
                    String(localized: "You can try again when you're ready.")
                )
            case .timedOut:
                return error(
                    .connectionTimeout,
                    String(localized: "Connection timed out"),
                    String(localized: "The target didn't respond within the time allotted for this network step."),
                    String(localized: "Check network access, the port, and any ProxyJump chain.")
                )
            case let .launchFailed(message):
                return error(
                    .processLaunch,
                    String(localized: "SSH tool couldn't be launched"),
                    message,
                    String(localized: "Check that the OpenSSH tools are accessible on this system.")
                )
            }
        }

        let normalized = output.lowercased()
        if normalized.contains("terly_askpass_cancelled") {
            return error(
                .authenticationCancelled,
                String(localized: "Authentication cancelled"),
                String(localized: "The password or host identity confirmation prompt was dismissed by the user."),
                String(localized: "Try again when you're ready, and enter the requested password or give the confirmation.")
            )
        }
        if let sftpCommand {
            // Beyond "No such file", the SFTP v3 protocol only has generic status
            // codes: OpenSSH's sftp-server maps most unmapped POSIX errno values
            // (e.g. ENOTEMPTY, or an existing rename destination) to the same bare
            // "Failure" text as any other unexpected error. The verb that was
            // attempted is the only way left to give the user an honest, specific
            // explanation instead of just echoing "Failure".
            if normalized.contains("permission denied") {
                return error(
                    .remoteOperationPermissionDenied,
                    String(localized: "Not authorized for this operation"),
                    String(localized: "The server rejected the operation on this file or folder."),
                    String(localized: "Check the remote file/folder permissions and ownership.")
                )
            }
            if normalized.contains("failure") {
                switch sftpCommand {
                case .removeDirectory:
                    return error(
                        .remoteDirectoryNotEmpty,
                        String(localized: "The folder couldn't be deleted"),
                        String(localized: "The folder is not empty."),
                        String(localized: "This app doesn't delete folders recursively; empty its contents first.")
                    )
                case .rename:
                    return error(
                        .remoteAlreadyExists,
                        String(localized: "Couldn't rename"),
                        String(localized: "The destination name may already be in use."),
                        String(localized: "Choose a different name, or remove the existing item first.")
                    )
                case .createDirectory:
                    return error(
                        .remoteAlreadyExists,
                        String(localized: "Couldn't create the folder"),
                        String(localized: "A file or folder with this name may already exist."),
                        String(localized: "Choose a different name, or check the existing item.")
                    )
                case .remove:
                    return error(
                        .unknown,
                        String(localized: "The file couldn't be deleted"),
                        String(localized: "The server rejected the request."),
                        String(localized: "Make sure the item is a file and that you have write permission.")
                    )
                }
            }
        }
        if containsAny(normalized, [
            "remote host identification has changed",
            "offending ",
        ]) {
            return error(
                .hostKeyMismatch,
                String(localized: "Server identity has changed"),
                String(localized: "The saved host key doesn't match the key the server presented."),
                String(localized: "Don't change the known_hosts entry without ruling out a possible attack or server reinstall.")
            )
        }
        if containsAny(normalized, [
            "host key verification failed",
            "no ed25519 host key is known",
            "no ecdsa host key is known",
            "no rsa host key is known",
        ]) {
            return error(
                .hostKeyUnknown,
                String(localized: "Server identity isn't trusted yet"),
                String(localized: "No verified known_hosts entry was found for this host."),
                String(localized: "Verify the fingerprint through an independent channel, then explicitly approve it in a regular terminal connection.")
            )
        }
        if containsAny(normalized, [
            "could not resolve hostname",
            "name or service not known",
            "nodename nor servname provided",
            "temporary failure in name resolution",
        ]) {
            return error(
                .dnsResolution,
                String(localized: "DNS resolution failed"),
                String(localized: "The target hostname couldn't be resolved to an IP address."),
                String(localized: "Check the HostName spelling, the DNS/VPN connection, and the ProxyJump setting.")
            )
        }
        if containsAny(normalized, [
            "stdio forwarding failed",
            "jumphost loop",
            "connection closed by unknown port 65535",
            "channel 0: open failed: connect failed",
        ]) {
            return error(
                .proxyJump,
                String(localized: "ProxyJump chain failed"),
                String(localized: "Couldn't establish the jump host, or the forwarding from the jump host to the target."),
                String(localized: "Check each ProxyJump alias and every host's reachability in the chain individually.")
            )
        }
        if containsAny(normalized, [
            "operation timed out",
            "connection timed out",
            "connect timeout",
        ]) {
            return error(
                .connectionTimeout,
                String(localized: "Connection timed out"),
                String(localized: "The target port didn't respond in time."),
                String(localized: "Check the firewall, VPN, port, and ProxyJump access.")
            )
        }
        if normalized.contains("connection refused") {
            return error(
                .connectionRefused,
                String(localized: "Connection refused"),
                String(localized: "The target was reached, but the specified port refused the connection."),
                String(localized: "Check that the SSH service is running and verify the Port setting.")
            )
        }
        if containsAny(normalized, [
            "the agent has no identities",
            "agent contains no identities",
            "could not open a connection to your authentication agent",
            "agent refused operation",
            "no such identity",
        ]) {
            return error(
                .agentUnavailable,
                String(localized: "SSH agent key unavailable"),
                String(localized: "The agent isn't running, is empty, or can't offer the required key for signing."),
                String(localized: "Check the agent status with ssh-add; don't give the app your private key.")
            )
        }
        // "No such file" is one of the handful of status codes the SFTP protocol (v3)
        // actually defines, so OpenSSH's sftp-server reports it verbatim for a missing
        // remote path — checked here (after the more specific "no such identity" agent
        // check above) so a missing local IdentityFile keeps classifying as an agent
        // problem rather than being reinterpreted as a missing remote sftp path.
        if normalized.contains("no such file") {
            return error(
                .remoteNotFound,
                String(localized: "File or folder not found"),
                String(localized: "The remote path no longer exists — it may have been deleted or moved."),
                String(localized: "Refresh the folder listing and check the path again.")
            )
        }
        if normalized.contains("permission denied") {
            return error(
                .permissionDenied,
                String(localized: "Authentication rejected"),
                String(localized: "The server didn't accept the user or key that was presented."),
                String(localized: "Check the User, IdentityFile, and SSH agent keys.")
            )
        }
        return error(
            .unknown,
            String(localized: "SSH operation failed"),
            output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? String(localized: "OpenSSH didn't provide a detailed error message.")
                : output.trimmingCharacters(in: .whitespacesAndNewlines),
            String(localized: "Review the checks in the diagnostic report.")
        )
    }

    private func containsAny(_ text: String, _ candidates: [String]) -> Bool {
        candidates.contains(where: text.contains)
    }

    private func error(
        _ kind: SSHFailureKind,
        _ title: String,
        _ explanation: String,
        _ suggestion: String
    ) -> SSHClassifiedError {
        SSHClassifiedError(
            kind: kind,
            title: title,
            explanation: explanation,
            suggestion: suggestion
        )
    }
}
