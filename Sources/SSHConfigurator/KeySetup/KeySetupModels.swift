import Foundation

/// Pure, side-effect-free helpers for the key setup wizard (WP3): deriving a
/// default private key path from a host alias, and building the exact argv
/// arrays passed to `ssh-keygen` / `ssh-add` / `ssh`. Kept separate from
/// `KeySetupEngine` so every argument list is directly unit-testable without
/// touching the filesystem or spawning a process.
enum KeySetupPathDeriver {
    /// Reduces an arbitrary Host alias to characters that are safe to embed
    /// in a filename: letters, digits, `.`, `-`, `_`. Everything else
    /// (including `/`, spaces, and shell metacharacters) becomes `_`, so the
    /// derived path can never escape `~/.ssh` or be misinterpreted by a
    /// shell — even though it is always passed as a single argv element and
    /// never through a shell in the first place.
    static func sanitizedFilenameComponent(for alias: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let sanitized = String(alias.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "_"
        })
        return sanitized.isEmpty ? "host" : sanitized
    }

    /// Default suggested private key path for a given alias:
    /// `~/.ssh/id_ed25519_<sanitized-alias>`. The user can freely edit this
    /// in the wizard before generation.
    static func defaultPrivateKeyPath(
        alias: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        let component = sanitizedFilenameComponent(for: alias)
        return homeDirectory
            .appendingPathComponent(".ssh")
            .appendingPathComponent("id_ed25519_\(component)")
            .path
    }

    /// Default `-C` comment: `<local user>@<alias>`.
    static func defaultComment(alias: String, userName: String = NSUserName()) -> String {
        "\(userName)@\(alias)"
    }
}

/// Builds the exact argv arrays for every process the wizard runs. No
/// string is ever assembled by joining through a local shell — each element
/// here is one argv entry.
enum KeySetupCommandBuilder {
    /// Fixed remote script that installs a public key into
    /// `~/.ssh/authorized_keys`. This string never has user input spliced
    /// into it — the public key content is streamed to the remote `cat`
    /// over stdin, not interpolated into the script, and the alias is a
    /// separate argv element (after `--`), not part of this script at all.
    /// Because the script itself is a fixed literal, no quoting of a
    /// variable value is needed here (contrast with `StartupShellQuoter`,
    /// which quotes *values* spliced into a script).
    static let authorizedKeysRemoteScript =
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"

    static func keygenArguments(privateKeyPath: String, comment: String) -> [String] {
        ["-t", "ed25519", "-f", privateKeyPath, "-C", comment]
    }

    static func sshAddArguments(privateKeyPath: String) -> [String] {
        [privateKeyPath]
    }

    /// The script is passed as ONE argv element. ssh joins the remote
    /// command words with spaces and the remote shell re-parses the result,
    /// so a local `["sh", "-c", script]` split would arrive remotely as
    /// `sh -c mkdir -p ~/.ssh && …` — `sh -c` would take only `mkdir` and
    /// the `&&` chain would escape to the outer shell and fail. As a single
    /// element the user's remote shell executes the whole chain itself.
    static func copyArguments(alias: String) -> [String] {
        ["--", alias, authorizedKeysRemoteScript]
    }

    static func verifyArguments(alias: String) -> [String] {
        ["-o", "BatchMode=yes", "--", alias, "true"]
    }
}

enum KeySetupError: LocalizedError, Equatable {
    case invalidAlias
    case overwriteNotConfirmed
    case publicKeyMissing

    var errorDescription: String? {
        switch self {
        case .invalidAlias:
            return "Somut bir Host alias'ı gerekli."
        case .overwriteNotConfirmed:
            return "Bu yolda zaten bir anahtar var. Üzerine yazmadan önce açıkça onaylaman gerekiyor."
        case .publicKeyMissing:
            return "Public key dosyası (.pub) bulunamadı veya okunamadı."
        }
    }
}
