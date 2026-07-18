import SwiftUI

/// (symbol, color) pairs shared by the status switches in `KeySetupWizardView`,
/// `SSHConnectionDiagnosticsView` (`DiagnosticCheckRow`), and `RunbookRunSheet`
/// (`RunbookHostRow`).
///
/// The three views track different domain enums (key-setup phase state,
/// diagnostic check status, runbook host result) with different case sets,
/// and their existing failure/pending symbols don't actually match each
/// other (e.g. `xmark.octagon.fill` vs `xmark.circle.fill` for failure).
/// This intentionally is not a single universal status enum — it only
/// covers the sub-cases that render identically across those views today;
/// everything that diverges (failure icon, pending icon, diagnostics'
/// warning/information) stays as a local, unchanged switch in each view.
enum StepStatusStyle {
    /// `checkmark.circle.fill` / green — identical in all three views.
    case succeeded
    /// `arrow.triangle.2.circlepath` / blue — identical in
    /// `KeySetupWizardView` and `RunbookRunSheet`.
    case running

    var symbolName: String {
        switch self {
        case .succeeded: "checkmark.circle.fill"
        case .running: "arrow.triangle.2.circlepath"
        }
    }

    var color: Color {
        switch self {
        case .succeeded: .green
        case .running: .blue
        }
    }
}
