import XCTest
@testable import SSHConfigurator

final class SSHErrorClassifierTests: XCTestCase {
    private let classifier = SSHErrorClassifier()

    func testClassifiesCommonSSHAndTransferFailures() {
        let cases: [(String, SSHFailureKind)] = [
            ("ssh: Could not resolve hostname prod: nodename nor servname provided", .dnsResolution),
            ("ssh: connect to host prod port 22: Operation timed out", .connectionTimeout),
            ("ssh: connect to host prod port 22: Connection refused", .connectionRefused),
            ("WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!", .hostKeyMismatch),
            ("No ED25519 host key is known for prod and you have requested strict checking. Host key verification failed.", .hostKeyUnknown),
            ("sign_and_send_pubkey: signing failed: agent refused operation", .agentUnavailable),
            ("deploy@prod: Permission denied (publickey).", .permissionDenied),
            ("stdio forwarding failed\r\nkex_exchange_identification: Connection closed by remote host", .proxyJump),
            ("channel 0: open failed: connect failed: Connection refused", .proxyJump),
        ]

        for (output, expectedKind) in cases {
            XCTAssertEqual(classifier.classify(output: output).kind, expectedKind, output)
        }
    }

    func testClassifiesProcessTimeoutAndCancellation() {
        XCTAssertEqual(
            classifier.classify(output: "", processError: .timedOut(5)).kind,
            .connectionTimeout
        )
        XCTAssertEqual(
            classifier.classify(output: "", processError: .cancelled).kind,
            .cancelled
        )
    }

    func testClassifiesAskpassCancellationAsAuthenticationCancelled() {
        // The bundled askpass helper (terly-askpass.sh) writes this exact
        // marker to stderr — which ssh/scp/sftp inherit and we capture — the
        // moment the user dismisses a password or host-key dialog. It must
        // never be confused with a generic "Permission denied" failure.
        let output = "user@prod-api's password: \nTERLY_ASKPASS_CANCELLED\nPermission denied (publickey,password)."

        XCTAssertEqual(classifier.classify(output: output).kind, .authenticationCancelled)
    }

    func testAskpassCancellationMarkerIsCaseInsensitive() {
        let output = "Terly_Askpass_Cancelled"
        XCTAssertEqual(classifier.classify(output: output).kind, .authenticationCancelled)
    }

    func testAskpassCancellationTakesPriorityOverGenericPermissionDenied() {
        // Without the marker present, the same trailing text must still
        // classify as the pre-existing permission-denied category — the new
        // category only fires when the marker is actually there.
        let output = "Permission denied (publickey,password)."
        XCTAssertEqual(classifier.classify(output: output).kind, .permissionDenied)
    }

    // MARK: - WP5: sftp file-operation classification

    func testNoSuchFileClassifiesAsRemoteNotFoundEvenWithoutAnSftpCommandContext() {
        let output = "remote rmdir \"/home/deploy/gone\": No such file"
        XCTAssertEqual(classifier.classify(output: output).kind, .remoteNotFound)
    }

    func testNoSuchFileDoesNotCollideWithAgentNoSuchIdentity() {
        // "no such file" and "no such identity" share the "no such" prefix but must
        // classify to different, unrelated categories.
        let output = "sign_and_send_pubkey: no such identity: /Users/dev/.ssh/id_ed25519: No such file or directory"
        XCTAssertEqual(classifier.classify(output: output).kind, .agentUnavailable)
    }

    func testGenericFailureWithoutSftpCommandContextStaysUnknown() {
        // Without knowing which sftp verb was attempted, a bare "Failure" carries no
        // recoverable meaning and must fall through to the generic category — it must
        // NOT be guessed at as "directory not empty" or "already exists".
        let output = "Failure"
        XCTAssertEqual(classifier.classify(output: output).kind, .unknown)
    }

    func testRemoveDirectoryFailureClassifiesAsDirectoryNotEmpty() {
        let output = "remote rmdir \"/home/deploy/uploads\": Failure"
        let classified = classifier.classify(output: output, sftpCommand: .removeDirectory)
        XCTAssertEqual(classified.kind, .remoteDirectoryNotEmpty)
        XCTAssertTrue(classified.userFacingDescription.contains("not empty"))
    }

    func testRenameFailureClassifiesAsAlreadyExists() {
        let output = "remote rename \"/home/deploy/a\" to \"/home/deploy/b\": Failure"
        let classified = classifier.classify(output: output, sftpCommand: .rename)
        XCTAssertEqual(classified.kind, .remoteAlreadyExists)
    }

    func testCreateDirectoryFailureClassifiesAsAlreadyExists() {
        let output = "Couldn't create directory: Failure"
        let classified = classifier.classify(output: output, sftpCommand: .createDirectory)
        XCTAssertEqual(classified.kind, .remoteAlreadyExists)
    }

    func testRemoveFileFailureClassifiesAsUnknownWithFileSpecificGuidance() {
        let output = "remote rm \"/home/deploy/report.txt\": Failure"
        let classified = classifier.classify(output: output, sftpCommand: .remove)
        XCTAssertEqual(classified.kind, .unknown)
        XCTAssertTrue(classified.userFacingDescription.contains("The file couldn't be deleted"))
    }

    func testPermissionDeniedWithSftpCommandClassifiesAsOperationPermissionDeniedNotAuthFailure() {
        let output = "remote rm \"/etc/shadow\": Permission denied"
        let classified = classifier.classify(output: output, sftpCommand: .remove)
        XCTAssertEqual(classified.kind, .remoteOperationPermissionDenied)
    }

    func testPermissionDeniedWithoutSftpCommandStillClassifiesAsAuthFailure() {
        // Backward compatibility: connection-phase "Permission denied" (e.g. from ssh/scp)
        // must keep meaning "authentication was rejected", not a file-operation error.
        let output = "deploy@prod: Permission denied (publickey)."
        XCTAssertEqual(classifier.classify(output: output).kind, .permissionDenied)
    }

    func testAskpassCancellationStillTakesPriorityWhenSftpCommandProvided() {
        let output = "TERLY_ASKPASS_CANCELLED"
        XCTAssertEqual(classifier.classify(output: output, sftpCommand: .removeDirectory).kind, .authenticationCancelled)
    }
}
