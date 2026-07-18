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
                title: "Bağlantı Tanılama ve Güven Merkezi",
                subtitle: Text(alias).font(.caption.monospaced()),
                onClose: { dismiss() }
            ) {
                if model.isRunning {
                    Button("İptal", role: .cancel) { model.cancel() }
                } else if model.report != nil {
                    Button("Yeniden çalıştır", systemImage: "arrow.clockwise") { model.run() }
                }
            }

            Divider()

            Group {
                if executionPolicy.requiresExplicitConfigEvaluationApproval && !approvedMatchExec {
                    configEvaluationWarning
                } else if model.isRunning {
                    VStack(spacing: 14) {
                        ProgressView()
                        Text("DNS, host güveni, agent ve uçtan uca bağlantı kontrol ediliyor…")
                            .foregroundStyle(.secondary)
                        Text("Her ağ adımı timeout ile sınırlıdır. İptal, çalışan alt süreci sonlandırır.")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let report = model.report {
                    reportView(report)
                } else {
                    ContentUnavailableView(
                        "Tanılama hazır",
                        systemImage: "checkmark.shield",
                        description: Text("Bağlantı kontrollerini başlatmak için aşağıdaki düğmeyi kullan.")
                    )
                    .overlay(alignment: .bottom) {
                        Button("Bağlantıyı test et") { model.run() }
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
            Label("Config değerlendirme onayı gerekli", systemImage: "exclamationmark.triangle.fill")
        } description: {
            Text("\(executionPolicy.riskDescription ?? "Config yerel komut çalıştırabilir.") Tanılama başlamadan önce bunu açıkça onaylamalısın.")
        } actions: {
            Button("Config'i değerlendirerek tanıla") {
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
                        report.hasFailures ? "Sorun bulundu" : "Kritik sorun bulunmadı",
                        systemImage: report.hasFailures ? "xmark.octagon.fill" : "checkmark.shield.fill"
                    )
                    .font(.title2.bold())
                    .foregroundStyle(report.hasFailures ? .red : .green)
                    Spacer()
                    Button(didCopyReport ? "Kopyalandı" : "Redakte raporu kopyala", systemImage: "doc.on.doc") {
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

                DisclosureGroup("Çözümlenmiş SSH ayarları (\(report.resolvedSettings.count))") {
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
                Text("Agent'ta kullanılabilir bir anahtar yok ve sunucu kimlik doğrulamayı reddetti.")
                    .font(.subheadline.weight(.semibold))
                Text("Yeni bir anahtar üretip sunucuya kopyalamak için kurulum sihirbazını açabilirsin.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Anahtar Kurulumu Sihirbazını Aç") {
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
            return "<güvenlik nedeniyle gizlendi>"
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
