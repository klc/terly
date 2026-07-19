import SwiftUI

struct StartupFlowOptionalEditorView: View {
    @Binding var profile: StartupFlowProfile?

    var body: some View {
        if profile != nil {
            StartupFlowEditorView(
                profile: Binding(
                    get: { profile! },
                    set: { profile = $0 }
                )
            )
        }
    }
}

struct StartupFlowEditorView: View {
    @Binding var profile: StartupFlowProfile

    private let secretDetector = StartupFlowSecretDetector()

    var body: some View {
        Section("Startup Flow") {
            Toggle("Run automatically on connect", isOn: $profile.automaticallyRun)

            if profile.steps.isEmpty {
                Text("No startup steps defined for this connection.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach($profile.steps) { $step in
                    StartupFlowStepEditor(
                        step: $step,
                        onMoveUp: { move(step.id, offset: -1) },
                        onMoveDown: { move(step.id, offset: 1) },
                        onDelete: { remove(step.id) }
                    )
                }
                .onMove(perform: move)
            }

            Menu("Add step", systemImage: "plus") {
                Button("Change user") {
                    profile.steps.append(.changeUser(""))
                }
                Button("Change directory") {
                    profile.steps.append(.changeDirectory(""))
                }
                Button("Run command") {
                    profile.steps.append(.runCommand(""))
                }
            }

            if secretDetector.mayContainSecret(profile) {
                Label(
                    "The command may contain a value that looks like a password, token, or key. Startup flows are written to the metadata file unencrypted; don't add secrets.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                .font(.footnote)
            }

            Text("The app never captures or stores your sudo password. If needed, it's entered at the normal terminal prompt.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        if !profile.steps.isEmpty {
            Section("Preview before connecting") {
                ForEach(Array(profile.steps.enumerated()), id: \.element.id) { index, step in
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(index + 1).")
                            .foregroundStyle(.secondary)
                        Text(step.summary)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func remove(_ id: UUID) {
        profile.steps.removeAll { $0.id == id }
    }

    private func move(from offsets: IndexSet, to destination: Int) {
        profile.steps.move(fromOffsets: offsets, toOffset: destination)
    }

    private func move(_ id: UUID, offset: Int) {
        guard let source = profile.steps.firstIndex(where: { $0.id == id }) else { return }
        let destination = source + offset
        guard profile.steps.indices.contains(destination) else { return }
        profile.steps.swapAt(source, destination)
    }
}

private struct StartupFlowStepEditor: View {
    @Binding var step: StartupFlowStep
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(step.kind.label, systemImage: icon)
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

            switch step.kind {
            case .changeUser:
                TextField("Username", text: $step.value, prompt: Text("xyz"))
                    .editorFieldStyle()
                Text("Runs as `sudo -iu <user>`. This step can only be first and can only appear once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .changeDirectory:
                TextField("Remote directory", text: $step.value, prompt: Text("/home/xyz"))
                    .editorFieldStyle()
            case .runCommand:
                TextField("Shell command", text: $step.value, prompt: Text("e.g. tmux attach || tmux new"), axis: .vertical)
                    .lineLimit(2...5)
                    .editorFieldStyle()
                Toggle("Stop the flow if this fails", isOn: $step.stopOnFailure)
            }
        }
        .padding(.vertical, 4)
    }

    private var icon: String {
        switch step.kind {
        case .changeUser: "person.badge.key"
        case .changeDirectory: "folder"
        case .runCommand: "terminal"
        }
    }
}
