import SwiftUI

struct SnippetEditorView: View {
    let onSave: (Snippet) -> Void
    let onDelete: (() -> Void)?
    let onCancel: () -> Void

    @State private var snippet: Snippet
    @State private var showingDeleteConfirmation = false

    init(
        snippet: Snippet,
        onSave: @escaping (Snippet) -> Void,
        onDelete: (() -> Void)? = nil,
        onCancel: @escaping () -> Void
    ) {
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
        self._snippet = State(initialValue: snippet)
    }

    private var trimmedKey: String {
        snippet.key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Key") {
                    TextField("Key", text: $snippet.key, prompt: Text("e.g. release"))
                        .editorFieldStyle()
                }

                Section("Value") {
                    TextEditor(text: $snippet.value)
                        .font(.body.monospaced())
                        .frame(minHeight: 140)
                    Toggle("Secret value (stored in Keychain)", isOn: $snippet.isSecret)
                    if snippet.isSecret {
                        Text("This value isn't written to the JSON file on disk; it's stored in the system Keychain.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if onDelete != nil {
                    Section {
                        Button(role: .destructive, action: {
                            showingDeleteConfirmation = true
                        }) {
                            HStack {
                                Spacer()
                                Text("Delete Snippet")
                                Spacer()
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(trimmedKey.isEmpty ? "New Snippet" : "Edit Snippet")
            .confirmationDialog(
                "Are you sure you want to delete this snippet?",
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    onDelete?()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This action cannot be undone.")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var trimmed = snippet
                        trimmed.key = trimmedKey
                        onSave(trimmed)
                    }
                    .disabled(trimmedKey.isEmpty)
                }
            }
        }
        .frame(minWidth: 460, minHeight: 420)
    }
}
