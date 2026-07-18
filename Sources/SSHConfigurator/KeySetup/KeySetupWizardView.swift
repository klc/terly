import SwiftUI

/// The key setup wizard (WP3): generate an ed25519 key pair, optionally add
/// it to the SSH agent, and copy the public key to the target host's
/// `authorized_keys` — with an explicit preview of the host, the exact
/// remote command, and the public key text before anything runs on the
/// server (product roadmap principle 5: no command runs on a server
/// without the user seeing it first).
///
/// Phases run strictly in order and each step only advances automatically
/// on success; a failure stops on that phase with its raw output and a
/// retry/back action, mirroring `RunbookRunSheet`'s phase model.
struct KeySetupWizardView: View {
    let alias: String
    let onIdentityFileAccepted: (String) -> Void

    @StateObject private var engine = KeySetupEngine()
    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case configure
        case generating
        case addingToAgent
        case copyPreview
        case copying
        case verifying
        case done
    }

    @State private var phase: Phase = .configure
    @State private var privateKeyPath: String
    @State private var comment: String
    @State private var addToAgent = true
    @State private var applyIdentityFile = true
    @State private var didApplyIdentityFile = false
    @State private var showingOverwriteConfirmation = false

    init(alias: String, onIdentityFileAccepted: @escaping (String) -> Void) {
        self.alias = alias
        self.onIdentityFileAccepted = onIdentityFileAccepted
        _privateKeyPath = State(initialValue: KeySetupPathDeriver.defaultPrivateKeyPath(alias: alias))
        _comment = State(initialValue: KeySetupPathDeriver.defaultComment(alias: alias))
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .configure:
                    configureView
                case .generating:
                    KeySetupStepStatusView(
                        title: "Anahtar oluşturuldu",
                        state: engine.generateState,
                        output: engine.generateOutput,
                        runningMessage: "ssh-keygen çalışıyor. Passphrase istenirse ayrı bir diyalog açılır.",
                        onBack: { phase = .configure },
                        onRetry: { requestGenerate() }
                    )
                case .addingToAgent:
                    KeySetupStepStatusView(
                        title: "SSH agent'a eklendi",
                        state: engine.agentAddState,
                        output: engine.agentAddOutput,
                        runningMessage: "ssh-add çalışıyor.",
                        onSkip: { phase = .copyPreview },
                        onRetry: { startAgentAdd() }
                    )
                case .copyPreview:
                    copyPreviewView
                case .copying:
                    KeySetupStepStatusView(
                        title: "Sunucuya kopyalandı",
                        state: engine.copyState,
                        output: engine.copyOutput,
                        runningMessage: "Public key sunucuda authorized_keys dosyasına ekleniyor.",
                        onBack: { phase = .copyPreview },
                        onRetry: { startCopy() }
                    )
                case .verifying:
                    KeySetupStepStatusView(
                        title: "Parolasız giriş doğrulandı",
                        state: engine.verifyState,
                        output: engine.verifyOutput,
                        runningMessage: "ssh -o BatchMode=yes ile test ediliyor.",
                        onSkip: { phase = .done },
                        onRetry: { startVerify() }
                    )
                case .done:
                    doneView
                }
            }
            .navigationTitle("Anahtar Kurulumu — \(alias)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(phase == .done ? "Kapat" : "İptal") { dismiss() }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 540)
        .confirmationDialog(
            "\(URL(fileURLWithPath: trimmedPath).lastPathComponent) zaten var. Üzerine yazılsın mı?",
            isPresented: $showingOverwriteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Üzerine Yaz", role: .destructive) { startGenerate(overwriteConfirmed: true) }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Mevcut anahtar dosyasının üzerine yazılacak. Bu işlem geri alınamaz.")
        }
        .onChange(of: engine.generateState) { _, newValue in
            guard phase == .generating, newValue == .succeeded else { return }
            if addToAgent {
                phase = .addingToAgent
                startAgentAdd()
            } else {
                phase = .copyPreview
            }
        }
        .onChange(of: engine.agentAddState) { _, newValue in
            guard phase == .addingToAgent, newValue.isTerminal else { return }
            phase = .copyPreview
        }
        .onChange(of: engine.copyState) { _, newValue in
            guard phase == .copying, newValue == .succeeded else { return }
            phase = .verifying
            startVerify()
        }
        .onChange(of: engine.verifyState) { _, newValue in
            guard phase == .verifying, newValue.isTerminal else { return }
            phase = .done
        }
    }

    // MARK: - Phase 1: configure

    private var configureView: some View {
        Form {
            Section("Hedef") {
                LabeledContent("Host", value: alias)
            }

            Section("Yeni anahtar") {
                TextField("Özel anahtar yolu", text: $privateKeyPath, prompt: Text("örn. ~/.ssh/id_ed25519"))
                    .font(.system(.body, design: .monospaced))
                    .editorFieldStyle()
                TextField("Yorum (-C)", text: $comment, prompt: Text("örn. mustafa@macbook"))
                    .editorFieldStyle()
            }

            Section {
                Toggle("Anahtarı SSH agent'a ekle (ssh-add)", isOn: $addToAgent)
            }

            Section {
                Text("Passphrase, ssh-keygen'in kendi istemiyle sorulur ve bir diyalog olarak gösterilir; uygulama passphrase'i hiçbir zaman görmez, tutmaz veya loglamaz.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Anahtar Oluştur") { requestGenerate() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedPath.isEmpty)
            }
            .padding()
        }
    }

    // MARK: - Phase: copy preview

    private var copyPreviewView: some View {
        Form {
            Section("Hedef") {
                LabeledContent("Host", value: alias)
            }

            Section("Çalıştırılacak uzak komut") {
                Text("ssh -- \(alias) '\(KeySetupCommandBuilder.authorizedKeysRemoteScript)'")
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }

            Section("Eklenecek public key") {
                Text(publicKeyText.isEmpty ? "(public key okunamadı)" : publicKeyText)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }

            if case let .failed(message) = engine.agentAddState, addToAgent {
                Section {
                    Label("SSH agent'a ekleme başarısız oldu: \(message)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Sunucuya Kopyala") { startCopy() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(publicKeyText.isEmpty)
            }
            .padding()
        }
    }

    // MARK: - Phase: done

    private var doneView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Özet")
                .font(.title3.bold())

            summaryRow(title: "Anahtar oluşturma", state: engine.generateState)
            if addToAgent {
                summaryRow(title: "SSH agent'a ekleme", state: engine.agentAddState)
            }
            summaryRow(title: "Sunucuya kopyalama", state: engine.copyState)
            summaryRow(title: "Parolasız giriş doğrulaması", state: engine.verifyState)

            Divider()

            Toggle("Host'un IdentityFile alanını bu anahtara güncelle", isOn: $applyIdentityFile)
                .disabled(didApplyIdentityFile)

            if didApplyIdentityFile {
                Label("IdentityFile güncellendi ve kaydedildi.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            }

            Spacer()

            HStack {
                Spacer()
                if applyIdentityFile && !didApplyIdentityFile {
                    Button("IdentityFile'ı Güncelle ve Uygula") {
                        onIdentityFileAccepted(trimmedPath)
                        didApplyIdentityFile = true
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
                Button("Kapat") { dismiss() }
            }
        }
        .padding(24)
    }

    private func summaryRow(title: String, state: KeySetupStepState) -> some View {
        HStack {
            Image(systemName: icon(for: state))
                .foregroundStyle(color(for: state))
            Text(title)
            Spacer()
            Text(label(for: state))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func icon(for state: KeySetupStepState) -> String {
        switch state {
        case .succeeded: return StepStatusStyle.succeeded.symbolName
        case .failed: return "xmark.octagon.fill"
        case .running: return StepStatusStyle.running.symbolName
        case .pending: return "circle.dashed"
        }
    }

    private func color(for state: KeySetupStepState) -> Color {
        switch state {
        case .succeeded: return StepStatusStyle.succeeded.color
        case .failed: return .red
        case .running: return StepStatusStyle.running.color
        case .pending: return .secondary
        }
    }

    private func label(for state: KeySetupStepState) -> String {
        switch state {
        case .succeeded: return "Başarılı"
        case let .failed(message): return message
        case .running: return "Çalışıyor"
        case .pending: return "Atlandı"
        }
    }

    // MARK: - Actions

    private var trimmedPath: String {
        privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var publicKeyText: String {
        engine.publicKeyPreview ?? ""
    }

    private func requestGenerate() {
        if engine.privateKeyExists(atPath: trimmedPath) {
            showingOverwriteConfirmation = true
        } else {
            startGenerate(overwriteConfirmed: false)
        }
    }

    private func startGenerate(overwriteConfirmed: Bool) {
        phase = .generating
        let path = trimmedPath
        let commentValue = comment
        Task {
            await engine.generateKey(privateKeyPath: path, comment: commentValue, overwriteConfirmed: overwriteConfirmed)
        }
    }

    private func startAgentAdd() {
        let path = trimmedPath
        Task {
            await engine.addToAgent(privateKeyPath: path)
        }
    }

    private func startCopy() {
        phase = .copying
        let text = publicKeyText
        let target = alias
        Task {
            await engine.copyPublicKey(alias: target, publicKeyText: text)
        }
    }

    private func startVerify() {
        let target = alias
        Task {
            await engine.verifyPasswordlessLogin(alias: target)
        }
    }
}

/// Shared "running / succeeded / failed" presentation for a single wizard
/// step. `onBack`/`onSkip`/`onRetry` are all optional — callers only supply
/// the actions that make sense for that step (e.g. the optional agent-add
/// step offers "Atla" instead of "Geri").
private struct KeySetupStepStatusView: View {
    let title: String
    let state: KeySetupStepState
    let output: String
    let runningMessage: String
    var onBack: (() -> Void)?
    var onSkip: (() -> Void)?
    var onRetry: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            switch state {
            case .pending, .running:
                ProgressView()
                Text(runningMessage)
                    .foregroundStyle(.secondary)
            case .succeeded:
                Label(title, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.headline)
            case let .failed(message):
                Label("Başarısız oldu", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.headline)
                ScrollView {
                    Text(message)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .frame(maxHeight: 220)
                HStack {
                    if let onBack {
                        Button("Geri", action: onBack)
                    }
                    if let onSkip {
                        Button("Atla", action: onSkip)
                    }
                    if let onRetry {
                        Button("Tekrar Dene", action: onRetry)
                            .buttonStyle(.borderedProminent)
                    }
                }
            }

            if !output.isEmpty, state != .running {
                DisclosureGroup("Çıktı") {
                    ScrollView {
                        Text(output)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                }
                .padding(.horizontal, 24)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
