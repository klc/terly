import Foundation

/// Resolves the on-disk location of the bundled `terly-askpass.sh` helper
/// script (see `terly-askpass.sh` in this directory for what it does and
/// why). Resolution happens lazily via `Bundle.main` at call time so this
/// works no matter where the app is installed.
///
/// Under `swift test`/SwiftPM the running "app" is a plain executable with
/// no `Contents/Resources`, so `Bundle.main` legitimately has nothing to
/// find here — callers treat a `nil` result as "interactive auth
/// unavailable" and fall back to non-interactive behaviour rather than
/// crashing.
enum AskpassHelperLocator {
    static let resourceName = "terly-askpass"
    static let resourceExtension = "sh"

    static func helperURL(bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: resourceName, withExtension: resourceExtension)
    }
}
