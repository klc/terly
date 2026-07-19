import SwiftUI

/// Position of the current search match among all matches. `index` is 1-based and
/// is 0 when there is no current match.
struct TerminalSearchSummary: Equatable {
    var index: Int
    var total: Int

    static let empty = TerminalSearchSummary(index: 0, total: 0)
}

enum TerminalFindCommand {
    case open
    case next
    case previous
}

@MainActor
protocol EmbeddedTerminalEngine {
    var identifier: TerminalEngineIdentifier { get }

    func makeSurface(
        for pane: TerminalPane,
        synchronizedPaneIDs: Set<TerminalPane.ID>,
        isActive: Bool,
        isVisible: Bool,
        isVisibleInLayout: Bool,
        onStartupEvent: @escaping @MainActor @Sendable (StartupFlowMarkerEvent) -> Void,
        onFindCommand: @escaping @MainActor @Sendable (TerminalFindCommand) -> Void,
        onActivate: @escaping @MainActor @Sendable () -> Void,
        onProcessExit: @escaping @MainActor @Sendable (Int32?) -> Void
    ) -> AnyView

    func send(_ bytes: [UInt8], to paneID: TerminalPane.ID) -> Bool

    @discardableResult
    func findNext(_ term: String, in paneID: TerminalPane.ID) -> TerminalSearchSummary?

    @discardableResult
    func findPrevious(_ term: String, in paneID: TerminalPane.ID) -> TerminalSearchSummary?

    func clearSearch(in paneID: TerminalPane.ID)

    func focusTerminal(_ paneID: TerminalPane.ID)
}
