import SwiftUI

struct SnippetListView: View {
    @ObservedObject var library: SnippetLibrary

    @State private var editingSnippet: Snippet?
    @State private var pendingDeleteOffsets: IndexSet?

    var body: some View {
        VStack(spacing: 0) {
            if library.snippets.isEmpty {
                ContentUnavailableView(
                    "No Snippets Found",
                    systemImage: "text.badge.plus",
                    description: Text("Save the commands or text you use often as key/value pairs. Search and insert them in the terminal with ⌘S.")
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
            "Are you sure you want to delete this snippet?",
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
                    editingSnippet = Snippet()
                }) {
                    Label("Add Snippet", systemImage: "plus")
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
        .navigationTitle("Snippets")
    }
}

struct SnippetRowView: View {
    let snippet: Snippet
    let onEdit: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(snippet.key.isEmpty ? String(localized: "(unnamed)") : snippet.key)
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
            .help("Edit snippet")
            .accessibilityLabel("Edit the \(snippetDisplayName) snippet")
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onEdit)
    }

    private var snippetDisplayName: String {
        snippet.key.isEmpty ? String(localized: "(unnamed)") : snippet.key
    }
}
