import Foundation

/// Phase C: pure (no SwiftUI) builder for the "open saved workspace" startup
/// preview — read-only, mirrors `SSHLaunchPlanBuilder.makePane`'s
/// override-wins-over-alias-profile resolution (see
/// `PaneStartupOverride.effectiveProfile`) without constructing any panes.
///
/// Deliberately narrower than the plain-connections preview built in
/// `ContentView.requestStartupLaunch`: it emits one item per pane whose
/// effective profile will actually auto-run at least one step
/// — not one item per pane in the workspace. `.suppressed` panes, panes whose
/// resolved profile is `nil` or has no steps, and local-terminal panes (which
/// never run a startup profile regardless of any override — see `makePane`)
/// never produce an item.
enum SavedWorkspaceStartupPreview {
    static func autoRunningItems(
        for workspace: SavedWorkspace,
        aliasStartupProfiles: [String: StartupFlowProfile]
    ) -> [StartupFlowLaunchPreviewItem] {
        workspace.sessions.flatMap { session in
            session.layout.panes.compactMap { pane -> StartupFlowLaunchPreviewItem? in
                guard !isLocalTerminalAlias(pane.alias) else { return nil }
                guard let profile = effectiveProfile(for: pane, aliasStartupProfiles: aliasStartupProfiles),
                      profile.automaticallyRun,
                      !profile.steps.isEmpty else {
                    return nil
                }
                return StartupFlowLaunchPreviewItem(
                    target: SSHConnectionTarget(hostID: session.hostID, alias: pane.alias),
                    profile: profile
                )
            }
        }
    }

    private static func effectiveProfile(
        for pane: SavedWorkspacePane,
        aliasStartupProfiles: [String: StartupFlowProfile]
    ) -> StartupFlowProfile? {
        if let override = pane.startup {
            return override.effectiveProfile(alias: pane.alias)
        }
        return aliasStartupProfiles[pane.alias]
    }

    private static func isLocalTerminalAlias(_ alias: String) -> Bool {
        alias == "Yerel Terminal" || alias == "Local Terminal"
    }
}
