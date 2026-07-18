import Foundation

public enum SSHConfigValidationResult: Sendable, Equatable {
    case valid
    case requiresMatchExecConfirmation
    case invalid(message: String)
}

public struct SSHConfigValidator: Sendable {
    public init() {}

    /// `ssh -G` does not open a network connection, but parsing a config with
    /// `Match exec` may execute the configured local command. Callers must ask
    /// for explicit confirmation before opting into that behavior.
    public func validate(
        _ document: SSHConfigDocument,
        forHost host: String,
        allowingMatchExec: Bool = false
    ) -> SSHConfigValidationResult {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .invalid(message: "Doğrulama için somut bir Host adı gerekli.")
        }
        guard allowingMatchExec || !document.containsMatchExec else {
            return .requiresMatchExecConfirmation
        }

        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("ssh-configurator-validation-\(UUID().uuidString)", isDirectory: true)
        let configURL = directory.appendingPathComponent("config")

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try document.source.write(to: configURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
            defer { try? fileManager.removeItem(at: directory) }

            let process = Process()
            let errorPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ["-F", configURL.path, "-G", host]
            process.standardError = errorPipe
            process.standardOutput = Pipe()

            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let message = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return .invalid(message: message.isEmpty ? "OpenSSH config doğrulaması başarısız oldu." : message)
            }

            return .valid
        } catch {
            return .invalid(message: error.localizedDescription)
        }
    }
}
