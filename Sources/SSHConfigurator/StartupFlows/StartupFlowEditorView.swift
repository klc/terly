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
        Section("Başlangıç Akışı") {
            Toggle("Bağlanınca otomatik çalıştır", isOn: $profile.automaticallyRun)

            if profile.steps.isEmpty {
                Text("Bu bağlantı için başlangıç adımı tanımlanmadı.")
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

            Menu("Adım ekle", systemImage: "plus") {
                Button("Kullanıcı değiştir") {
                    profile.steps.append(.changeUser(""))
                }
                Button("Dizine geç") {
                    profile.steps.append(.changeDirectory(""))
                }
                Button("Komut çalıştır") {
                    profile.steps.append(.runCommand(""))
                }
            }

            if secretDetector.mayContainSecret(profile) {
                Label(
                    "Komut parola, token veya anahtar benzeri bir değer içeriyor olabilir. Başlangıç akışları şifrelenmeden metadata dosyasına yazılır; secret ekleme.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                .font(.footnote)
            }

            Text("Uygulama sudo parolasını yakalamaz veya saklamaz. Gerekirse parola normal terminal isteminde girilir.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        if !profile.steps.isEmpty {
            Section("Bağlantı öncesi önizleme") {
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

            switch step.kind {
            case .changeUser:
                TextField("Kullanıcı adı", text: $step.value, prompt: Text("xyz"))
                    .editorFieldStyle()
                Text("sudo -iu <kullanıcı> kullanılır. Bu adım ilk sırada ve yalnızca bir kez bulunabilir.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .changeDirectory:
                TextField("Uzak dizin", text: $step.value, prompt: Text("/home/xyz"))
                    .editorFieldStyle()
            case .runCommand:
                TextField("Shell komutu", text: $step.value, prompt: Text("örn. tmux attach || tmux new"), axis: .vertical)
                    .lineLimit(2...5)
                    .editorFieldStyle()
                Toggle("Başarısız olursa akışı durdur", isOn: $step.stopOnFailure)
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
