import Foundation
import XCTest

/// Black-box tests for the bundled `terly-askpass.sh` SSH_ASKPASS helper.
///
/// The script's job is to classify the prompt ssh/scp/sftp hands it (host-key
/// yes/no confirmation vs. a password/passphrase prompt), show the right
/// kind of dialog, and return the user's answer on stdout only — never
/// logging or persisting anything. It talks to macOS exclusively through
/// `osascript`, so these tests replace `osascript` on `PATH` with a small
/// stub that (a) records the AppleScript it was handed so we can verify
/// which dialog template the real script chose, and (b) plays back a canned
/// answer or a cancellation, without ever touching real UI. This keeps the
/// classification and stdout-only-secret behaviour covered by `swift test`
/// on a machine with no display.
final class AskpassHelperScriptTests: XCTestCase {
    private static let scriptURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AskpassHelperScriptTests.swift -> SSHConfiguratorTests
            .deletingLastPathComponent() // SSHConfiguratorTests -> Tests
            .deletingLastPathComponent() // Tests -> repo root
            .appendingPathComponent("Sources/SSHConfigurator/Askpass/terly-askpass.sh")
    }()

    func testScriptExistsAndIsExecutable() {
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: Self.scriptURL.path))
    }

    func testHostKeyPromptRoutesToConfirmationDialogAndReturnsLiteralAnswer() throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        let result = try harness.run(
            prompt: "The authenticity of host 'prod-api (1.2.3.4)' can't be established.\n"
                + "ED25519 key fingerprint is SHA256:abcdef.\n"
                + "Are you sure you want to continue connecting (yes/no/[fingerprint])? ",
            stubMode: .answer("yes")
        )

        // Routed to the approve/reject dialog, not the password one.
        XCTAssertTrue(result.capturedAppleScript.contains("Evet"))
        XCTAssertTrue(result.capturedAppleScript.contains("Hayır"))
        XCTAssertFalse(result.capturedAppleScript.contains("hidden answer"))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "yes\n")
        XCTAssertEqual(result.stderr, "")
    }

    func testHostKeyPromptNeverAutoAnswersYes() throws {
        // Even though the confirmation dialog's *default* button is "Hayır"
        // (fail closed), the script must not print anything on its own — it
        // only prints whatever the (stubbed) dialog interaction produced.
        let harness = try Harness()
        defer { harness.cleanUp() }

        let result = try harness.run(
            prompt: "Are you sure you want to continue connecting (yes/no/[fingerprint])? ",
            stubMode: .answer("no")
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "no\n")
    }

    func testPasswordPromptRoutesToHiddenAnswerDialog() throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        let result = try harness.run(
            prompt: "deploy@prod-api's password: ",
            stubMode: .answer("s3cr3t")
        )

        XCTAssertTrue(result.capturedAppleScript.contains("hidden answer"))
        XCTAssertFalse(result.capturedAppleScript.contains("Evet"))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "s3cr3t\n")
        // The secret must never appear on stderr or in the AppleScript we
        // handed to osascript (it's only ever passed back on stdout).
        XCTAssertFalse(result.capturedAppleScript.contains("s3cr3t"))
        XCTAssertEqual(result.stderr, "")
    }

    func testPassphrasePromptAlsoRoutesToHiddenAnswerDialog() throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        let result = try harness.run(
            prompt: "Enter passphrase for key '/Users/klc/.ssh/id_ed25519': ",
            stubMode: .answer("hunter2")
        )

        XCTAssertTrue(result.capturedAppleScript.contains("hidden answer"))
        XCTAssertEqual(result.stdout, "hunter2\n")
    }

    func testCancellationYieldsEmptyStdoutNonZeroExitAndStderrMarker() throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        let result = try harness.run(
            prompt: "deploy@prod-api's password: ",
            stubMode: .cancel
        )

        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "")
        XCTAssertTrue(result.stderr.contains("TERLY_ASKPASS_CANCELLED"))
    }

    func testHostKeyCancellationAlsoYieldsEmptyStdoutAndMarker() throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        let result = try harness.run(
            prompt: "Are you sure you want to continue connecting (yes/no/[fingerprint])? ",
            stubMode: .cancel
        )

        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "")
        XCTAssertTrue(result.stderr.contains("TERLY_ASKPASS_CANCELLED"))
    }

    func testLockDirectoryIsReleasedAfterRunSoASecondPromptCanProceed() throws {
        let harness = try Harness()
        defer { harness.cleanUp() }

        _ = try harness.run(prompt: "deploy@prod-api's password: ", stubMode: .answer("first"))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: harness.lockDirectoryURL.path),
            "Lock directory must be removed once the dialog interaction finishes"
        )

        // A second, independent invocation (simulating a second concurrent
        // transfer) must still be able to acquire the lock and complete.
        let second = try harness.run(prompt: "deploy@prod-api's password: ", stubMode: .answer("second"))
        XCTAssertEqual(second.exitCode, 0)
        XCTAssertEqual(second.stdout, "second\n")
    }

    // MARK: - Harness

    private enum StubMode {
        case answer(String)
        case cancel
    }

    private struct RunResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
        let capturedAppleScript: String
    }

    private final class Harness {
        let rootURL: URL
        let capturePathURL: URL
        let lockDirectoryURL: URL

        init() throws {
            rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("terly-askpass-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            capturePathURL = rootURL.appendingPathComponent("captured-applescript.txt")
            lockDirectoryURL = rootURL.appendingPathComponent("terly-askpass.lock", isDirectory: true)

            let stubScript = """
            #!/bin/sh
            cat > "$CAPTURE_FILE"
            if [ "$STUB_MODE" = "cancel" ]; then
                exit 1
            fi
            printf '%s' "$STUB_ANSWER"
            exit 0
            """
            let stubURL = rootURL.appendingPathComponent("osascript")
            try stubScript.write(to: stubURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stubURL.path)
        }

        func run(prompt: String, stubMode: StubMode) throws -> RunResult {
            try? FileManager.default.removeItem(at: capturePathURL)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [AskpassHelperScriptTests.scriptURL.path, prompt]

            var environment: [String: String] = [
                "PATH": "\(rootURL.path):/usr/bin:/bin",
                "TMPDIR": rootURL.path,
                "CAPTURE_FILE": capturePathURL.path,
            ]
            switch stubMode {
            case let .answer(value):
                environment["STUB_MODE"] = "answer"
                environment["STUB_ANSWER"] = value
            case .cancel:
                environment["STUB_MODE"] = "cancel"
            }
            process.environment = environment

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            try process.run()
            process.waitUntilExit()

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let capturedAppleScript = (try? String(contentsOf: capturePathURL, encoding: .utf8)) ?? ""

            return RunResult(
                exitCode: process.terminationStatus,
                stdout: String(decoding: stdoutData, as: UTF8.self),
                stderr: String(decoding: stderrData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                capturedAppleScript: capturedAppleScript
            )
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }
}
