import Foundation

enum TunnelType: String, Codable, Equatable, CaseIterable, Identifiable, Sendable {
    case local
    case remote
    case dynamic
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .local: return "Local Forward (-L)"
        case .remote: return "Remote Forward (-R)"
        case .dynamic: return "Dynamic Forward (-D)"
        }
    }
}

enum TunnelStatus: Equatable, Sendable {
    case idle
    case connecting
    case active
    case reconnecting
    case failed(String)
}

struct TunnelDefinition: Codable, Equatable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var description: String
    var type: TunnelType
    var localBindAddress: String
    var localPort: Int?
    var remoteBindAddress: String
    var remotePort: Int?
    var targetHostAlias: String
    var isEnabled: Bool
    var autoConnect: Bool

    var validationError: String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "Tünel adı gerekli." }
        guard !targetHostAlias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Hedef host gerekli."
        }
        guard Self.isValidPort(localPort) else { return "Yerel port 1 ile 65535 arasında olmalı." }

        guard type != .dynamic else { return nil }
        guard !remoteBindAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Uzak host gerekli."
        }
        guard Self.isValidPort(remotePort) else { return "Uzak port 1 ile 65535 arasında olmalı." }
        return nil
    }

    private static func isValidPort(_ port: Int?) -> Bool {
        guard let port else { return false }
        return (1 ... 65_535).contains(port)
    }
    
    init(
        id: UUID = UUID(),
        name: String = "",
        description: String = "",
        type: TunnelType = .local,
        localBindAddress: String = "127.0.0.1",
        localPort: Int? = nil,
        remoteBindAddress: String = "",
        remotePort: Int? = nil,
        targetHostAlias: String = "",
        isEnabled: Bool = true,
        autoConnect: Bool = false
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.type = type
        self.localBindAddress = localBindAddress
        self.localPort = localPort
        self.remoteBindAddress = remoteBindAddress
        self.remotePort = remotePort
        self.targetHostAlias = targetHostAlias
        self.isEnabled = isEnabled
        self.autoConnect = autoConnect
    }
}
