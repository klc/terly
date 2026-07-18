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
                    TextField("Anahtar", text: $snippet.key, prompt: Text("Örn. release"))
                        .editorFieldStyle()
                }

                Section("Value") {
                    TextEditor(text: $snippet.value)
                        .font(.body.monospaced())
                        .frame(minHeight: 140)
                    Toggle("Gizli değer (Keychain'de saklanır)", isOn: $snippet.isSecret)
                    if snippet.isSecret {
                        Text("Bu değer diskteki JSON dosyasına yazılmaz; sistem Keychain'inde saklanır.")
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
                                Text("Snippet'i Sil")
                                Spacer()
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(trimmedKey.isEmpty ? "Yeni Snippet" : "Snippet Düzenle")
            .confirmationDialog(
                "Snippet'i silmek istediğinize emin misiniz?",
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Sil", role: .destructive) {
                    onDelete?()
                }
                Button("Vazgeç", role: .cancel) {}
            } message: {
                Text("Bu işlem geri alınamaz.")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("İptal", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Kaydet") {
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
