import Foundation

/// Quotes a path for embedding as a single argument inside an OpenSSH `sftp` batch
/// script (as fed via `sftp -b -`).
///
/// sftp's batch/interactive command line is tokenized by `makeargv()` in OpenSSH's
/// `misc.c` using a small shell-like grammar: a token wrapped in double quotes may
/// contain whitespace, and inside it a backslash only has special meaning before a
/// `"` or another `\` (both are unescaped by dropping the leading backslash); every
/// other byte — including single quotes and multi-byte/unicode text — is copied
/// through unchanged. This matches the escaping already used ad hoc for `mkdir`/`put`/
/// `get` elsewhere in this app (backslash and double-quote only); this type centralizes
/// it and adds an explicit guard sftp itself cannot express.
///
/// sftp batch scripts are parsed **one command per line**, so a path containing `\n`
/// or `\r` cannot be represented at all: it would be read back as the start of a second,
/// unrelated command. Such paths are rejected rather than silently mangled.
enum SFTPBatchPathQuoting {
    /// Thrown when a path cannot be represented as a single sftp batch line.
    struct EmbeddedNewlineError: Error, Equatable {}

    /// Quotes `path` for use as one argument in an sftp batch command (e.g. `rename
    /// "<from>" "<to>"`).
    /// - Throws: `EmbeddedNewlineError` if `path` contains a line feed or carriage return.
    static func quote(_ path: String) throws -> String {
        guard !path.contains("\n"), !path.contains("\r") else {
            throw EmbeddedNewlineError()
        }
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
