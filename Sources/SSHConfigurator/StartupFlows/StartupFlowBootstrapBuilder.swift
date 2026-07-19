import Foundation

enum StartupFlowBuildError: LocalizedError, Equatable {
    case emptyUser(step: Int)
    case invalidUser(step: Int)
    case emptyDirectory(step: Int)
    case emptyCommand(step: Int)
    case changeUserMustBeFirst(step: Int)
    case multipleUserChanges(step: Int)

    var errorDescription: String? {
        switch self {
        case let .emptyUser(step):
            String(localized: "Step \(step + 1): enter a username.")
        case let .invalidUser(step):
            String(localized: "Step \(step + 1): the username isn't safe to use with sudo.")
        case let .emptyDirectory(step):
            String(localized: "Step \(step + 1): enter a remote directory path.")
        case let .emptyCommand(step):
            String(localized: "Step \(step + 1): enter the command to run.")
        case let .changeUserMustBeFirst(step):
            String(localized: "Step \(step + 1): changing the user can only be the first step in the flow.")
        case let .multipleUserChanges(step):
            String(localized: "Step \(step + 1) isn't supported: the user can only be changed once in a flow.")
        }
    }
}

struct StartupFlowBootstrapBuilder: Sendable {
    func build(
        profile: StartupFlowProfile,
        runID: UUID = UUID()
    ) throws -> StartupFlowExecution {
        try validate(profile.steps)

        let markerPrefix = "SSHCFG_STARTUP_" + runID.uuidString.replacingOccurrences(of: "-", with: "")
        let steps = profile.steps
        let userStep = steps.first?.kind == .changeUser ? steps.first : nil
        let remainingStartIndex = userStep == nil ? 0 : 1
        let remainingSteps = Array(steps.dropFirst(remainingStartIndex))
        let innerScript = makeScript(
            steps: remainingSteps,
            startingAt: remainingStartIndex,
            markerPrefix: markerPrefix,
            emitsRunningMarker: userStep == nil,
            normalizesInteractiveShellExit: userStep != nil
        )

        let script: String
        if let userStep {
            let quotedUser = StartupShellQuoter.singleQuoted(userStep.value)
            let quotedInner = StartupShellQuoter.singleQuoted(innerScript)
            let failure = markerCommand(
                prefix: markerPrefix,
                state: "failed",
                values: ["0", "\"$startup_code\""]
            )
            script = [
                markerCommand(prefix: markerPrefix, state: "running", values: ["0"]),
                "startup_user=$(id -un 2>/dev/null || true)",
                "if [ \"$startup_user\" = \(quotedUser) ]; then /bin/sh -lc \(quotedInner); else sudo -iu \(quotedUser) -- /bin/sh -lc \(quotedInner); fi",
                "startup_code=$?",
                "if [ \"$startup_code\" -ne 0 ]; then \(failure); exec \"${SHELL:-/bin/sh}\" -l; fi",
            ].joined(separator: "; ")
        } else {
            script = innerScript
        }
        let command = "/bin/sh -lc \(StartupShellQuoter.singleQuoted(script))"

        return StartupFlowExecution(
            profileID: profile.id,
            command: command,
            markerPrefix: markerPrefix,
            stepSummaries: steps.map(\.summary)
        )
    }

    func validate(_ steps: [StartupFlowStep]) throws {
        var userChangeCount = 0
        for (index, step) in steps.enumerated() {
            let value = step.value.trimmingCharacters(in: .whitespacesAndNewlines)
            switch step.kind {
            case .changeUser:
                userChangeCount += 1
                guard !value.isEmpty else { throw StartupFlowBuildError.emptyUser(step: index) }
                guard Self.isValidUser(value) else { throw StartupFlowBuildError.invalidUser(step: index) }
                guard userChangeCount == 1 else {
                    throw StartupFlowBuildError.multipleUserChanges(step: index)
                }
                guard index == 0 else {
                    throw StartupFlowBuildError.changeUserMustBeFirst(step: index)
                }
            case .changeDirectory:
                guard !value.isEmpty else {
                    throw StartupFlowBuildError.emptyDirectory(step: index)
                }
            case .runCommand:
                guard !value.isEmpty else {
                    throw StartupFlowBuildError.emptyCommand(step: index)
                }
            }
        }
    }

    static func isValidUser(_ user: String) -> Bool {
        guard let expression = try? NSRegularExpression(
            pattern: "^[A-Za-z_][A-Za-z0-9_.-]*[$]?$"
        ) else { return false }
        let range = NSRange(user.startIndex..., in: user)
        return expression.firstMatch(in: user, range: range)?.range == range
    }

    private func makeScript(
        steps: [StartupFlowStep],
        startingAt startIndex: Int,
        markerPrefix: String,
        emitsRunningMarker: Bool,
        normalizesInteractiveShellExit: Bool
    ) -> String {
        var fragments: [String] = []
        if emitsRunningMarker {
            fragments.append(markerCommand(prefix: markerPrefix, state: "running", values: []))
        }

        for (offset, step) in steps.enumerated() {
            let index = startIndex + offset
            fragments.append(markerCommand(prefix: markerPrefix, state: "running", values: ["\(index)"]))
            switch step.kind {
            case .changeUser:
                // Validation prevents this branch from being reachable.
                continue
            case .changeDirectory:
                let path = StartupShellQuoter.singleQuoted(
                    step.value.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                fragments.append("cd -- \(path) || startup_fail \(index) $?")
            case .runCommand:
                let command = step.value.trimmingCharacters(in: .whitespacesAndNewlines)
                let evaluatedCommand = "eval \(StartupShellQuoter.singleQuoted(command))"
                if step.stopOnFailure {
                    fragments.append("\(evaluatedCommand) || startup_fail \(index) $?")
                } else {
                    fragments.append("\(evaluatedCommand) || true")
                }
            }
        }

        fragments.insert(
            failureFunction(
                prefix: markerPrefix,
                normalizesInteractiveShellExit: normalizesInteractiveShellExit
            ),
            at: 0
        )
        fragments.append(markerCommand(prefix: markerPrefix, state: "completed", values: []))
        fragments.append(interactiveShellCommand(normalizeExit: normalizesInteractiveShellExit))
        return fragments.joined(separator: "; ")
    }

    private func failureFunction(
        prefix: String,
        normalizesInteractiveShellExit: Bool
    ) -> String {
        let marker = markerCommand(
            prefix: prefix,
            state: "failed",
            values: ["\"$1\"", "\"$2\""]
        )
        return "startup_fail() { \(marker); \(interactiveShellCommand(normalizeExit: normalizesInteractiveShellExit)); }"
    }

    private func interactiveShellCommand(normalizeExit: Bool) -> String {
        normalizeExit
            ? "\"${SHELL:-/bin/sh}\" -l; exit 0"
            : "exec \"${SHELL:-/bin/sh}\" -l"
    }

    private func markerCommand(prefix: String, state: String, values: [String]) -> String {
        let staticPayload = ([prefix, state] + values.map { value in
            value.hasPrefix("\"") ? "%s" : value
        }).joined(separator: "|")
        let dynamicValues = values.filter { $0.hasPrefix("\"") }
        let arguments = dynamicValues.isEmpty ? "" : " " + dynamicValues.joined(separator: " ")
        return "printf '\\036\(staticPayload)\\037'\(arguments)"
    }
}

enum StartupShellQuoter {
    static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
