import SwiftUI

struct RunbookEditorView: View {
    let onSave: (Runbook) -> Void
    let onDelete: (() -> Void)?
    let onCancel: () -> Void

    @State private var runbook: Runbook
    @State private var showingDeleteConfirmation = false

    init(
        runbook: Runbook,
        onSave: @escaping (Runbook) -> Void,
        onDelete: (() -> Void)? = nil,
        onCancel: @escaping () -> Void
    ) {
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
        self._runbook = State(initialValue: runbook)
    }

    private var trimmedName: String {
        runbook.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Runbook") {
                    TextField("Ad", text: $runbook.name)
                        .editorFieldStyle()
                    TextField("Açıklama (isteğe bağlı)", text: $runbook.description, axis: .vertical)
                        .lineLimit(1 ... 3)
                        .editorFieldStyle()
                    Toggle("Tehlikeli olarak işaretle", isOn: $runbook.isDangerous)
                    Text("İşaretlenmemiş olsa da `rm -rf`, `shutdown` gibi tehlikeli komut kalıpları içeren adımlar çalıştırma önizlemesinde otomatik olarak uyarılır.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Adımlar") {
                    if runbook.steps.isEmpty {
                        Text("Henüz adım eklenmedi.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach($runbook.steps) { $step in
                            RunbookStepEditor(
                                step: $step,
                                onMoveUp: { move(step.id, offset: -1) },
                                onMoveDown: { move(step.id, offset: 1) },
                                onDelete: { removeStep(step.id) }
                            )
                        }
                        .onMove(perform: moveSteps)
                    }

                    Button {
                        runbook.steps.append(RunbookStep())
                    } label: {
                        Label("Adım ekle", systemImage: "plus")
                    }
                }

                Section("Parametreler") {
                    if runbook.parameters.isEmpty {
                        Text("Komutlarda `{{ad}}` şeklinde kullanılacak parametre yok.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach($runbook.parameters) { $parameter in
                            RunbookParameterEditor(
                                parameter: $parameter,
                                onDelete: { removeParameter(parameter.id) }
                            )
                        }
                    }

                    Button {
                        runbook.parameters.append(RunbookParameter())
                    } label: {
                        Label("Parametre ekle", systemImage: "plus")
                    }

                    Text("Parola veya token gibi sırları varsayılan değere yazma — parametre değerleri her çalıştırmada ayrıca sorulur ve kalıcı saklanmaz.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if onDelete != nil {
                    Section {
                        Button(role: .destructive, action: {
                            showingDeleteConfirmation = true
                        }) {
                            HStack {
                                Spacer()
                                Text("Runbook'u Sil")
                                Spacer()
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(trimmedName.isEmpty ? "Yeni Runbook" : "Runbook Düzenle")
            .confirmationDialog(
                "Runbook'u silmek istediğinize emin misiniz?",
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
                        var trimmed = runbook
                        trimmed.name = trimmedName
                        onSave(trimmed)
                    }
                    .disabled(trimmedName.isEmpty || runbook.steps.isEmpty)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 560)
    }

    private func removeStep(_ id: UUID) {
        runbook.steps.removeAll { $0.id == id }
    }

    private func moveSteps(from offsets: IndexSet, to destination: Int) {
        runbook.steps.move(fromOffsets: offsets, toOffset: destination)
    }

    private func move(_ id: UUID, offset: Int) {
        guard let source = runbook.steps.firstIndex(where: { $0.id == id }) else { return }
        let destination = source + offset
        guard runbook.steps.indices.contains(destination) else { return }
        runbook.steps.swapAt(source, destination)
    }

    private func removeParameter(_ id: UUID) {
        runbook.parameters.removeAll { $0.id == id }
    }
}

private struct RunbookStepEditor: View {
    @Binding var step: RunbookStep
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Komut", systemImage: "terminal")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Yukarı taşı", systemImage: "chevron.up", action: onMoveUp)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Adımı yukarı taşı")
                    .accessibilityLabel("Adımı yukarı taşı")
                Button("Aşağı taşı", systemImage: "chevron.down", action: onMoveDown)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Adımı aşağı taşı")
                    .accessibilityLabel("Adımı aşağı taşı")
                Button("Adımı sil", systemImage: "trash", role: .destructive, action: onDelete)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Adımı sil")
                    .accessibilityLabel("Adımı sil")
            }

            TextField("Komut", text: $step.command, prompt: Text("örn. apt-get install -y {{package}}"), axis: .vertical)
                .font(.body.monospaced())
                .lineLimit(1 ... 4)
                .editorFieldStyle()

            Toggle("Başarısız olursa bu hostta sonraki adımlara devam et", isOn: $step.continueOnError)

            if RunbookDangerDetector.isDangerous(step.command) {
                Label("Bu komut tehlikeli bir kalıp içeriyor.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct RunbookParameterEditor: View {
    @Binding var parameter: RunbookParameter
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Parametre adı", text: $parameter.name, prompt: Text("örn. version"))
                    .font(.body.monospaced())
                    .editorFieldStyle()
                TextField(
                    "Varsayılan değer (isteğe bağlı)",
                    text: Binding(
                        get: { parameter.defaultValue ?? "" },
                        set: { parameter.defaultValue = $0.isEmpty ? nil : $0 }
                    )
                )
                .foregroundStyle(.secondary)
                .editorFieldStyle()
            }
            Spacer()
            Button("Parametreyi sil", systemImage: "trash", role: .destructive, action: onDelete)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Parametreyi sil")
                .accessibilityLabel("Parametreyi sil")
        }
        .padding(.vertical, 4)
    }
}
