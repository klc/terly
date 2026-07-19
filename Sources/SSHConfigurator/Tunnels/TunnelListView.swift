import SwiftUI

struct TunnelListView: View {
    @ObservedObject var model: TunnelWorkspaceModel
    let availableHosts: [String]
    
    @State private var editingTunnel: TunnelDefinition?
    
    var body: some View {
        VStack(spacing: 0) {
            if model.tunnels.isEmpty {
                ContentUnavailableView(
                    "No Tunnels Found",
                    systemImage: "network",
                    description: Text("No SSH tunnel has been created yet.")
                )
            } else {
                List {
                    ForEach(model.tunnels) { tunnel in
                        TunnelRowView(
                            tunnel: tunnel,
                            status: model.activeStatuses[tunnel.id] ?? .idle,
                            onToggle: {
                                if model.activeStatuses[tunnel.id] == .active || model.activeStatuses[tunnel.id] == .connecting {
                                    model.stopTunnel(id: tunnel.id)
                                } else {
                                    model.startTunnel(id: tunnel.id)
                                }
                            },
                            onEdit: {
                                editingTunnel = tunnel
                            }
                        )
                    }
                    .onDelete { offsets in
                        model.removeTunnels(at: offsets)
                    }
                }
                .listStyle(.inset)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: {
                    editingTunnel = TunnelDefinition()
                }) {
                    Label("Add Tunnel", systemImage: "plus")
                }
            }
        }
        .sheet(item: $editingTunnel) { tunnel in
            TunnelEditorView(
                tunnel: tunnel,
                availableHosts: availableHosts,
                onSave: { updatedTunnel in
                    if model.tunnels.contains(where: { $0.id == updatedTunnel.id }) {
                        model.updateTunnel(updatedTunnel)
                    } else {
                        model.addTunnel(updatedTunnel)
                    }
                    editingTunnel = nil
                },
                onDelete: model.tunnels.contains(where: { $0.id == tunnel.id }) ? {
                    if let index = model.tunnels.firstIndex(where: { $0.id == tunnel.id }) {
                        model.removeTunnels(at: IndexSet(integer: index))
                    }
                    editingTunnel = nil
                } : nil,
                onCancel: {
                    editingTunnel = nil
                }
            )
        }
        .navigationTitle("Tunnels")
    }
}

struct TunnelRowView: View {
    let tunnel: TunnelDefinition
    let status: TunnelStatus
    let onToggle: () -> Void
    let onEdit: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(tunnel.name)
                    .font(.headline)
                Text("\(tunnel.type.displayName) → \(tunnel.targetHostAlias)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                if !tunnel.description.isEmpty {
                    Text(tunnel.description)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                
                HStack {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(statusText)
                        .font(.caption2)
                        .foregroundStyle(statusColor)
                }
            }
            Spacer()
            
            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
            .help("Edit tunnel")
            .accessibilityLabel("Edit the \(tunnel.name) tunnel")

            Button(action: onToggle) {
                Image(systemName: isRunning ? "stop.circle.fill" : "play.circle.fill")
                    .resizable()
                    .frame(width: 24, height: 24)
                    .foregroundStyle(isRunning ? .red : .green)
            }
            .buttonStyle(.plain)
            .help(isRunning ? "Stop tunnel" : "Start tunnel")
            .accessibilityLabel(isRunning ? "Stop the \(tunnel.name) tunnel" : "Start the \(tunnel.name) tunnel")
        }
        .padding(.vertical, 8)
    }
    
    private var isRunning: Bool {
        status == .active || status == .connecting
    }
    
    private var statusColor: Color {
        switch status {
        case .idle: return .secondary
        case .connecting, .reconnecting: return .orange
        case .active: return .green
        case .failed: return .red
        }
    }
    
    private var statusText: String {
        switch status {
        case .idle: return String(localized: "Stopped")
        case .connecting: return String(localized: "Connecting…")
        case .active: return String(localized: "Active")
        case .reconnecting: return String(localized: "Reconnecting…")
        case let .failed(msg): return String(localized: "Failed: \(msg)")
        }
    }
}
