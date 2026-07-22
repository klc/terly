import SwiftUI

/// The mandatory run flow for a runbook (product roadmap principle 5: no
/// command ever runs on more than one server without the user seeing it
/// first). Four phases in strict order — target selection, parameter
/// values, preview, running — and nothing is composed or sent to `ssh`
/// until the user has seen the exact resolved command list and host count
/// on the preview screen and pressed "Run".
struct RunbookRunSheet: View {
    let runbook: Runbook
    let availableConnections: [SSHConnectionTarget]
    let onClose: () -> Void

    private enum Phase {
        case targets
        case parameters
        case preview
        case running
    }

    @State private var phase: Phase = .targets
    @State private var selectedAlias: String?
    @State private var parameterValues: [UUID: String] = [:]
    @State private var concurrencyLimit = RunbookExecutionEngine.defaultConcurrencyLimit
    @State private var showingDangerConfirmation = false
    @State private var selectedOutput: RunbookOutputSelection?
    @StateObject private var engine = RunbookExecutionEngine()

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .targets: targetSelectionView
                case .parameters: parameterFormView
                case .preview: previewView
                case .running: runningView
                }
            }
            .navigationTitle(runbook.name.isEmpty ? String(localized: "Run Runbook") : runbook.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(phase == .running ? "Close" : "Cancel") {
                        if phase == .running { engine.cancel() }
                        onClose()
                    }
                }
                if phase == .parameters || phase == .preview {
                    ToolbarItem(placement: .navigation) {
                        Button("Back", action: goBack)
                    }
                }
                if phase != .running {
                    ToolbarItem(placement: .confirmationAction) {
                        nextButton
                    }
                }
            }
            .confirmationDialog(
                "This runbook is marked dangerous or contains a dangerous command pattern. Are you sure you want to run it on \(resolvedTargets.count) hosts?",
                isPresented: $showingDangerConfirmation,
                titleVisibility: .visible
            ) {
                Button("Run", role: .destructive, action: startRun)
                Button("Cancel", role: .cancel) {}
            }
        }
        .frame(minWidth: 560, minHeight: 480)
        .onAppear(perform: setDefaults)
    }

    // MARK: - Toolbar actions

    @ViewBuilder
    private var nextButton: some View {
        switch phase {
        case .targets:
            Button("Next") {
                phase = runbook.parameters.isEmpty ? .preview : .parameters
            }
            .disabled(resolvedTargets.isEmpty)
        case .parameters:
            Button("Next") { phase = .preview }
        case .preview:
            Button("Run (\(resolvedTargets.count) hosts)") {
                if isDangerousRun {
                    showingDangerConfirmation = true
                } else {
                    startRun()
                }
            }
            .disabled(previewComposeError != nil || resolvedTargets.isEmpty)
        case .running:
            EmptyView()
        }
    }

    private func goBack() {
        switch phase {
        case .parameters: phase = .targets
        case .preview: phase = runbook.parameters.isEmpty ? .targets : .parameters
        case .targets, .running: break
        }
    }

    private func startRun() {
        phase = .running
        engine.run(
            runbook: runbook,
            values: valuesDictionary,
            targets: resolvedTargets,
            concurrencyLimit: concurrencyLimit
        )
    }

    private func setDefaults() {
        if selectedAlias == nil {
            selectedAlias = availableConnections.first?.alias
        }
    }

    // MARK: - Derived state

    private var resolvedTargets: [String] {
        selectedAlias.map { [$0] } ?? []
    }

    private var valuesDictionary: [String: String] {
        var values: [String: String] = [:]
        for parameter in runbook.parameters {
            values[parameter.name] = parameterValues[parameter.id] ?? parameter.defaultValue ?? ""
        }
        return values
    }

    private var composedSteps: Result<[(step: RunbookStep, command: String)], Error> {
        Result {
            try runbook.steps.map { step in
                (step: step, command: try RunbookCommandComposer.compose(step: step, values: valuesDictionary))
            }
        }
    }

    private var previewComposeError: Error? {
        if case let .failure(error) = composedSteps { return error }
        return nil
    }

    private var isDangerousRun: Bool {
        if runbook.isDangerous { return true }
        if case let .success(steps) = composedSteps {
            return steps.contains { RunbookDangerDetector.isDangerous($0.command) }
        }
        return false
    }

    // MARK: - Phase 1: targets

    private var targetSelectionView: some View {
        Form {
            Section("Host") {
                if availableConnections.isEmpty {
                    Text("No concrete host found in the config.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Host", selection: $selectedAlias) {
                        Text("Select…").tag(String?.none)
                        ForEach(availableConnections) { connection in
                            Text(connection.alias).tag(String?.some(connection.alias))
                        }
                    }
                    .labelsHidden()
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Phase 2: parameters

    private var parameterFormView: some View {
        Form {
            Section("Parameters") {
                ForEach(runbook.parameters) { parameter in
                    TextField(
                        parameter.name.isEmpty ? String(localized: "(unnamed)") : parameter.name,
                        text: Binding(
                            get: { parameterValues[parameter.id] ?? parameter.defaultValue ?? "" },
                            set: { parameterValues[parameter.id] = $0 }
                        )
                    )
                    .editorFieldStyle()
                }
            }

            Text("These values are only used for this run; they aren't saved to the runbook file.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    // MARK: - Phase 3: preview

    private var previewView: some View {
        Form {
            Section("Targets (\(resolvedTargets.count) hosts)") {
                ForEach(resolvedTargets, id: \.self) { alias in
                    Text(alias).font(.body.monospaced())
                }
            }

            Section("Commands to run") {
                switch composedSteps {
                case let .success(steps):
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, entry in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("\(index + 1).")
                                    .foregroundStyle(.secondary)
                                Text(entry.command)
                                    .font(.body.monospaced())
                                    .textSelection(.enabled)
                                if RunbookDangerDetector.isDangerous(entry.command) {
                                    Label("Dangerous", systemImage: "exclamationmark.triangle.fill")
                                        .labelStyle(.iconOnly)
                                        .foregroundStyle(.orange)
                                }
                            }
                            if entry.step.continueOnError {
                                Text("If this fails, continues with the next steps on this host.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                case let .failure(error):
                    Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            Section("Concurrency") {
                Stepper(
                    "Up to \(concurrencyLimit) hosts at a time",
                    value: $concurrencyLimit,
                    in: RunbookExecutionEngine.concurrencyLimitRange
                )
            }

            if isDangerousRun {
                Label(
                    "This runbook is marked dangerous or contains a dangerous command pattern. Extra confirmation will be required before running.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                .font(.caption)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Phase 4: running

    private var runningView: some View {
        VStack(spacing: 0) {
            List {
                ForEach(engine.orderedResults) { result in
                    Button {
                        selectedOutput = RunbookOutputSelection(alias: result.alias)
                    } label: {
                        RunbookHostRow(result: result)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.inset)

            Divider()

            HStack {
                Text(summaryText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if engine.isRunning {
                    Button("Cancel run", role: .destructive) { engine.cancel() }
                } else if hasFailedHosts {
                    Button("Retry failed") { engine.retryFailedHosts() }
                }
            }
            .padding()
        }
        .sheet(item: $selectedOutput) { selection in
            RunbookHostOutputView(
                result: engine.results[selection.alias] ?? RunbookHostResult(alias: selection.alias)
            )
        }
    }

    private var summaryText: String {
        let total = engine.orderedResults.count
        let succeeded = engine.orderedResults.filter {
            if case .succeeded = $0.status { return true }
            return false
        }.count
        let failed = engine.orderedResults.filter {
            if case .failed = $0.status { return true }
            return false
        }.count

        if engine.isRunning {
            return String(localized: "Running… (\(succeeded + failed)/\(total) completed)")
        }
        return String(localized: "\(succeeded)/\(total) succeeded, \(failed)/\(total) failed")
    }

    private var hasFailedHosts: Bool {
        engine.orderedResults.contains {
            if case .failed = $0.status { return true }
            return false
        }
    }
}

private struct RunbookOutputSelection: Identifiable {
    let alias: String
    var id: String { alias }
}

private struct RunbookHostRow: View {
    let result: RunbookHostResult

    var body: some View {
        HStack {
            statusIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(result.alias)
                    .font(.body.monospaced())
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if case .running = result.status {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch result.status {
        case .pending:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .running:
            Image(systemName: StepStatusStyle.running.symbolName).foregroundStyle(StepStatusStyle.running.color)
        case .succeeded:
            Image(systemName: StepStatusStyle.succeeded.symbolName).foregroundStyle(StepStatusStyle.succeeded.color)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private var statusText: String {
        switch result.status {
        case .pending: return String(localized: "Waiting")
        case let .running(step, total): return String(localized: "Step \(step)/\(total)")
        case .succeeded: return String(localized: "Succeeded")
        case let .failed(message): return message
        }
    }
}

private struct RunbookHostOutputView: View {
    let result: RunbookHostResult
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(result.output.isEmpty ? String(localized: "No output.") : result.output)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle(result.alias)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 360)
    }
}
