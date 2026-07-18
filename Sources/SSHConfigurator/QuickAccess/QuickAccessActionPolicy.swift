import Foundation

enum QuickAccessAction: String, CaseIterable, Equatable, Sendable {
    case connect
    case settings
    case transfer
    case diagnostics
}

enum QuickAccessRouteTarget: Equatable, Sendable {
    case host(hostID: Int, alias: String)
    case group(id: UUID)
}

struct QuickAccessRoute: Equatable, Sendable {
    let action: QuickAccessAction
    let target: QuickAccessRouteTarget
}

enum QuickAccessActionPolicy {
    static func availableActions(for entry: QuickAccessEntry) -> [QuickAccessAction] {
        switch entry.kind {
        case .host:
            return [.connect, .settings, .transfer, .diagnostics]
        case .group:
            return [.connect, .settings]
        }
    }

    static func route(
        action: QuickAccessAction,
        entry: QuickAccessEntry
    ) -> QuickAccessRoute? {
        guard availableActions(for: entry).contains(action) else { return nil }
        switch entry.kind {
        case .host:
            guard let hostID = entry.hostID, let alias = entry.alias else { return nil }
            return QuickAccessRoute(action: action, target: .host(hostID: hostID, alias: alias))
        case .group:
            guard let groupID = entry.groupID else { return nil }
            return QuickAccessRoute(action: action, target: .group(id: groupID))
        }
    }
}

enum QuickAccessKeyboardKey: Equatable, Sendable {
    case character(String)
    case up
    case down
    case enter
    case escape
}

struct QuickAccessKeyboardInput: Equatable, Sendable {
    let key: QuickAccessKeyboardKey
    let commandModifier: Bool
}

enum QuickAccessKeyboardCommand: Equatable, Sendable {
    case present
    case moveSelection(Int)
    case performPrimaryAction
    case dismiss
}

enum QuickAccessKeyboardPolicy {
    static func command(for input: QuickAccessKeyboardInput) -> QuickAccessKeyboardCommand? {
        switch (input.key, input.commandModifier) {
        case let (.character(value), true) where value.lowercased() == "k":
            return .present
        case (.up, false):
            return .moveSelection(-1)
        case (.down, false):
            return .moveSelection(1)
        case (.enter, false):
            return .performPrimaryAction
        case (.escape, false):
            return .dismiss
        default:
            return nil
        }
    }
}
