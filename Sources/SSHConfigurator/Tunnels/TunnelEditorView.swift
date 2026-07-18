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
                Section("Tünel Bilgileri") {
                    TextField("Adı", text: $tunnel.name, prompt: Text("örn. Postgres tüneli"))
                        .editorFieldStyle()
                    TextField("Açıklama (İsteğe bağlı)", text: $tunnel.description)
                        .editorFieldStyle()
                    Picker("Tipi", selection: $tunnel.type) {
                        ForEach(TunnelType.allCases) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    Toggle("Etkin", isOn: $tunnel.isEnabled)
                    Toggle("Otomatik Bağlan", isOn: $tunnel.autoConnect)
                        .disabled(!tunnel.isEnabled)
                }
                
                Section("Yerel Bağlantı (Bind)") {
                    TextField("IP Adresi", text: $tunnel.localBindAddress, prompt: Text("örn. 127.0.0.1"))
                        .editorFieldStyle()
                        .onChange(of: tunnel.localBindAddress) { _, newValue in
                            showingOpenBindWarning = newValue == "0.0.0.0" || newValue == "::"
                        }

                    if showingOpenBindWarning {
                        Label("Dış dünyaya açık (0.0.0.0) yerel bind güvenli olmayabilir.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }

                    TextField("Port", value: Binding(
                        get: { tunnel.localPort },
                        set: { tunnel.localPort = $0 }
                    ), format: .number, prompt: Text("örn. 5432"))
                        .editorFieldStyle()
                }

                if tunnel.type != .dynamic {
                    Section("Uzak Bağlantı") {
                        TextField("Uzak IP / Host", text: $tunnel.remoteBindAddress, prompt: Text("örn. localhost"))
                            .editorFieldStyle()
                        TextField("Uzak Port", value: Binding(
                            get: { tunnel.remotePort },
                            set: { tunnel.remotePort = $0 }
                        ), format: .number, prompt: Text("örn. 5432"))
                            .editorFieldStyle()
                    }
                }
                
                Section("Hedef Host (Alias)") {
                    Picker("Host", selection: $tunnel.targetHostAlias) {
                        Text("Seçiniz...").tag("")
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
                                Text("Tüneli Sil")
                                Spacer()
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(tunnel.name.isEmpty ? "Yeni Tünel" : "Tünel Düzenle")
            .confirmationDialog(
                "Tüneli silmek istediğinize emin misiniz?",
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Sil", role: .destructive) {
                    onDelete?()
                }
                Button("Vazgeç", role: .cancel) {}
            } message: {
                Text("Bu işlem geri alınamaz.")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("İptal", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Kaydet") {
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
