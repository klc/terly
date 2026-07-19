import SwiftUI

struct TunnelEditorView: View {
    let initialTunnel: TunnelDefinition
    let availableHosts: [String]
    let onSave: (TunnelDefinition) -> Void
    let onDelete: (() -> Void)?
    let onCancel: () -> Void
    
    @State private var tunnel: TunnelDefinition
    @State private var showingOpenBindWarning = false
    @State private var showingDeleteConfirmation = false
    
    init(tunnel: TunnelDefinition, availableHosts: [String], onSave: @escaping (TunnelDefinition) -> Void, onDelete: (() -> Void)? = nil, onCancel: @escaping () -> Void) {
        self.initialTunnel = tunnel
        self.availableHosts = availableHosts
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
        self._tunnel = State(initialValue: tunnel)
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Tunnel Info") {
                    TextField("Name", text: $tunnel.name, prompt: Text("e.g. Postgres tunnel"))
                        .editorFieldStyle()
                    TextField("Description (Optional)", text: $tunnel.description)
                        .editorFieldStyle()
                    Picker("Type", selection: $tunnel.type) {
                        ForEach(TunnelType.allCases) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    Toggle("Enabled", isOn: $tunnel.isEnabled)
                    Toggle("Auto-Connect", isOn: $tunnel.autoConnect)
                        .disabled(!tunnel.isEnabled)
                }

                Section("Local Bind") {
                    TextField("IP Address", text: $tunnel.localBindAddress, prompt: Text("e.g. 127.0.0.1"))
                        .editorFieldStyle()
                        .onChange(of: tunnel.localBindAddress) { _, newValue in
                            showingOpenBindWarning = newValue == "0.0.0.0" || newValue == "::"
                        }

                    if showingOpenBindWarning {
                        Label("Binding to all interfaces (0.0.0.0) may not be secure.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }

                    TextField("Port", value: Binding(
                        get: { tunnel.localPort },
                        set: { tunnel.localPort = $0 }
                    ), format: .number, prompt: Text("e.g. 5432"))
                        .editorFieldStyle()
                }

                if tunnel.type != .dynamic {
                    Section("Remote Bind") {
                        TextField("Remote IP / Host", text: $tunnel.remoteBindAddress, prompt: Text("e.g. localhost"))
                            .editorFieldStyle()
                        TextField("Remote Port", value: Binding(
                            get: { tunnel.remotePort },
                            set: { tunnel.remotePort = $0 }
                        ), format: .number, prompt: Text("e.g. 5432"))
                            .editorFieldStyle()
                    }
                }

                Section("Target Host (Alias)") {
                    Picker("Host", selection: $tunnel.targetHostAlias) {
                        Text("Select…").tag("")
                        ForEach(availableHosts, id: \.self) { host in
                            Text(host).tag(host)
                        }
                    }
                }

                if let onDelete = onDelete {
                    Section {
                        Button(role: .destructive, action: {
                            showingDeleteConfirmation = true
                        }) {
                            HStack {
                                Spacer()
                                Text("Delete Tunnel")
                                Spacer()
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(tunnel.name.isEmpty ? "New Tunnel" : "Edit Tunnel")
            .confirmationDialog(
                "Are you sure you want to delete this tunnel?",
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
                        onSave(tunnel)
                    }
                    .disabled(tunnel.validationError != nil)
                }
            }
            .onAppear {
                showingOpenBindWarning = tunnel.localBindAddress == "0.0.0.0" || tunnel.localBindAddress == "::"
            }
        }
        .frame(minWidth: 460, minHeight: 450)
    }
}
