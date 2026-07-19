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
                    TextField("Name", text: $runbook.name)
                        .editorFieldStyle()
                    TextField("Description (optional)", text: $runbook.description, axis: .vertical)
                        .lineLimit(1 ... 3)
                        .editorFieldStyle()
                    Toggle("Mark as dangerous", isOn: $runbook.isDangerous)
                    Text("Even when unmarked, steps containing dangerous command patterns like `rm -rf` or `shutdown` are automatically flagged in the run preview.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Steps") {
                    if runbook.steps.isEmpty {
                        Text("No steps added yet.")
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
                        Label("Add step", systemImage: "plus")
                    }
                }

                Section("Parameters") {
                    if runbook.parameters.isEmpty {
                        Text("No parameters to use as `{{name}}` in commands.")
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
                        Label("Add parameter", systemImage: "plus")
                    }

                    Text("Don't put secrets like passwords or tokens in a default value — parameter values are asked for separately on every run and aren't stored persistently.")
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
                                Text("Delete Runbook")
                                Spacer()
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(trimmedName.isEmpty ? "New Runbook" : "Edit Runbook")
            .confirmationDialog(
                "Are you sure you want to delete this runbook?",
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
                Label("Command", systemImage: "terminal")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Move up", systemImage: "chevron.up", action: onMoveUp)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Move step up")
                    .accessibilityLabel("Move step up")
                Button("Move down", systemImage: "chevron.down", action: onMoveDown)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Move step down")
                    .accessibilityLabel("Move step down")
                Button("Delete step", systemImage: "trash", role: .destructive, action: onDelete)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Delete step")
                    .accessibilityLabel("Delete step")
            }

            TextField("Command", text: $step.command, prompt: Text("e.g. apt-get install -y {{package}}"), axis: .vertical)
                .font(.body.monospaced())
                .lineLimit(1 ... 4)
                .editorFieldStyle()

            Toggle("Continue with the next steps on this host if this fails", isOn: $step.continueOnError)

            if RunbookDangerDetector.isDangerous(step.command) {
                Label("This command contains a dangerous pattern.", systemImage: "exclamationmark.triangle.fill")
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
                TextField("Parameter name", text: $parameter.name, prompt: Text("e.g. version"))
                    .font(.body.monospaced())
                    .editorFieldStyle()
                TextField(
                    "Default value (optional)",
                    text: Binding(
                        get: { parameter.defaultValue ?? "" },
                        set: { parameter.defaultValue = $0.isEmpty ? nil : $0 }
                    )
                )
                .foregroundStyle(.secondary)
                .editorFieldStyle()
            }
            Spacer()
            Button("Delete parameter", systemImage: "trash", role: .destructive, action: onDelete)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Delete parameter")
                .accessibilityLabel("Delete parameter")
        }
        .padding(.vertical, 4)
    }
}
