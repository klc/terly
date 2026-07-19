import CryptoKit
import Foundation

enum StartupFlowStepKind: String, Codable, CaseIterable, Sendable {
    case changeUser
    case changeDirectory
    case runCommand

    var label: String {
        switch self {
        case .changeUser: String(localized: "Change user")
        case .changeDirectory: String(localized: "Change directory")
        case .runCommand: String(localized: "Run command")
        }
    }
}

struct StartupFlowStep: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var kind: StartupFlowStepKind
    var value: String
    var stopOnFailure: Bool

    init(
        id: UUID = UUID(),
        kind: StartupFlowStepKind,
        value: String = "",
        stopOnFailure: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.value = value
        self.stopOnFailure = stopOnFailure
    }

    static func changeUser(_ user: String, id: UUID = UUID()) -> Self {
        Self(id: id, kind: .changeUser, value: user)
    }

    static func changeDirectory(_ path: String, id: UUID = UUID()) -> Self {
        Self(id: id, kind: .changeDirectory, value: path)
    }

    static func runCommand(
        _ command: String,
        stopOnFailure: Bool = true,
        id: UUID = UUID()
    ) -> Self {
        Self(
            id: id,
            kind: .runCommand,
            value: command,
            stopOnFailure: stopOnFailure
        )
    }

    var summary: String {
        switch kind {
        case .changeUser:
            "sudo -iu \(value)"
        case .changeDirectory:
            "cd \(value)"
        case .runCommand:
            value
        }
    }
}

struct StartupFlowProfile: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var alias: String
    var automaticallyRun: Bool
    var steps: [StartupFlowStep]

    init(
        id: UUID = UUID(),
        alias: String,
        automaticallyRun: Bool = false,
        steps: [StartupFlowStep] = []
    ) {
        self.id = id
        self.alias = alias
        self.automaticallyRun = automaticallyRun
        self.steps = steps
    }
}

enum StartupFlowProfileStatus: Equatable, Sendable {
    case linked
    case orphaned
}

struct StartupFlowRecord: Equatable, Identifiable, Sendable {
    var profile: StartupFlowProfile
    var status: StartupFlowProfileStatus

    var id: UUID { profile.id }
}

enum StartupFlowRunState: Equatable, Sendable {
    case ready
    case skipped
    case running(stepIndex: Int?)
    case completed
    case failed(stepIndex: Int, message: String)
}

struct StartupFlowExecution: Equatable, Sendable {
    let profileID: UUID
    let command: String
    let markerPrefix: String
    let stepSummaries: [String]
}

struct StartupFlowPendingChange: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let profileID: UUID
    let before: StartupFlowProfile?
    let after: StartupFlowProfile
    let expectedConfigFingerprint: String

    init(
        id: UUID = UUID(),
        before: StartupFlowProfile?,
        after: StartupFlowProfile,
        expectedConfigFingerprint: String
    ) {
        self.id = id
        profileID = after.id
        self.before = before
        self.after = after
        self.expectedConfigFingerprint = expectedConfigFingerprint
    }
}

struct StartupFlowMetadataState: Codable, Equatable, Sendable {
    var version: Int
    var profiles: [StartupFlowProfile]
    var pendingChanges: [StartupFlowPendingChange]

    init(
        version: Int = 2,
        profiles: [StartupFlowProfile] = [],
        pendingChanges: [StartupFlowPendingChange] = []
    ) {
        self.version = version
        self.profiles = profiles
        self.pendingChanges = pendingChanges
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case profiles
        case pendingChanges
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        profiles = try container.decodeIfPresent(
            [StartupFlowProfile].self,
            forKey: .profiles
        ) ?? []
        pendingChanges = try container.decodeIfPresent(
            [StartupFlowPendingChange].self,
            forKey: .pendingChanges
        ) ?? []
    }
}

struct StartupFlowReconciliationContext: Equatable, Sendable {
    let workingConfigFingerprint: String
    let persistedConfigFingerprint: String
    let workingAliases: Set<String>
    let persistedAliases: Set<String>

    init(
        workingSource: String,
        persistedSource: String,
        workingAliases: Set<String>,
        persistedAliases: Set<String>
    ) {
        workingConfigFingerprint = StartupFlowConfigFingerprint.make(workingSource)
        persistedConfigFingerprint = StartupFlowConfigFingerprint.make(persistedSource)
        self.workingAliases = workingAliases
        self.persistedAliases = persistedAliases
    }
}

enum StartupFlowPendingDecision: Equatable, Sendable {
    case keep
    case commit
    case rollback
}

enum StartupFlowReconciliationPolicy {
    static func decision(
        for change: StartupFlowPendingChange,
        context: StartupFlowReconciliationContext
    ) -> StartupFlowPendingDecision {
        // Fingerprint transaction'ın hangi config düzenlemesiyle üretildiğini kaydeder;
        // ilgisiz satır değişiklikleri full-source hash'i değiştirebildiği için yaşam
        // döngüsünde somut hedef alias varlığı otoritedir.
        if context.persistedAliases.contains(change.after.alias) {
            return .commit
        }
        if context.workingAliases.contains(change.after.alias) {
            return .keep
        }
        return .rollback
    }
}

enum StartupFlowConfigFingerprint {
    static func make(_ source: String) -> String {
        SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum StartupFlowEditingAvailability: Equatable, Sendable {
    case available(alias: String)
    case unavailable(message: String)
}

enum StartupFlowEditingPolicy {
    static func availability(for aliases: [String]) -> StartupFlowEditingAvailability {
        if let alias = aliases.first(where: SSHLaunchPlanBuilder.isConcreteAlias) {
            return .available(alias: alias)
        }
        return .unavailable(
            message: String(localized: "A startup flow can only be linked to a concrete Host alias. Add a concrete alias first for a wildcard or negated pattern.")
        )
    }
}

enum StartupFlowMarkerEvent: Equatable, Sendable {
    case running(stepIndex: Int?)
    case completed
    case failed(stepIndex: Int, exitCode: Int32)
}

struct StartupFlowSecretDetector: Sendable {
    private static let suspiciousTerms = [
        "password", "passwd", "token", "secret", "api_key", "api-key",
        "authorization", "bearer", "private_key", "private-key",
    ]

    func mayContainSecret(_ profile: StartupFlowProfile) -> Bool {
        profile.steps
            .filter { $0.kind == .runCommand }
            .map { $0.value.lowercased() }
            .contains { command in
                Self.suspiciousTerms.contains { command.contains($0) }
            }
    }
}
