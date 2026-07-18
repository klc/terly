import SwiftUI

struct RunbookListView: View {
    @ObservedObject var library: RunbookLibrary
    let availableConnections: [SSHConnectionTarget]
    let connectionGroups: [SSHConnectionGroup]

    @State private var editingRunbook: Runbook?
    @State private var runningRunbook: Runbook?
    @State private var pendingDeleteOffsets: IndexSet?

    var body: some View {
        VStack(spacing: 0) {
            if library.runbooks.isEmpty {
                ContentUnavailableView(
                    "Runbook Bulunamadı",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Birden çok sunucuda çalıştırmak istediğin komut dizilerini adım adım kaydet.")
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
            "Runbook'u silmek istediğinize emin misiniz?",
            isPresented: Binding(
                get: { pendingDeleteOffsets != nil },
                set: { if !$0 { pendingDeleteOffsets = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Sil", role: .destructive) {
                if let offsets = pendingDeleteOffsets {
                    library.remove(at: offsets)
                }
                pendingDeleteOffsets = nil
            }
            Button("Vazgeç", role: .cancel) {
                pendingDeleteOffsets = nil
            }
        } message: {
            Text("Bu işlem geri alınamaz.")
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: {
                    editingRunbook = Runbook()
                }) {
                    Label("Runbook Ekle", systemImage: "plus")
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
                connectionGroups: connectionGroups,
                onClose: { runningRunbook = nil }
            )
        }
        .navigationTitle("Runbook'lar")
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
                    Text(runbook.name.isEmpty ? "(isimsiz)" : runbook.name)
                        .font(.headline)
                    if runbook.isDangerous || runbook.steps.contains(where: { RunbookDangerDetector.isDangerous($0.command) }) {
                        Label("Tehlikeli", systemImage: "exclamationmark.triangle.fill")
                            .labelStyle(.iconOnly)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .help("Bu runbook tehlikeli olarak işaretli veya tehlikeli bir komut kalıbı içeriyor.")
                    }
                }
                Text("\(runbook.steps.count) adım" + (runbook.description.isEmpty ? "" : " · \(runbook.description)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()

            Button(action: onRun) {
                Label("Çalıştır", systemImage: "play.fill")
            }
            .buttonStyle(.borderless)
            .disabled(runbook.steps.isEmpty)
            .accessibilityLabel("\(runbookDisplayName) runbook'unu çalıştır")

            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.plain)
            .help("Runbook'u düzenle")
            .accessibilityLabel("\(runbookDisplayName) runbook'unu düzenle")
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onEdit)
    }

    private var runbookDisplayName: String {
        runbook.name.isEmpty ? "(isimsiz)" : runbook.name
    }
}
