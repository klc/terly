import SwiftUI

struct SnippetListView: View {
    @ObservedObject var library: SnippetLibrary

    @State private var editingSnippet: Snippet?
    @State private var pendingDeleteOffsets: IndexSet?

    var body: some View {
        VStack(spacing: 0) {
            if library.snippets.isEmpty {
                ContentUnavailableView(
                    "Snippet Bulunamadı",
                    systemImage: "text.badge.plus",
                    description: Text("Sık kullandığın komut veya metinleri key/value olarak kaydet. Terminalde ⌘S ile ara ve ekle.")
                )
            } else {
                List {
                    ForEach(library.snippets) { snippet in
                        SnippetRowView(snippet: snippet, onEdit: { editingSnippet = snippet })
                    }
                    .onDelete { offsets in
                        pendingDeleteOffsets = offsets
                    }
                }
                .listStyle(.inset)
            }
        }
        .confirmationDialog(
            "Snippet'i silmek istediğinize emin misiniz?",
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
                    editingSnippet = Snippet()
                }) {
                    Label("Snippet Ekle", systemImage: "plus")
                }
            }
        }
        .sheet(item: $editingSnippet) { snippet in
            SnippetEditorView(
                snippet: snippet,
                onSave: { updated in
                    library.addOrUpdate(updated)
                    editingSnippet = nil
                },
                onDelete: library.snippets.contains(where: { $0.id == snippet.id }) ? {
                    library.remove(snippet)
                    editingSnippet = nil
                } : nil,
                onCancel: {
                    editingSnippet = nil
                }
            )
        }
        .navigationTitle("Snippet'ler")
    }
}

struct SnippetRowView: View {
    let snippet: Snippet
    let onEdit: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(snippet.key.isEmpty ? "(isimsiz)" : snippet.key)
                        .font(.headline)
                    if snippet.isSecret {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(snippet.isSecret ? "••••••••" : snippet.value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()

            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.plain)
            .help("Snippet'i düzenle")
            .accessibilityLabel("\(snippetDisplayName) snippet'ini düzenle")
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onEdit)
    }

    private var snippetDisplayName: String {
        snippet.key.isEmpty ? "(isimsiz)" : snippet.key
    }
}
