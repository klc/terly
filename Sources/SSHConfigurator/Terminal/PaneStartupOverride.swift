import Foundation

/// Phase A: a per-pane override that WINS over the alias-keyed startup
/// profile map. `nil` (the pane's `startupOverride` being absent) preserves
/// today's alias-keyed behavior byte-for-byte — this type only ever changes
/// behavior when a pane explicitly carries one.
enum PaneStartupOverride: Codable, Equatable, Sendable {
    /// Free-form command, runs automatically (as if it were the sole step of
    /// a synthetic auto-run profile).
    case command(String)
    /// Embedded snapshot copy of a flow — normalized (alias + automatic-run)
    /// at the point of use, mirroring `ContentView.startupProfiles(for:group:connections:)`.
    case flow(StartupFlowProfile)
    /// Explicitly no startup, even if the host has an auto-run flow.
    case suppressed

    private enum CodingKeys: String, CodingKey {
        case type
        case command
        case flow
    }

    private enum Kind: String, Codable {
        case command
        case flow
        case suppressed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(Kind.self, forKey: .type)
        switch type {
        case .command:
            let value = try container.decode(String.self, forKey: .command)
            self = .command(value)
        case .flow:
            let profile = try container.decode(StartupFlowProfile.self, forKey: .flow)
            self = .flow(profile)
        case .suppressed:
            self = .suppressed
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .command(value):
            try container.encode(Kind.command, forKey: .type)
            try container.encode(value, forKey: .command)
        case let .flow(profile):
            try container.encode(Kind.flow, forKey: .type)
            try container.encode(profile, forKey: .flow)
        case .suppressed:
            try container.encode(Kind.suppressed, forKey: .type)
        }
    }

    /// The startup profile this override yields for a pane connecting to
    /// `alias` — `nil` means "no automatic startup", which `makePane` treats
    /// exactly like an absent alias-keyed profile.
    func effectiveProfile(alias: String) -> StartupFlowProfile? {
        switch self {
        case .suppressed:
            return nil

        case let .command(command):
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return StartupFlowProfile(
                alias: alias,
                automaticallyRun: true,
                steps: [.runCommand(trimmed)]
            )

        case let .flow(profile):
            var normalized = profile
            normalized.alias = alias
            normalized.automaticallyRun = true
            return normalized
        }
    }
}
