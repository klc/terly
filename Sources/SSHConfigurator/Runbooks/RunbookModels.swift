import Foundation

/// A single command in a `Runbook`. `command` is the user's own raw shell
/// command text — the same thing they could type directly into a terminal.
/// Only the *parameter values* substituted into `{{name}}` placeholders are
/// ever quoted; see `RunbookCommandComposer`.
struct RunbookStep: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    var command: String
    /// When true, a non-zero exit status (or transport failure) for this step
    /// does not stop the remaining steps on the same host.
    var continueOnError: Bool

    init(id: UUID = UUID(), command: String = "", continueOnError: Bool = false) {
        self.id = id
        self.command = command
        self.continueOnError = continueOnError
    }
}

/// A named placeholder that can appear as `{{name}}` inside a step's command.
/// Only `defaultValue` is ever persisted — the resolved value used for an
/// actual run is supplied fresh at run time and never written to disk, so
/// secrets typed into the run sheet don't leak into the runbook JSON. Users
/// are warned in the editor not to put secrets in `defaultValue` either.
struct RunbookParameter: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    var name: String
    var defaultValue: String?

    init(id: UUID = UUID(), name: String = "", defaultValue: String? = nil) {
        self.id = id
        self.name = name
        self.defaultValue = defaultValue
    }
}

struct Runbook: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    var name: String
    var description: String
    var steps: [RunbookStep]
    var parameters: [RunbookParameter]
    /// User-declared "this is dangerous" flag. Combined with — but distinct
    /// from — the automatic pattern-based detection in
    /// `RunbookDangerDetector`; either one is enough to require the extra
    /// confirmation dialog before a run starts.
    var isDangerous: Bool

    init(
        id: UUID = UUID(),
        name: String = "",
        description: String = "",
        steps: [RunbookStep] = [],
        parameters: [RunbookParameter] = [],
        isDangerous: Bool = false
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.steps = steps
        self.parameters = parameters
        self.isDangerous = isDangerous
    }
}

/// Warns (never blocks) about steps whose command text looks destructive.
/// This is a best-effort substring match, not a security boundary — the
/// actual boundary is the mandatory preview + confirmation flow in the run
/// sheet.
enum RunbookDangerDetector {
    static let patterns: [String] = [
        "rm -rf",
        "mkfs",
        "dd if=",
        "shutdown",
        "reboot",
        "systemctl stop",
        "kill -9",
    ]

    static func isDangerous(_ command: String) -> Bool {
        patterns.contains { command.contains($0) }
    }
}

enum RunbookCommandComposerError: LocalizedError, Equatable, Sendable {
    case unknownPlaceholder(String)

    var errorDescription: String? {
        switch self {
        case let .unknownPlaceholder(name):
            return "Bilinmeyen parametre: {{\(name)}}"
        }
    }
}

/// Substitutes `{{name}}` placeholders in a step's command with resolved
/// parameter values. Every substituted value is single-quoted with
/// `StartupShellQuoter.singleQuoted` before being spliced in, so a value
/// containing spaces, single quotes, `;`, or `$(...)` can never break out of
/// its substitution point or get interpreted by the remote shell — it is
/// always inserted as one opaque shell word. The surrounding command text is
/// left untouched: it is the operator's own raw shell command.
///
/// An unknown placeholder (no matching entry in `values`) is always an
/// error — never silently substituted with an empty string.
enum RunbookCommandComposer {
    static func compose(step: RunbookStep, values: [String: String]) throws -> String {
        var result = ""
        var remainder = Substring(step.command)

        while let openRange = remainder.range(of: "{{") {
            result += remainder[remainder.startIndex ..< openRange.lowerBound]
            let afterOpen = remainder[openRange.upperBound...]

            guard let closeRange = afterOpen.range(of: "}}") else {
                // Unterminated placeholder: treat the rest as literal text.
                result += remainder[openRange.lowerBound...]
                remainder = ""
                break
            }

            let name = afterOpen[afterOpen.startIndex ..< closeRange.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            guard let value = values[name] else {
                throw RunbookCommandComposerError.unknownPlaceholder(name)
            }
            result += StartupShellQuoter.singleQuoted(value)
            remainder = afterOpen[closeRange.upperBound...]
        }

        result += remainder
        return result
    }
}
