import XCTest
@testable import SSHConfigurator

@MainActor
final class TunnelWorkspaceModelTests: XCTestCase {
    
    private final class MockTunnelStore: TunnelPersisting {
        var tunnels: [TunnelDefinition] = []
        var didLoad = false
        var didSave = false
        
        func load() throws -> [TunnelDefinition] {
            didLoad = true
            return tunnels
        }
        
        func save(_ tunnels: [TunnelDefinition]) throws {
            didSave = true
            self.tunnels = tunnels
        }
    }
    
    private final class MockProcessExecuting: SSHProcessExecuting, @unchecked Sendable {
        var requests: [SSHProcessRequest] = []
        var onStart: ((@escaping @Sendable (SSHProcessStream, Data) -> Void) -> Void)?
        
        func start(_ request: SSHProcessRequest, onOutput: @escaping @Sendable (SSHProcessStream, Data) -> Void, completion: @escaping @Sendable (Result<SSHProcessResult, SSHProcessClientError>) -> Void) throws -> any SSHProcessTask {
            requests.append(request)
            onStart?(onOutput)
            return MockTask()
        }
    }
    
    private final class MockTask: SSHProcessTask, @unchecked Sendable {
        var isCancelled = false
        func cancel() {
            isCancelled = true
        }
    }
    
    func testLoadAndSave() throws {
        let store = MockTunnelStore()
        let builder = SSHLaunchPlanBuilder(baseEnvironment: [:])
        let model = TunnelWorkspaceModel(store: store, processExecuting: MockProcessExecuting(), launchPlanBuilder: builder)
        
        XCTAssertFalse(store.didLoad)
        model.load()
        XCTAssertTrue(store.didLoad)
        
        let tunnel = TunnelDefinition(name: "Test", type: .local, targetHostAlias: "server1")
        model.addTunnel(tunnel)
        
        XCTAssertTrue(store.didSave)
        XCTAssertEqual(store.tunnels.count, 1)
        XCTAssertEqual(store.tunnels.first?.name, "Test")
    }
    
    func testLoadStartsAutoConnectTunnels() throws {
        let store = MockTunnelStore()
        store.tunnels = [
            TunnelDefinition(name: "Auto", type: .dynamic, localPort: 1080, targetHostAlias: "server1", autoConnect: true),
            TunnelDefinition(name: "Manual", type: .dynamic, localPort: 1081, targetHostAlias: "server2", autoConnect: false)
        ]
        
        let processExecuting = MockProcessExecuting()
        let builder = SSHLaunchPlanBuilder(baseEnvironment: [:])
        let model = TunnelWorkspaceModel(store: store, processExecuting: processExecuting, launchPlanBuilder: builder)
        
        model.load()
        
        XCTAssertEqual(processExecuting.requests.count, 1)
        XCTAssertEqual(processExecuting.requests.first?.arguments.last, "server1")
    }
    
    func testLoadDoesNotStartDisabledAutoConnectTunnels() {
        let store = MockTunnelStore()
        store.tunnels = [
            TunnelDefinition(name: "Disabled", type: .dynamic, localPort: 1080, targetHostAlias: "server1", isEnabled: false, autoConnect: true)
        ]
        let processExecuting = MockProcessExecuting()
        let model = TunnelWorkspaceModel(
            store: store,
            processExecuting: processExecuting,
            launchPlanBuilder: SSHLaunchPlanBuilder(baseEnvironment: [:])
        )

        model.load()

        XCTAssertTrue(processExecuting.requests.isEmpty)
    }

    func testStartTunnelRejectsInvalidForwardingDefinition() {
        let store = MockTunnelStore()
        let processExecuting = MockProcessExecuting()
        let model = TunnelWorkspaceModel(
            store: store,
            processExecuting: processExecuting,
            launchPlanBuilder: SSHLaunchPlanBuilder(baseEnvironment: [:])
        )
        let tunnel = TunnelDefinition(name: "Invalid", type: .local, targetHostAlias: "server1")
        model.addTunnel(tunnel)

        model.startTunnel(id: tunnel.id)

        XCTAssertTrue(processExecuting.requests.isEmpty)
        XCTAssertEqual(model.activeStatuses[tunnel.id], .failed("Local port must be between 1 and 65535."))
    }

    func testStartTunnel_LocalForward() async throws {
        let store = MockTunnelStore()
        let processExecuting = MockProcessExecuting()
        let builder = SSHLaunchPlanBuilder(baseEnvironment: [:])
        let model = TunnelWorkspaceModel(store: store, processExecuting: processExecuting, launchPlanBuilder: builder)
        
        let tunnel = TunnelDefinition(name: "Test", type: .local, localBindAddress: "127.0.0.1", localPort: 8080, remoteBindAddress: "localhost", remotePort: 80, targetHostAlias: "server1")
        model.addTunnel(tunnel)
        
        model.startTunnel(id: tunnel.id)
        
        XCTAssertEqual(model.activeStatuses[tunnel.id], .connecting)
        XCTAssertEqual(processExecuting.requests.count, 1)
        XCTAssertEqual(processExecuting.requests.first?.arguments, ["-N", "-L", "127.0.0.1:8080:localhost:80", "--", "server1"])
    }
    
    func testStartTunnel_AddressInUse() async throws {
        let store = MockTunnelStore()
        let processExecuting = MockProcessExecuting()
        let builder = SSHLaunchPlanBuilder(baseEnvironment: [:])
        let model = TunnelWorkspaceModel(store: store, processExecuting: processExecuting, launchPlanBuilder: builder)
        
        let tunnel = TunnelDefinition(
            name: "Test",
            type: .local,
            localPort: 8080,
            remoteBindAddress: "localhost",
            remotePort: 80,
            targetHostAlias: "server1"
        )
        model.addTunnel(tunnel)
        
        processExecuting.onStart = { onOutput in
            let errorData = "bind: Address already in use\r\n".data(using: .utf8)!
            onOutput(.standardError, errorData)
        }
        
        model.startTunnel(id: tunnel.id)
        
        try await Task.sleep(nanoseconds: 100_000_000)
        
        XCTAssertEqual(model.activeStatuses[tunnel.id], .failed("Address already in use"))
    }
}
