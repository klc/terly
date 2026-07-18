import Foundation

enum KeySetupStepState: Equatable {
    case pending
    case running
    case succeeded
    case failed(String)

    var isTerminal: Bool {
        switch self {
        case .succeeded, .failed: return true
        case .pending, .running: return false
        }
    }
}

/// Runs the three steps of the key setup wizard (WP3): generate an ed25519
/// key pair, optionally add it to the SSH agent, and copy the public key to
/// a server's `authorized_keys`. Every process goes through the shared
/// `SSHProcessExecuting` layer (same timeout/cancellation/output-collection
/// behaviour as the rest of the app) with `SSHProcessEnvironment
/// .interactiveAuth()` so passphrase/host-key prompts surface through the
/// bundled askpass helper instead of failing closed.
///
/// Security invariant: this type never reads the *private* key file. The
/// only file read anywhere in here is `readPublicKey`, which always reads
/// `<privateKeyPath>.pub` — see `KeySetupEngineTests` for a test that proves
/// the private key's content never surfaces even when the two files are
/// distinguishable by content.
@MainActor
final class KeySetupEngine: ObservableObject {
    @Published private(set) var generateState: KeySetupStepState = .pending
    @Published private(set) var agentAddState: KeySetupStepState = .pending
    @Published private(set) var copyState: KeySetupStepState = .pending
    @Published private(set) var verifyState: KeySetupStepState = .pending

    @Published private(set) var generateOutput = ""
    @Published private(set) var agentAddOutput = ""
    @Published private(set) var copyOutput = ""
    @Published private(set) var verifyOutput = ""

    @Published private(set) var publicKeyPreview: String?

    private let processClient: any SSHProcessExecuting
    private let fileManager: FileManager
    private let sshKeygenURL: URL
    private let sshAddURL: URL
    private let sshURL: URL
    private let interactiveEnvironment: [String: String]
    private let batchEnvironment: [String: String]

    init(
        processClient: any SSHProcessExecuting = SSHProcessClient(),
        fileManager: FileManager = .default,
        sshKeygenURL: URL = URL(fileURLWithPath: "/usr/bin/ssh-keygen"),
        sshAddURL: URL = URL(fileURLWithPath: "/usr/bin/ssh-add"),
        sshURL: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
        interactiveEnvironment: [String: String] = SSHProcessEnvironment.interactiveAuth(),
        batchEnvironment: [String: String] = SSHProcessEnvironment.tool()
    ) {
        self.processClient = processClient
        self.fileManager = fileManager
        self.sshKeygenURL = sshKeygenURL
        self.sshAddURL = sshAddURL
        self.sshURL = sshURL
        self.interactiveEnvironment = interactiveEnvironment
        self.batchEnvironment = batchEnvironment
    }

    func privateKeyExists(atPath path: String) -> Bool {
        fileManager.fileExists(atPath: path)
    }

    /// Step 1: `ssh-keygen -t ed25519 -f <path> -C <comment>`. The
    /// passphrase prompt (if any) is left entirely to ssh-keygen's own
    /// prompt, which is routed to the bundled askpass helper by
    /// `interactiveEnvironment` — this app process never sees or stores a
    /// passphrase.
    ///
    /// If a file already exists at `privateKeyPath`, this refuses to run
    /// unless `overwriteConfirmed` is `true` — the caller is expected to
    /// have shown an explicit confirmation dialog first, but this function
    /// re-checks rather than trusting that blindly, so an accidental
    /// overwrite without confirmation is structurally impossible. When
    /// overwrite is confirmed, `"y\n"` is fed on stdin because ssh-keygen's
    /// "Overwrite (y/n)?" prompt reads directly from stdin rather than
    /// through askpass (verified empirically — see WP3 implementation notes).
    func generateKey(
        privateKeyPath: String,
        comment: String,
        overwriteConfirmed: Bool
    ) async {
        let fileExists = fileManager.fileExists(atPath: privateKeyPath)
        guard !fileExists || overwriteConfirmed else {
            generateState = .failed(KeySetupError.overwriteNotConfirmed.localizedDescription)
            return
        }

        generateState = .running
        generateOutput = ""
        let request = SSHProcessRequest(
            executableURL: sshKeygenURL,
            arguments: KeySetupCommandBuilder.keygenArguments(privateKeyPath: privateKeyPath, comment: comment),
            environment: interactiveEnvironment,
            standardInput: fileExists ? Data("y\n".utf8) : nil,
            timeout: 180
        )

        do {
            let result = try await processClient.execute(request)
            generateOutput = result.combinedOutput
            if result.terminationStatus == 0 {
                generateState = .succeeded
                publicKeyPreview = try? readPublicKey(privateKeyPath: privateKeyPath)
            } else {
                generateState = .failed(failureMessage(result, fallback: "ssh-keygen çıkış kodu \(result.terminationStatus) döndürdü."))
            }
        } catch {
            generateState = .failed(error.localizedDescription)
        }
    }

