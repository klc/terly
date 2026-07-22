import SwiftUI

/// Phase C: the save-new / edit-existing sheet for a `SavedWorkspace`. Layout
/// (tabs, panes, split ratios) is never editable here — only the name and
/// each pane's startup override — so the working state only needs to track
/// per-pane startup selections, keyed by the pane's snapshot-internal `id`.
/// `workspace.sessions` itself (aliases, layout shape) is read directly from
/// the seed value throughout; only `startupByPane` changes.
struct WorkspaceEditSheet: View {
    let workspace: SavedWorkspace
    let isNew: Bool
    let availableFlows: [StartupFlowProfile]
    let onSave: (SavedWorkspace) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var startupByPane: [UUID: PaneStartupSelection]
    @FocusState private var nameFieldFocused: Bool

    init(
        workspace: SavedWorkspace,
        isNew: Bool,
        availableFlows: [StartupFlowProfile],
        onSave: @escaping (SavedWorkspace) -> Void
    ) {
        self.workspace = workspace
        self.isNew = isNew
        self.availableFlows = availableFlows
        self.onSave = onSave
        _name = State(initialValue: workspace.name)

        var initialSelections: [UUID: PaneStartupSelection] = [:]
        for session in workspace.sessions {
            for pane in session.layout.panes {
                initialSelections[pane.id] = PaneStartupSelection(pane.startup)
            }
        }
        _startupByPane = State(initialValue: initialSelections)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                systemImage: isNew ? "rectangle.stack.badge.plus" : "rectangle.stack",
                title: isNew ? String(localized: "Save as workspace") : String(localized: "Edit workspace"),
                subtitle: Text("Reopening a workspace appends its tabs and panes to whatever is already open.").font(.caption),
                onClose: { dismiss() }
            )

            Divider()

            Form {
                Section("Workspace") {
                    TextField("Workspace name", text: $name, prompt: Text("Prod fleet"))
                        .editorFieldStyle()
                        .focused($nameFieldFocused)
                }

                ForEach(Array(workspace.sessions.enumerated()), id: \.offset) { _, session in
                    Section(session.customTitle ?? session.alias) {
                        ForEach(session.layout.panes, id: \.id) { pane in
                            paneRow(pane)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button(isNew ? String(localized: "Create Workspace") : String(localized: "Save Changes")) {
                    onSave(updatedWorkspace())
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding()
        }
        .frame(minWidth: 560, minHeight: 560)
        .onAppear {
            if isNew {
                nameFieldFocused = true
            }
        }
    }

    @ViewBuilder
    private func paneRow(_ pane: SavedWorkspacePane) -> some View {
        if isLocalTerminalAlias(pane.alias) {
            Text("Local Terminal — no startup command")
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(pane.alias)
                    .font(.subheadline.weight(.semibold))

                Picker("Startup", selection: kindBinding(for: pane.id)) {
                    Text("Host default").tag(PaneStartupKind.hostDefault)
                    Text("None").tag(PaneStartupKind.suppressed)
                    Text("Command").tag(PaneStartupKind.command)
                    Text("Flow").tag(PaneStartupKind.flow)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 220)

                switch startupByPane[pane.id] ?? .hostDefault {
                case .command:
                    TextField("Command", text: commandBinding(for: pane.id), prompt: Text("e.g. tmux attach || tmux new"))
                        .font(.system(.body, design: .monospaced))
                        .editorFieldStyle()

                case .flow:
                    if availableFlows.isEmpty {
                        Text("No saved startup flows yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Flow", selection: flowBinding(for: pane.id)) {
                            ForEach(availableFlows) { flow in
                                Text(flow.alias).tag(flow.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 220)
                    }

                case .hostDefault, .suppressed:
                    EmptyView()
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func kindBinding(for paneID: UUID) -> Binding<PaneStartupKind> {
        Binding(
            get: { (startupByPane[paneID] ?? .hostDefault).kind },
            set: { newKind in
                switch newKind {
                case .hostDefault:
                    startupByPane[paneID] = .hostDefault
                case .suppressed:
                    startupByPane[paneID] = .suppressed
                case .command:
                    if case .command = startupByPane[paneID] { } else {
                        startupByPane[paneID] = .command("")
                    }
                case .flow:
                    if case .flow = startupByPane[paneID] { } else {
                        startupByPane[paneID] = .flow(
                            availableFlows.first ?? StartupFlowProfile(alias: "", automaticallyRun: true)
                        )
                    }
                }
            }
        )
    }

    private func commandBinding(for paneID: UUID) -> Binding<String> {
        Binding(
            get: {
                if case let .command(text) = startupByPane[paneID] ?? .hostDefault { return text }
                return ""
            },
            set: { newValue in
                startupByPane[paneID] = .command(newValue)
            }
        )
    }

    private func flowBinding(for paneID: UUID) -> Binding<UUID> {
        Binding(
            get: {
                if case let .flow(profile) = startupByPane[paneID] ?? .hostDefault {
                    return profile.id
                }
                return availableFlows.first?.id ?? UUID()
            },
            set: { newID in
                guard let profile = availableFlows.first(where: { $0.id == newID }) else { return }
                startupByPane[paneID] = .flow(profile)
            }
        )
    }

    private func updatedWorkspace() -> SavedWorkspace {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let updatedSessions = workspace.sessions.map { session in
            SavedWorkspaceSession(
                hostID: session.hostID,
                alias: session.alias,
                customTitle: session.customTitle,
                layout: rebuiltLayout(session.layout),
                activePaneID: session.activePaneID,
                synchronizedPaneIDs: session.synchronizedPaneIDs
            )
        }
        return SavedWorkspace(
            id: workspace.id,
            name: trimmedName,
            createdAt: workspace.createdAt,
            updatedAt: workspace.updatedAt,
            sessions: updatedSessions
        )
    }

    private func rebuiltLayout(_ layout: SavedWorkspacePaneLayout) -> SavedWorkspacePaneLayout {
        switch layout {
        case let .pane(pane):
            let selection = startupByPane[pane.id] ?? .hostDefault
            return .pane(SavedWorkspacePane(id: pane.id, alias: pane.alias, startup: selection.override))
        case let .split(axis, ratio, first, second):
            return .split(axis: axis, ratio: ratio, first: rebuiltLayout(first), second: rebuiltLayout(second))
        }
    }

    private func isLocalTerminalAlias(_ alias: String) -> Bool {
        alias == "Yerel Terminal" || alias == "Local Terminal"
    }
}

private enum PaneStartupKind: Hashable {
    case hostDefault
    case suppressed
    case command
    case flow
}

private enum PaneStartupSelection: Equatable {
    case hostDefault
    case suppressed
    case command(String)
    case flow(StartupFlowProfile)

    init(_ override: PaneStartupOverride?) {
        switch override {
        case .none:
            self = .hostDefault
        case .suppressed:
            self = .suppressed
        case let .command(value):
            self = .command(value)
        case let .flow(profile):
            self = .flow(profile)
        }
    }

    var kind: PaneStartupKind {
        switch self {
        case .hostDefault: .hostDefault
        case .suppressed: .suppressed
        case .command: .command
        case .flow: .flow
        }
    }

    var override: PaneStartupOverride? {
        switch self {
        case .hostDefault: nil
        case .suppressed: .suppressed
        case let .command(value): .command(value)
        case let .flow(profile): .flow(profile)
        }
    }
}
