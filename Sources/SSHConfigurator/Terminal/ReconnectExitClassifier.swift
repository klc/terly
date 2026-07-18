/// Decides whether a pane's process exit counts as an *unexpected*
/// disconnect (eligible for the WP7 reconnect band / auto-retry) or an
/// expected one the user caused directly.
///
/// Deliberately does not special-case the exit code: a clean `exit 0` typed
/// into the remote shell, or the remote side hanging up on its own, both
/// count as unexpected here — only an explicit user close (tab/pane close
/// button) is "expected". This matches WP7's plan: the status band already
/// requires the user to act (or opt into auto mode), so treating a plain
/// `exit` as "unexpected" is an acceptable, conservative default.
enum ReconnectExitClassifier {
    static func isUnexpectedDisconnect(paneStillPresent: Bool, userInitiatedClose: Bool) -> Bool {
        guard paneStillPresent else { return false }
        return !userInitiatedClose
    }
}
