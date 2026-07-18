import Foundation
import Combine

@MainActor
final class TunnelWorkspaceModel: ObservableObject {
    @Published var tunnels: [TunnelDefinition] = []
    @Published var activeStatuses: [UUID: TunnelStatus] = [:]
    @Published var errorMessage: String?
    
    private let store: any TunnelPersisting
    private let processExecuting: any SSHProcessExecuting
    private let launchPlanBuilder: SSHLaunchPlanBuilder
    private var tasks: [UUID: any SSHProcessTask] = [:]
    
    init(
        store: any TunnelPersisting = TunnelStore(),
        processExecuting: any SSHProcessExecuting = SSHProcessClient(),
        launchPlanBuilder: SSHLaunchPlanBuilder
    ) {
        self.store = store
        self.processExecuting = processExecuting
        self.launchPlanBuilder = launchPlanBuilder
    }
    
    func load() {
        do {
            tunnels = try store.load()
            for tunnel in tunnels where tunnel.isEnabled && tunnel.autoConnect {
                startTunnel(id: tunnel.id)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    
    func save() {
        do {
            try store.save(tunnels)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    
    func addTunnel(_ tunnel: TunnelDefinition) {
        tunnels.append(tunnel)
        save()
    }
    
    func updateTunnel(_ tunnel: TunnelDefinition) {
        if let index = tunnels.firstIndex(where: { $0.id == tunnel.id }) {
            tunnels[index] = tunnel
            save()
            if !tunnel.isEnabled {
                stopTunnel(id: tunnel.id)
            }
        }
    }
    
    func removeTunnels(at offsets: IndexSet) {
        let removed = offsets.map { tunnels[$0] }
        tunnels.remove(atOffsets: offsets)
        save()
        for tunnel in removed {
            stopTunnel(id: tunnel.id)
        }
    }
    
    func startTunnel(id: UUID) {
        guard let tunnel = tunnels.first(where: { $0.id == id }) else { return }
        guard tunnel.isEnabled else {
            activeStatuses[id] = .idle
            return
        }
        if let validationError = tunnel.validationError {
            activeStatuses[id] = .failed(validationError)
            return
        }
        
        // Cancel existing task if any
        stopTunnel(id: id)
        
        activeStatuses[id] = .connecting
        
        var arguments = ["-N"]
        switch tunnel.type {
        case .local:
            let localStr = "\(tunnel.localBindAddress):\(tunnel.localPort ?? 0)"
            let remoteStr = "\(tunnel.remoteBindAddress):\(tunnel.remotePort ?? 0)"
            arguments.append(contentsOf: ["-L", "\(localStr):\(remoteStr)"])
        case .remote:
            let localStr = "\(tunnel.localBindAddress):\(tunnel.localPort ?? 0)"
            let remoteStr = "\(tunnel.remoteBindAddress):\(tunnel.remotePort ?? 0)"
            arguments.append(contentsOf: ["-R", "\(localStr):\(remoteStr)"])
        case .dynamic:
            let localStr = "\(tunnel.localBindAddress):\(tunnel.localPort ?? 0)"
            arguments.append(contentsOf: ["-D", localStr])
        }
        arguments.append(contentsOf: ["--", tunnel.targetHostAlias])
        
        let request = SSHProcessRequest(
            executableURL: launchPlanBuilder.sshURL,
            arguments: arguments,
            environment: launchPlanBuilder.baseEnvironment,
            currentDirectoryURL: launchPlanBuilder.currentDirectoryURL
        )
        
        do {
            let task = try processExecuting.start(request, onOutput: { [weak self] stream, data in
                guard let self else { return }
                if stream == .standardError {
                    let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.contains("Address already in use") || text.contains("cannot listen to port") {
                        Task { @MainActor in
                            self.activeStatuses[id] = .failed("Address already in use")
                            self.tasks[id]?.cancel()
                        }
                    } else if text.contains("Connection refused") || text.contains("Could not request local forwarding") {
                        Task { @MainActor in
                            self.activeStatuses[id] = .failed("Connection refused or forwarding denied")
                            self.tasks[id]?.cancel()
                        }
                    } else if text.contains("Authenticated") || text.contains("debug1: Local connections") || text.contains("debug1: channel") {
                        // Sometimes verbose output can indicate success
                    }
                }
            }, completion: { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    self.tasks.removeValue(forKey: id)
                    if case let .failed(msg) = self.activeStatuses[id] {
                        // Keep the failure message if we failed due to a specific matched error string
                    } else {
                        switch result {
                        case let .failure(error):
                            if case .cancelled = error {
                                self.activeStatuses[id] = .idle
                            } else {
                                self.activeStatuses[id] = .failed(error.localizedDescription)
                            }
                        case let .success(res):
                            if res.terminationStatus != 0 {
                                self.activeStatuses[id] = .failed("Process exited with code \(res.terminationStatus)")
                            } else {
                                self.activeStatuses[id] = .idle
                            }
                        }
                    }
                }
            })
            
            tasks[id] = task
            // If it doesn't fail within a short time, we consider it active.
            // Since `ssh -N` blocks and produces no output on success (without -v),
            // a delay transitioning to `.active` is a robust approach.
            Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if self.activeStatuses[id] == .connecting {
                    self.activeStatuses[id] = .active
                }
            }
            
        } catch {
            activeStatuses[id] = .failed(error.localizedDescription)
        }
    }
    
    func stopTunnel(id: UUID) {
        tasks[id]?.cancel()
        tasks.removeValue(forKey: id)
        activeStatuses[id] = .idle
    }
    
    func stopAllTunnels() {
        for (id, task) in tasks {
            task.cancel()
            activeStatuses[id] = .idle
        }
        tasks.removeAll()
    }
}