    /// Step 2 (optional): `ssh-add <path>`. The path is the only argument —
    /// `ssh-add` itself opens and reads the key file; this app process
    /// never does.
    func addToAgent(privateKeyPath: String) async {
        agentAddState = .running
        agentAddOutput = ""
        let request = SSHProcessRequest(
            executableURL: sshAddURL,
            arguments: KeySetupCommandBuilder.sshAddArguments(privateKeyPath: privateKeyPath),
            environment: interactiveEnvironment,
            timeout: 60
        )

        do {
            let result = try await processClient.execute(request)
            agentAddOutput = result.combinedOutput
            agentAddState = result.terminationStatus == 0
                ? .succeeded
                : .failed(failureMessage(result, fallback: "ssh-add çıkış kodu \(result.terminationStatus) döndürdü."))
        } catch {
            agentAddState = .failed(error.localizedDescription)
        }
    }

    /// Reads ONLY `<privateKeyPath>.pub`. This is the sole file-content
    /// read in the entire wizard; the private key at `privateKeyPath`
    /// itself is never opened by this app.
    func readPublicKey(privateKeyPath: String) throws -> String {
        let publicKeyPath = privateKeyPath + ".pub"
        guard fileManager.fileExists(atPath: publicKeyPath) else {
            throw KeySetupError.publicKeyMissing
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: publicKeyPath))
        guard let text = String(data: data, encoding: .utf8) else {
            throw KeySetupError.publicKeyMissing
        }
        return text
    }

    /// Step 3: streams `publicKeyText` (already read from the `.pub` file
    /// by the caller/`readPublicKey`) to
    /// `ssh -- <alias> '<authorizedKeysRemoteScript>'` over stdin.
    /// The private key is not referenced anywhere in this call.
    func copyPublicKey(alias: String, publicKeyText: String) async {
        copyState = .running
        copyOutput = ""
        var text = publicKeyText
        if !text.hasSuffix("\n") { text += "\n" }

        let request = SSHProcessRequest(
            executableURL: sshURL,
            arguments: KeySetupCommandBuilder.copyArguments(alias: alias),
            environment: interactiveEnvironment,
            standardInput: Data(text.utf8),
            timeout: 180
        )

        do {
            let result = try await processClient.execute(request)
            copyOutput = result.combinedOutput
            copyState = result.terminationStatus == 0
                ? .succeeded
                : .failed(failureMessage(result, fallback: "Kopyalama çıkış kodu \(result.terminationStatus) döndürdü."))
        } catch {
            copyState = .failed(error.localizedDescription)
        }
    }

    /// Step 4 (best-effort verification): `ssh -o BatchMode=yes -- <alias>
    /// true`. Uses the plain batch environment (not interactive/askpass) —
    /// the point is to fail immediately if a password would still be
    /// required, not to prompt for one again.
    func verifyPasswordlessLogin(alias: String) async {
        verifyState = .running
        verifyOutput = ""
        let request = SSHProcessRequest(
            executableURL: sshURL,
            arguments: KeySetupCommandBuilder.verifyArguments(alias: alias),
            environment: batchEnvironment,
            timeout: 15
        )

        do {
            let result = try await processClient.execute(request)
            verifyOutput = result.combinedOutput
            verifyState = result.terminationStatus == 0
                ? .succeeded
                : .failed(failureMessage(result, fallback: "Doğrulama çıkış kodu \(result.terminationStatus) döndürdü."))
        } catch {
            verifyState = .failed(error.localizedDescription)
        }
    }

    private func failureMessage(_ result: SSHProcessResult, fallback: String) -> String {
        result.combinedOutput.isEmpty ? fallback : result.combinedOutput
    }
}
