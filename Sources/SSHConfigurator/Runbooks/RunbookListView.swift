import SwiftUI

struct RunbookListView: View {
    @ObservedObject var library: RunbookLibrary
    let availableConnections: [SSHConnectionTarget]

    @State private var editingRunbook: Runbook?
    @State private var runningRunbook: Runbook?
    @State private var pendingDeleteOffsets: IndexSet?

    var body: some View {
        VStack(spacing: 0) {
            if library.runbooks.isEmpty {
                ContentUnavailableView(
                    "No Runbooks Found",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Save the command sequences you want to run on multiple servers, step by step.")
                )
            } else {
                List {
                    ForEach(library.runbooks) { runbook in
                        RunbookRowView(
                            runbook: runbook,
                            onEdit: { editingRunbook = runbook },
                            onRun: { runningRunbook = runbook }
                        )
                    }
                    .onDelete { offsets in
                        pendingDeleteOffsets = offsets
                    }
                }
                .listStyle(.inset)
            }
        }
        .confirmationDialog(
            "Are you sure you want to delete this runbook?",
            isPresented: Binding(
                get: { pendingDeleteOffsets != nil },
                set: { if !$0 { pendingDeleteOffsets = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let offsets = pendingDeleteOffsets {
                    library.remove(at: offsets)
                }
                pendingDeleteOffsets = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteOffsets = nil
            }
        } message: {
            Text("This action cannot be undone.")
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: {
                    editingRunbook = Runbook()
                }) {
                    Label("Add Runbook", systemImage: "plus")
                }
            }
        }
        .sheet(item: $editingRunbook) { runbook in
            RunbookEditorView(
                runbook: runbook,
                onSave: { updated in
                    library.addOrUpdate(updated)
                    editingRunbook = nil
                },
                onDelete: library.runbooks.contains(where: { $0.id == runbook.id }) ? {
                    library.remove(runbook)
                    editingRunbook = nil
                } : nil,
                onCancel: {
                    editingRunbook = nil
                }
            )
        }
        .sheet(item: $runningRunbook) { runbook in
            RunbookRunSheet(
                runbook: runbook,
                availableConnections: availableConnections,
                onClose: { runningRunbook = nil }
            )
        }
        .navigationTitle("Runbooks")
    }
}

private struct RunbookRowView: View {
    let runbook: Runbook
    let onEdit: () -> Void
    let onRun: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(runbook.name.isEmpty ? String(localized: "(unnamed)") : runbook.name)
                        .font(.headline)
                    if runbook.isDangerous || runbook.steps.contains(where: { RunbookDangerDetector.isDangerous($0.command) }) {
                        Label("Dangerous", systemImage: "exclamationmark.triangle.fill")
                            .labelStyle(.iconOnly)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .help("This runbook is marked dangerous or contains a dangerous command pattern.")
                    }
                }
                Text(stepsSummaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()

            Button(action: onRun) {
                Label("Run", systemImage: "play.fill")
            }
            .buttonStyle(.borderless)
            .disabled(runbook.steps.isEmpty)
            .accessibilityLabel("Run the \(runbookDisplayName) runbook")

            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.plain)
            .help("Edit runbook")
            .accessibilityLabel("Edit the \(runbookDisplayName) runbook")
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onEdit)
    }

    private var runbookDisplayName: String {
        runbook.name.isEmpty ? String(localized: "(unnamed)") : runbook.name
    }

    private var stepsSummaryText: String {
        let stepsPart = String(localized: "\(runbook.steps.count) steps")
        guard !runbook.description.isEmpty else { return stepsPart }
        return "\(stepsPart) · \(runbook.description)"
    }
}
