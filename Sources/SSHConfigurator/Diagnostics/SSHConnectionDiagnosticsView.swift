import AppKit
import Combine
import SSHConfigCore
import SwiftUI

@MainActor
final class SSHConnectionDiagnosticsViewModel: ObservableObject {
    @Published private(set) var report: SSHDiagnosticReport?
    @Published private(set) var isRunning = false

    private let alias: String
    private let document: SSHConfigDocument
    private let diagnostics: any SSHConnectionDiagnosing
    private var task: Task<Void, Never>?

    init(
        alias: String,
        document: SSHConfigDocument,
        diagnostics: any SSHConnectionDiagnosing = SSHConnectionDiagnostics()
    ) {
        self.alias = alias
        self.document = document
        self.diagnostics = diagnostics
    }

    func run() {
        task?.cancel()
        report = nil
        isRunning = true
        task = Task { [weak self] in
            guard let self else { return }
            let report = await diagnostics.diagnose(alias: alias, document: document)
            guard !Task.isCancelled else { return }
            self.report = report
            isRunning = false
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
    }
}

struct SSHConnectionDiagnosticsView: View {
    @StateObject private var model: SSHConnectionDiagnosticsViewModel
    @State private var approvedMatchExec = false
    @State private var didCopyReport = false
    @State private var showingKeySetupWizard = false

    @Environment(\.dismiss) private var dismiss

    let alias: String
    let executionPolicy: SSHDiagnosticsExecutionPolicy
    let onIdentityFileAccepted: (String) -> Void

    init(
        alias: String,
        document: SSHConfigDocument,
        onIdentityFileAccepted: @escaping (String) -> Void = { _ in }
    ) {
        self.alias = alias
        self.onIdentityFileAccepted = onIdentityFileAccepted
        executionPolicy = SSHDiagnosticsExecutionPolicy(document: document)
        _model = StateObject(wrappedValue: SSHConnectionDiagnosticsViewModel(
            alias: alias,
            document: document
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                systemImage: "stethoscope",
                iconFont: .title2,
                title: String(localized: "Connection Diagnostics and Trust Center"),
                subtitle: Text(alias).font(.caption.monospaced()),
                onClose: { dismiss() }
            ) {
                if model.isRunning {
                    Button("Cancel", role: .cancel) { model.cancel() }
                } else if model.report != nil {
                    Button("Run again", systemImage: "arrow.clockwise") { model.run() }
                }
            }

            Divider()

            Group {
                if executionPolicy.requiresExplicitConfigEvaluationApproval && !approvedMatchExec {
                    configEvaluationWarning
                } else if model.isRunning {
                    VStack(spacing: 14) {
                        ProgressView()
                        Text("Checking DNS, host trust, agent, and end-to-end connection…")
                            .foregroundStyle(.secondary)
                        Text("Each network step is limited by a timeout. Cancelling ends the running subprocess.")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let report = model.report {
                    reportView(report)
                } else {
                    ContentUnavailableView(
                        "Diagnostics ready",
                        systemImage: "checkmark.shield",
                        description: Text("Use the button below to start the connection checks.")
                    )
                    .overlay(alignment: .bottom) {
                        Button("Test connection") { model.run() }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .padding(32)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 620)
        .task {
            if !executionPolicy.requiresExplicitConfigEvaluationApproval {
                model.run()
            }
        }
        .onDisappear { model.cancel() }
        .sheet(isPresented: $showingKeySetupWizard) {
            KeySetupWizardView(alias: alias, onIdentityFileAccepted: onIdentityFileAccepted)
        }
    }

    private var configEvaluationWarning: some View {
        ContentUnavailableView {
            Label("Config evaluation approval required", systemImage: "exclamationmark.triangle.fill")
        } description: {
            Text("\(executionPolicy.riskDescription ?? String(localized: "The config can run a local command.")) You must explicitly approve this before diagnostics can start.")
        } actions: {
            Button("Diagnose while evaluating config") {
                approvedMatchExec = true
                model.run()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func reportView(_ report: SSHDiagnosticReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Label(
                        report.hasFailures ? "Issue found" : "No critical issues found",
                        systemImage: report.hasFailures ? "xmark.octagon.fill" : "checkmark.shield.fill"
                    )
                    .font(.title2.bold())
                    .foregroundStyle(report.hasFailures ? .red : .green)
                    Spacer()
                    Button(didCopyReport ? "Copied" : "Copy redacted report", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report.redactedText, forType: .string)
                        didCopyReport = true
                    }
                }

                VStack(spacing: 10) {
                    ForEach(report.checks) { check in
                        DiagnosticCheckRow(check: check)
                    }
                }

                if report.suggestsKeySetup {
                    keySetupSuggestion
                }

                DisclosureGroup("Resolved SSH settings (\(report.resolvedSettings.count))") {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(report.resolvedSettings) { setting in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(setting.key)
                                        .font(.system(.caption, design: .monospaced).bold())
                                        .frame(width: 180, alignment: .leading)
                                    Text(displayValue(for: setting))
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                                Text(setting.source)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Divider()
                        }
                    }
                    .padding(.top, 10)
                }
                .font(.headline)
            }
            .padding(24)
        }
    }

    private var keySetupSuggestion: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "key.fill")
                .foregroundStyle(.orange)
                .font(.title3)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text("There's no usable key in the agent, and the server rejected authentication.")
                    .font(.subheadline.weight(.semibold))
                Text("You can open the setup wizard to generate a new key and copy it to the server.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Open Key Setup Wizard") {
                    showingKeySetupWizard = true
                }
                .buttonStyle(.bordered)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private func displayValue(for setting: SSHResolvedSetting) -> String {
        switch setting.key {
        case "localcommand", "remotecommand", "proxycommand":
            return String(localized: "<hidden for security>")
        default:
            return setting.value
        }
    }
}

private struct DiagnosticCheckRow: View {
    let check: SSHDiagnosticCheck

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.title3)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(check.title)
                    .font(.headline)
                Text(check.summary)
                if let detail = check.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private var icon: String {
        switch check.status {
        case .passed: StepStatusStyle.succeeded.symbolName
        case .warning: "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon.fill"
        case .information: "info.circle.fill"
        }
    }

    private var color: Color {
        switch check.status {
        case .passed: StepStatusStyle.succeeded.color
        case .warning: .orange
        case .failed: .red
        case .information: .blue
        }
    }
}
