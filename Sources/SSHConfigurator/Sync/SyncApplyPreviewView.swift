import SwiftUI

/// Full diff review for a pending sync apply — mirrors the app's existing
/// `ChangePreviewView` pattern (side-by-side monospaced columns) so this
/// looks and behaves like the config backup/restore preview the user
/// already knows, rather than introducing a second UI language for the
/// same kind of decision.
struct SyncApplyPreviewView: View {
    let diffs: [SyncFileDiff]
    let onClose: () -> Void

    @State private var selectedID: String?

    private var selectedDiff: SyncFileDiff? {
        diffs.first { $0.id == selectedID } ?? diffs.first
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Changes to Apply", onClose: onClose)

            Divider()

            HStack(spacing: 0) {
                List(diffs, selection: $selectedID) { diff in
                    Label(diff.relativePath, systemImage: diff.kind == .new ? "plus.circle" : "pencil.circle")
                        .tag(diff.relativePath as String?)
                }
                .frame(width: 220)
                .listStyle(.sidebar)

                Divider()

                if let selectedDiff {
                    HStack(spacing: 0) {
                        SyncDiffColumn(title: "Current (local)", source: selectedDiff.currentContent)
                        Divider()
                        SyncDiffColumn(title: "Incoming (remote)", source: selectedDiff.incomingContent)
                    }
                } else {
                    ContentUnavailableView(
                        "No Changes",
                        systemImage: "checkmark.circle",
                        description: Text("Nothing left to review.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear { selectedID = diffs.first?.id }
    }
}

private struct SyncDiffColumn: View {
    let title: String
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(12)

            Divider()

            ScrollView([.horizontal, .vertical]) {
                Text(source.isEmpty ? String(localized: "(empty / none)") : source)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
