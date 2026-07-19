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
                        title: String(localized: "Key generated"),
                        state: engine.generateState,
                        output: engine.generateOutput,
                        runningMessage: String(localized: "ssh-keygen is running. A separate dialog opens if a passphrase is requested."),
                        onBack: { phase = .configure },
                        onRetry: { requestGenerate() }
                    )
                case .addingToAgent:
                    KeySetupStepStatusView(
                        title: String(localized: "Added to SSH agent"),
                        state: engine.agentAddState,
                        output: engine.agentAddOutput,
                        runningMessage: String(localized: "ssh-add is running."),
                        onSkip: { phase = .copyPreview },
                        onRetry: { startAgentAdd() }
                    )
                case .copyPreview:
                    copyPreviewView
                case .copying:
                    KeySetupStepStatusView(
                        title: String(localized: "Copied to server"),
                        state: engine.copyState,
                        output: engine.copyOutput,
                        runningMessage: String(localized: "Adding the public key to authorized_keys on the server."),
                        onBack: { phase = .copyPreview },
                        onRetry: { startCopy() }
                    )
                case .verifying:
                    KeySetupStepStatusView(
                        title: String(localized: "Password-less login verified"),
                        state: engine.verifyState,
                        output: engine.verifyOutput,
                        runningMessage: String(localized: "Testing with ssh -o BatchMode=yes."),
                        onSkip: { phase = .done },
                        onRetry: { startVerify() }
                    )
                case .done:
                    doneView
                }
            }
            .navigationTitle("Key Setup — \(alias)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(phase == .done ? "Close" : "Cancel") { dismiss() }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 540)
        .confirmationDialog(
            "\(URL(fileURLWithPath: trimmedPath).lastPathComponent) already exists. Overwrite it?",
            isPresented: $showingOverwriteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Overwrite", role: .destructive) { startGenerate(overwriteConfirmed: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The existing key file will be overwritten. This action cannot be undone.")
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
            Section("Target") {
                LabeledContent("Host", value: alias)
            }

            Section("New key") {
                TextField("Private key path", text: $privateKeyPath, prompt: Text("e.g. ~/.ssh/id_ed25519"))
                    .font(.system(.body, design: .monospaced))
                    .editorFieldStyle()
                TextField("Comment (-C)", text: $comment, prompt: Text("e.g. mustafa@macbook"))
                    .editorFieldStyle()
            }

            Section {
                Toggle("Add key to SSH agent (ssh-add)", isOn: $addToAgent)
            }

            Section {
                Text("The passphrase is requested through ssh-keygen's own prompt, shown as a dialog; the app never sees, stores, or logs the passphrase.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Generate Key") { requestGenerate() }
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
            Section("Target") {
                LabeledContent("Host", value: alias)
            }

            Section("Remote command to run") {
                Text("ssh -- \(alias) '\(KeySetupCommandBuilder.authorizedKeysRemoteScript)'")
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }

            Section("Public key to add") {
                Text(publicKeyText.isEmpty ? String(localized: "(couldn't read public key)") : publicKeyText)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }

            if case let .failed(message) = engine.agentAddState, addToAgent {
                Section {
                    Label("Adding to SSH agent failed: \(message)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Copy to Server") { startCopy() }
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
            Text("Summary")
                .font(.title3.bold())

            summaryRow(title: String(localized: "Key generation"), state: engine.generateState)
            if addToAgent {
                summaryRow(title: String(localized: "Add to SSH agent"), state: engine.agentAddState)
            }
            summaryRow(title: String(localized: "Copy to server"), state: engine.copyState)
            summaryRow(title: String(localized: "Password-less login verification"), state: engine.verifyState)

            Divider()

            Toggle("Update the host's IdentityFile to this key", isOn: $applyIdentityFile)
                .disabled(didApplyIdentityFile)

            if didApplyIdentityFile {
                Label("IdentityFile updated and saved.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            }

            Spacer()

            HStack {
                Spacer()
                if applyIdentityFile && !didApplyIdentityFile {
                    Button("Update and Apply IdentityFile") {
                        onIdentityFileAccepted(trimmedPath)
                        didApplyIdentityFile = true
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
                Button("Close") { dismiss() }
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
        case .succeeded: return String(localized: "Succeeded")
        case let .failed(message): return message
        case .running: return String(localized: "Running")
        case .pending: return String(localized: "Skipped")
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
/// step offers "Skip" instead of "Back").
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
                Label("Failed", systemImage: "xmark.octagon.fill")
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
                        Button("Back", action: onBack)
                    }
                    if let onSkip {
                        Button("Skip", action: onSkip)
                    }
                    if let onRetry {
                        Button("Retry", action: onRetry)
                            .buttonStyle(.borderedProminent)
                    }
                }
            }

            if !output.isEmpty, state != .running {
                DisclosureGroup("Output") {
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
