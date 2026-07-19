import SwiftUI
import SSHConfigCore

struct ContentView: View {
    @StateObject private var model = ConfigViewModel()
    @StateObject private var terminalWorkspace = TerminalWorkspaceModel()
    @StateObject private var terminalEngine = SwiftTermTerminalEngine()
    @StateObject private var transferWorkspace = SCPTransferWorkspaceModel()
    @StateObject private var transferEngine = TransferQueueEngine()
    @StateObject private var tunnelWorkspace = TunnelWorkspaceModel(launchPlanBuilder: SSHLaunchPlanBuilder(baseEnvironment: SSHProcessEnvironment.interactive()))
    @StateObject private var startupFlows = StartupFlowLibrary()
    @StateObject private var quickAccess = QuickAccessLibrary()
    @StateObject private var snippets = SnippetLibrary()
    @StateObject private var runbooks = RunbookLibrary()
    private let hostSettingsApplyCoordinator = HostSettingsApplyCoordinator()
    @State private var showingDeleteConfirmation = false
    @State private var collapsedHostGroupIDs: Set<String> = []
    @State private var editingHostSelection: HostSettingsSelection?
    @State private var connectionGroupEditorSelection: ConnectionGroupEditorSelection?
    @State private var transferSelection: SCPTransferSelection?
    @State private var diagnosticSelection: SSHDiagnosticSelection?
    @State private var keySetupSelection: KeySetupSelection?
    @State private var startupLaunchRequest: StartupLaunchRequest?
    @State private var showingQuickAccess = false
    @State private var pendingQuickAccessRoute: QuickAccessRoute?
    @State private var showingSnippetPalette = false

    var body: some View {
        NavigationSplitView {
            ContentSidebarView(
                model: model,
                startupFlows: startupFlows,
                expansionBinding: expansionBinding,
                onConnectHost: connect,
                onConnectGroup: connect,
                onDuplicateHost: model.duplicateHost,
                onDiagnoseHost: { showDiagnostics(for: $0) },
                onTransferHost: { showTransfer(for: $0) },
                onKeySetupHost: { showKeySetup(for: $0) },
                onShowHostSettings: { showSettings(for: $0) },
                onShowGroupSettings: { showSettings(for: $0) },
                onNewConnectionGroup: showNewConnectionGroupEditor,
                onNewHost: {
                    model.addHost()
                    if let host = model.selectedHost {
                        showSettings(for: host)
                    }
                },
                onDeleteHost: { requestDeleteHost($0) },
                onOpenLocalTerminal: { terminalWorkspace.openLocalTerminal() }
            )
        } detail: {
            ContentDetailView(
                model: model,
                terminalWorkspace: terminalWorkspace,
                terminalEngine: terminalEngine,
                startupFlows: startupFlows,
                tunnelWorkspace: tunnelWorkspace,
                snippets: snippets,
                runbooks: runbooks,
                isHostSettingsSheetPresented: editingHostSelection != nil,
                onRequestTransfer: { showTransfer(forAlias: $0) },
                onDropFilesForUpload: uploadDroppedFiles
            )
            .frame(minWidth: 680, minHeight: 460)
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button("Quick access", systemImage: "magnifyingglass") {
                    showingQuickAccess = true
                }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(model.document == nil)
                .help("Quick access (⌘K)")
                .accessibilityLabel("Quick access")
            }
        }
        .alert(
            "Delete the selected host?",
            isPresented: $showingDeleteConfirmation
        ) {
            Button("Delete", role: .destructive) {
                model.deleteSelectedHost()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The host is permanently removed from ~/.ssh/config. The previous version is kept as a backup.")
        }
        .alert(
            "Operation failed",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.dismissError() } }
            )
        ) {
            Button("OK", role: .cancel) {
                model.dismissError()
            }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert(
            "Terminal could not be opened",
            isPresented: Binding(
                get: { terminalWorkspace.errorMessage != nil },
                set: { if !$0 { terminalWorkspace.dismissError() } }
            )
        ) {
            Button("OK", role: .cancel) {
                terminalWorkspace.dismissError()
            }
        } message: {
            Text(terminalWorkspace.errorMessage ?? "")
        }
        .alert(
            "Startup flow could not be saved",
            isPresented: Binding(
                get: { startupFlows.errorMessage != nil },
                set: { if !$0 { startupFlows.dismissError() } }
            )
        ) {
            Button("OK", role: .cancel) { startupFlows.dismissError() }
        } message: {
            Text(startupFlows.errorMessage ?? "")
        }
        .alert(
            "Quick access metadata could not be saved",
            isPresented: Binding(
                get: { quickAccess.errorMessage != nil },
                set: { if !$0 { quickAccess.dismissError() } }
            )
        ) {
            Button("OK", role: .cancel) { quickAccess.dismissError() }
        } message: {
            Text(quickAccess.errorMessage ?? "")
        }
        .alert(
            "Match exec detected",
            isPresented: Binding(
                get: { model.requiresMatchExecConfirmation },
                set: { if !$0 { model.dismissMatchExecConfirmation() } }
            )
        ) {
            Button("Validate by running the command") {
                model.dismissMatchExecConfirmation()
                model.validateSelectedHost(allowingMatchExec: true)
            }
            Button("Cancel", role: .cancel) {
                model.dismissMatchExecConfirmation()
            }
        } message: {
            Text("ssh -G can run the local command inside Match exec. Make sure you want to continue.")
        }
        .sheet(item: $editingHostSelection, onDismiss: discardUnsavedWorkingCopy) { selection in
            hostSettingsSheet(for: selection)
        }
        .sheet(item: $connectionGroupEditorSelection) { selection in
            ConnectionGroupEditorSheet(
                group: selection.groupID.flatMap { groupID in
                    model.connectionGroups.first { $0.id == groupID }
                },
                connections: model.availableConnections,
                onSave: { name, aliases, openMode in
                    model.saveConnectionGroup(
                        id: selection.groupID,
                        name: name,
                        aliases: aliases,
                        openMode: openMode
                    )
                },
                onDelete: selection.groupID.flatMap { groupID in
                    model.connectionGroups.first { $0.id == groupID }
                }.map { group in
                    { model.deleteConnectionGroup(group) }
                }
            )
        }
        .sheet(item: $transferSelection) { selection in
            SCPTransferSheet(
                alias: selection.alias,
                workspace: transferWorkspace,
                hasUnsavedChanges: model.hasChanges,
                queue: transferEngine.queue,
                engine: transferEngine
            )
        }
        .sheet(item: $diagnosticSelection) { selection in
            if let document = model.document {
                SSHConnectionDiagnosticsView(
                    alias: selection.alias,
                    document: document,
                    onIdentityFileAccepted: { path in
                        applyIdentityFile(path, hostID: selection.id)
                    }
                )
            }
        }
        .sheet(item: $keySetupSelection) { selection in
            KeySetupWizardView(
                alias: selection.alias,
                onIdentityFileAccepted: { path in
                    applyIdentityFile(path, hostID: selection.id)
                }
            )
        }
        .sheet(item: $startupLaunchRequest) { request in
            StartupFlowLaunchPreviewSheet(
                items: request.items,
                onRun: { executeStartupLaunch(request, skipAllStartups: false) },
                onSkip: { executeStartupLaunch(request, skipAllStartups: true) }
            )
        }
        .sheet(
            isPresented: $showingQuickAccess,
            onDismiss: performPendingQuickAccessRoute
        ) {
            QuickAccessPaletteView(
                entries: quickAccessEntries,
                onToggleFavorite: { entryID in
                    _ = quickAccess.toggleFavorite(entryID: entryID)
                },
                onRoute: { route in
                    pendingQuickAccessRoute = route
                    showingQuickAccess = false
                }
            )
        }
        .modifier(RawConfigAccessSupport(model: model))
        .task {
            model.load()
            transferEngine.historyLibrary.load()
            // WP7: the model doesn't own StartupFlowLibrary, so an automatic
            // reconnect looks up the alias's startup profile through here —
            // exactly what a manual reconnect click already gets from the view.
            terminalWorkspace.startupProfileProvider = { startupFlows.profile(for: $0) }
            if let context = startupReconciliationContext {
                startupFlows.load(context: context)
            }
            
            var startupProfiles: [String: StartupFlowProfile] = [:]
            for target in model.availableConnections {
                if let profile = startupFlows.profile(for: target.alias) {
                    startupProfiles[target.alias] = profile
                }
            }
            let validAliases = Set(model.availableConnections.map(\.alias) + model.connectionGroups.map(\.name))
            terminalWorkspace.restoreWorkspace(startupProfiles: startupProfiles, validAliases: validAliases)

            if terminalWorkspace.sessions.isEmpty {
                model.selectedItem = .localTerminal
                terminalWorkspace.openLocalTerminal()
            }

            tunnelWorkspace.load()
            quickAccess.load(catalog: quickAccessCatalog)
            snippets.load()
            runbooks.load()
            collapseAllHostGroups()
        }
        .onChange(of: startupReconciliationContext) { _, context in
            reconcileStartupFlows(context)
        }
        .onChange(of: quickAccessCatalog) { _, catalog in
            quickAccess.reconcile(catalog: catalog)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            tunnelWorkspace.stopAllTunnels()
        }
        .modifier(
            SnippetPaletteSupport(
                snippets: snippets,
                terminalWorkspace: terminalWorkspace,
                showingPalette: $showingSnippetPalette,
                onInsert: insertSnippetValue
            )
        )
    }

    private func insertSnippetValue(_ value: String) {
        guard let session = terminalWorkspace.selectedSession else { return }
        let targets = session.synchronizedPaneIDs.isEmpty
            ? [session.activePaneID]
            : Array(session.synchronizedPaneIDs)
        let bytes = Array(value.utf8)
        for paneID in targets {
            _ = terminalEngine.send(bytes, to: paneID)
        }
    }

    private func expansionBinding(for group: SSHConfigHostGroup) -> Binding<Bool> {
        Binding(
            get: { !collapsedHostGroupIDs.contains(group.id) },
            set: { isExpanded in
                if isExpanded {
                    collapsedHostGroupIDs.remove(group.id)
                } else {
                    collapsedHostGroupIDs.insert(group.id)
                }
            }
        )
    }

    private func collapseAllHostGroups() {
        collapsedHostGroupIDs = Set(model.hostGroups.flatMap(groupIDs(in:)))
    }

    private func groupIDs(in group: SSHConfigHostGroup) -> [String] {
        [group.id] + group.children.flatMap(groupIDs(in:))
    }

    private func connectSelectedHost() {
        guard let host = model.selectedHost else { return }
        connect(host)
    }

    private func requestDeleteHost(_ host: SSHHostBlock) {
        model.selectedItem = .host(host.id)
        showingDeleteConfirmation = true
    }

    private func showTransfer(forAlias alias: String) {
        guard SSHLaunchPlanBuilder.isConcreteAlias(alias) else { return }
        let hostID = model.hosts.first { $0.patterns.contains(alias) }?.id ?? alias.hashValue
        transferSelection = SCPTransferSelection(id: hostID, alias: alias)
    }

    private func uploadDroppedFiles(_ urls: [URL], alias: String) {
        guard SSHLaunchPlanBuilder.isConcreteAlias(alias) else { return }
        guard !model.hasChanges else {
            showTransfer(forAlias: alias)
            return
        }

        let remoteDirectory = SCPTransferSheet.rememberedRemoteDirectory(alias: alias) ?? "."
        let items = urls.map { url in
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return TransferItem(
                direction: .upload,
                alias: alias,
                localURL: url,
                remotePath: RemotePath.appending(url.lastPathComponent, to: remoteDirectory),
                isDirectory: isDirectory,
                transferProtocol: .scp,
                verifyChecksum: false
            )
        }
        guard !items.isEmpty else { return }
        transferEngine.enqueue(items)
        showTransfer(forAlias: alias)
    }

    private func showTransfer(for host: SSHHostBlock?) {
        guard let host,
              let alias = host.patterns.first(where: SSHLaunchPlanBuilder.isConcreteAlias) else {
            return
        }
        transferSelection = SCPTransferSelection(id: host.id, alias: alias)
    }

    private func showDiagnostics(for host: SSHHostBlock?) {
        guard model.prepareForDiagnostics(),
              let host,
              let alias = host.patterns.first(where: SSHLaunchPlanBuilder.isConcreteAlias) else {
            return
        }
        diagnosticSelection = SSHDiagnosticSelection(id: host.id, alias: alias)
    }

    private func showKeySetup(for host: SSHHostBlock?) {
        guard let host,
              let alias = host.patterns.first(where: SSHLaunchPlanBuilder.isConcreteAlias) else {
            return
        }
        keySetupSelection = KeySetupSelection(id: host.id, alias: alias)
    }

    private func applyIdentityFile(_ path: String, hostID: Int) {
        guard let host = model.hosts.first(where: { $0.id == hostID }) else { return }
        model.updateIdentityFile(for: host, path: path)
    }

    private func connect(_ host: SSHHostBlock) {
        let alias = host.patterns.first(where: SSHLaunchPlanBuilder.isConcreteAlias) ?? ""
        let target = SSHConnectionTarget(hostID: host.id, alias: alias)
        requestStartupLaunch(for: .connections([target]))
    }

    private func openConnections(
        _ connections: [SSHConnectionTarget],
        skipAllStartups: Bool
    ) {
        let previousSelection = model.selectedItem
        let profiles = startupProfiles(for: connections)
        let didOpen = terminalWorkspace.openConnections(
            connections,
            hasUnsavedChanges: model.hasChanges,
            startupProfiles: profiles,
            skipAllStartups: skipAllStartups
        )
        if didOpen, let lastConnection = connections.last {
            _ = quickAccess.markUsed(hostAliases: connections.map(\.alias))
            model.selectedItem = .host(lastConnection.hostID)
        } else {
            model.selectedItem = previousSelection
        }
    }

    private func connect(_ group: SSHConnectionGroup) {
        guard let connections = model.connections(in: group) else { return }
        requestStartupLaunch(for: .group(group, connections))
    }

    private func requestStartupLaunch(for destination: StartupLaunchRequest.Destination) {
        let connections: [SSHConnectionTarget]
        switch destination {
        case let .connections(targets):
            connections = targets
        case let .group(_, targets):
            connections = targets
        }

        let items = connections.map {
            StartupFlowLaunchPreviewItem(
                target: $0,
                profile: startupFlows.profile(for: $0.alias)
            )
        }
        guard items.contains(where: { item in
            guard let profile = item.profile else { return false }
            return profile.automaticallyRun && !profile.steps.isEmpty
        }) else {
            executeStartupLaunch(
                StartupLaunchRequest(destination: destination, items: items),
                skipAllStartups: false
            )
            return
        }

        startupLaunchRequest = StartupLaunchRequest(destination: destination, items: items)
    }

    private func open(
        group: SSHConnectionGroup,
        connections: [SSHConnectionTarget],
        skipAllStartups: Bool
    ) {
        let previousSelection = model.selectedItem
        let didOpen: Bool
        let profiles = startupProfiles(for: connections)
        switch group.openMode {
        case .separateTabs:
            didOpen = terminalWorkspace.openConnections(
                connections,
                hasUnsavedChanges: model.hasChanges,
                startupProfiles: profiles,
                skipAllStartups: skipAllStartups
            )
        case .splitPanes:
            didOpen = terminalWorkspace.openConnectionGroupInSplitSession(
                groupID: group.id,
                title: group.name,
                targets: connections,
                hasUnsavedChanges: model.hasChanges,
                startupProfiles: profiles,
                skipAllStartups: skipAllStartups
            )
        }
        if didOpen, let lastConnection = connections.last {
            _ = quickAccess.markUsed(
                hostAliases: connections.map(\.alias),
                groupID: group.id
            )
            model.selectedItem = .host(lastConnection.hostID)
        } else {
            model.selectedItem = previousSelection
        }
    }

    private func executeStartupLaunch(
        _ request: StartupLaunchRequest,
        skipAllStartups: Bool
    ) {
        switch request.destination {
        case let .connections(connections):
            openConnections(connections, skipAllStartups: skipAllStartups)
        case let .group(group, connections):
            open(
                group: group,
                connections: connections,
                skipAllStartups: skipAllStartups
            )
        }
    }

    private func startupProfiles(
        for connections: [SSHConnectionTarget]
    ) -> [String: StartupFlowProfile] {
        Dictionary(uniqueKeysWithValues: connections.compactMap { connection in
            startupFlows.profile(for: connection.alias).map { (connection.alias, $0) }
        })
    }

    private func applyHostSettings(
        _ draft: HostDraft,
        profile: StartupFlowProfile?,
        originalHost: SSHHostBlock
    ) -> Bool {
        guard let prepared = model.prepare(draft, for: originalHost) else { return false }
        let newAlias = draft.patterns
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
            .first(where: SSHLaunchPlanBuilder.isConcreteAlias)

        let originalAlias = originalHost.patterns.first(where: SSHLaunchPlanBuilder.isConcreteAlias)
        return hostSettingsApplyCoordinator.apply(
            preparedConfigSource: prepared.source,
            profile: profile,
            oldAlias: originalAlias,
            newAlias: newAlias,
            persistedAliases: startupReconciliationContext?.persistedAliases ?? [],
            rollbackCatalog: quickAccessCatalog,
            startupFlows: startupFlows,
            quickAccess: quickAccess,
            commitConfigWorkingCopy: {
                model.applyPreparedHostDocument(prepared)
            }
        )
    }

    @ViewBuilder
    private func hostSettingsSheet(for selection: HostSettingsSelection) -> some View {
        if let document = model.document,
           let host = model.hosts.first(where: { $0.id == selection.id }) {
            let availability = StartupFlowEditingPolicy.availability(for: host.patterns)
            HostSettingsSheet(
                host: host,
                document: document,
                startupProfile: startupProfile(for: availability),
                onIdentityFileAccepted: { path in
                    applyIdentityFile(path, hostID: host.id)
                }
            ) { draft, profile in
                applyHostSettings(draft, profile: profile, originalHost: host)
            }
        }
    }

    private func startupProfile(
        for availability: StartupFlowEditingAvailability
    ) -> StartupFlowProfile? {
        guard case let .available(alias) = availability else { return nil }
        return startupFlows.editableProfile(for: alias)
    }

    private func reconcileStartupFlows(_ context: StartupFlowReconciliationContext?) {
        guard let context else { return }
        startupFlows.reconcile(context: context)
    }

    private var startupReconciliationContext: StartupFlowReconciliationContext? {
        guard let document = model.document, let snapshot = model.snapshot else { return nil }
        let persistedDocument = SSHConfigDocument(source: snapshot.source)
        return StartupFlowReconciliationContext(
            workingSource: document.source,
            persistedSource: snapshot.source,
            workingAliases: concreteAliases(in: document),
            persistedAliases: concreteAliases(in: persistedDocument)
        )
    }

    private func concreteAliases(in document: SSHConfigDocument) -> Set<String> {
        Set(document.hostBlocks.flatMap { host in
            host.patterns.filter(SSHLaunchPlanBuilder.isConcreteAlias)
        })
    }

    private var quickAccessCatalog: QuickAccessCatalog {
        QuickAccessCatalog(document: model.document, groups: model.connectionGroups)
    }

    private var quickAccessEntries: [QuickAccessEntry] {
        quickAccess.entries(for: quickAccessCatalog)
    }

    private func handleQuickAccessRoute(_ route: QuickAccessRoute) {
        switch route.target {
        case let .host(_, alias):
            guard let host = model.hosts.first(where: { $0.patterns.contains(alias) }) else {
                return
            }
            switch route.action {
            case .connect:
                connect(host)
            case .settings:
                showSettings(for: host)
            case .transfer:
                showTransfer(for: host)
            case .diagnostics:
                showDiagnostics(for: host)
            }
        case let .group(groupID):
            guard let group = model.connectionGroups.first(where: { $0.id == groupID }) else {
                return
            }
            switch route.action {
            case .connect:
                connect(group)
            case .settings:
                showSettings(for: group)
            case .transfer, .diagnostics:
                break
            }
        }
    }

    private func performPendingQuickAccessRoute() {
        guard let route = pendingQuickAccessRoute else { return }
        pendingQuickAccessRoute = nil
        handleQuickAccessRoute(route)
    }

    private func showSettings(for host: SSHHostBlock) {
        editingHostSelection = HostSettingsSelection(id: host.id)
    }

    // Config mutasyonları artık anında diske yazıldığından, modal kapanışında
    // kalan tek kirli durum kaydedilmemiş taslaktır (ör. Yeni Host iptal edildi,
    // "new-host" placeholder'ı bellekte kaldı). Dosyayla eşitle.
    private func discardUnsavedWorkingCopy() {
        guard model.hasChanges else { return }
        model.restoreSnapshot()
    }

    private func showSettings(for group: SSHConnectionGroup) {
        connectionGroupEditorSelection = ConnectionGroupEditorSelection(
            id: group.id,
            groupID: group.id
        )
    }

    private func showNewConnectionGroupEditor() {
        connectionGroupEditorSelection = ConnectionGroupEditorSelection(
            id: UUID(),
            groupID: nil
        )
    }
}

/// The host/group navigation list. Only observes `model` (host list, selection,
/// matches) and `startupFlows` (orphaned startup records), so publishes from
/// unrelated models (terminal workspace, transfer queue, tunnels, quick access)
/// don't force this subtree to re-render.
private struct ContentSidebarView: View {
    @EnvironmentObject private var syncCoordinator: SyncCoordinator
    @ObservedObject var model: ConfigViewModel
    @ObservedObject var startupFlows: StartupFlowLibrary
    let expansionBinding: (SSHConfigHostGroup) -> Binding<Bool>
    let onConnectHost: (SSHHostBlock) -> Void
    let onConnectGroup: (SSHConnectionGroup) -> Void
    let onDuplicateHost: (SSHHostBlock) -> Void
    let onDiagnoseHost: (SSHHostBlock) -> Void
    let onTransferHost: (SSHHostBlock) -> Void
    let onKeySetupHost: (SSHHostBlock) -> Void
    let onShowHostSettings: (SSHHostBlock) -> Void
    let onShowGroupSettings: (SSHConnectionGroup) -> Void
    let onNewConnectionGroup: () -> Void
    let onNewHost: () -> Void
    let onDeleteHost: (SSHHostBlock) -> Void
    let onOpenLocalTerminal: () -> Void

    var body: some View {
        List(selection: $model.selectedItem) {
            Section("Workspace") {
                Label("Global settings", systemImage: "slider.horizontal.3")
                    .tag(ConfigNavigationItem.global)
                Label("Include files", systemImage: "folder")
                    .tag(ConfigNavigationItem.includes)
                Label("Backup history", systemImage: "clock.arrow.circlepath")
                    .tag(ConfigNavigationItem.backups)
                Label("Tunnels", systemImage: "network")
                    .tag(ConfigNavigationItem.tunnels)
                Label("Snippets", systemImage: "text.badge.plus")
                    .tag(ConfigNavigationItem.snippets)
                Label("Runbooks", systemImage: "list.bullet.rectangle")
                    .tag(ConfigNavigationItem.runbooks)
                Button {
                    onOpenLocalTerminal()
                    model.selectedItem = .localTerminal
                } label: {
                    Label("Local Terminal", systemImage: "terminal")
                }
                .buttonStyle(.plain)
                .tag(ConfigNavigationItem.localTerminal)
            }

            Section {
                ForEach(model.hostGroups) { group in
                    if group.isAutomaticPrefixGroup {
                        HostGroupDisclosure(
                            group: group,
                            isExpanded: expansionBinding(group),
                            expansionBinding: expansionBinding,
                            selectedItem: model.selectedItem,
                            onConnect: onConnectHost,
                            onDuplicate: onDuplicateHost,
                            onDiagnose: onDiagnoseHost,
                            onTransfer: onTransferHost,
                            onKeySetup: onKeySetupHost,
                            onShowSettings: onShowHostSettings,
                            onDelete: onDeleteHost
                        )
                    } else {
                        ForEach(group.hosts) { host in
                            HostNavigationRow(
                                host: host,
                                isSelected: model.selectedItem == .host(host.id),
                                onConnect: { onConnectHost(host) },
                                onDuplicate: { onDuplicateHost(host) },
                                onDiagnose: { onDiagnoseHost(host) },
                                onTransfer: { onTransferHost(host) },
                                onKeySetup: { onKeySetupHost(host) },
                                onShowSettings: { onShowHostSettings(host) },
                                onDelete: { onDeleteHost(host) }
                            )
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Connections")
                    Spacer()
                    Button {
                        onNewHost()
                    } label: {
                        Image(systemName: "plus")
                            .font(.caption)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Add new SSH connection")
                    .accessibilityLabel("Add new SSH connection")
                    .disabled(model.document == nil)
                    .padding(.trailing, 4)
                }
            }

            Section {
                if model.connectionGroups.isEmpty {
                    Button {
                        onNewConnectionGroup()
                    } label: {
                        Label("Create your first group", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.plain)
                } else {
                    ForEach(model.connectionGroups) { group in
                        ConnectionGroupRow(
                            group: group,
                            onConnect: { onConnectGroup(group) },
                            onShowSettings: { onShowGroupSettings(group) }
                        )
                    }
                }
            } header: {
                HStack {
                    Text("Connection groups")
                    Spacer()
                    Button {
                        onNewConnectionGroup()
                    } label: {
                        Image(systemName: "folder.badge.plus")
                            .font(.caption)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Create new connection group")
                    .accessibilityLabel("Create new connection group")
                    .disabled(model.availableConnections.isEmpty)
                    .padding(.trailing, 4)
                }
            }

            StartupFlowOrphanSection(
                records: startupFlows.orphanedRecords,
                aliases: model.availableConnections.map(\.alias),
                onReassign: { profileID, alias in
                    startupFlows.reassign(profileID: profileID, to: alias)
                }
            )

            if !model.matches.isEmpty {
                Section("Match rules") {
                    ForEach(model.matches) { match in
                        Label(match.displayName, systemImage: "arrow.triangle.branch")
                            .tag(ConfigNavigationItem.match(match.id))
                    }
                }
            }
        }
        .navigationTitle("SSH Config")
        .safeAreaInset(edge: .bottom) {
            if syncCoordinator.isConfigured {
                SyncStatusFooter(status: syncCoordinator.status)
            }
        }
    }
}

/// Small persistent strip at the bottom of the sidebar reflecting
/// `SyncCoordinator.status` — only shown once a remote is configured, so it
/// stays invisible for anyone not using WP10 sync. Clicking it opens the
/// Senkronizasyon settings tab.
private struct SyncStatusFooter: View {
    let status: SyncStatus
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button {
            openSettings()
        } label: {
            HStack(spacing: 6) {
                icon
                Text(label)
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
            }
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open sync settings")
    }

    @ViewBuilder
    private var icon: some View {
        switch status {
        case .idle:
            Image(systemName: "checkmark.circle")
        case .pendingCommit:
            Image(systemName: "clock.arrow.circlepath")
        case .syncing:
            ProgressView().controlSize(.mini)
        case .pendingApply:
            Image(systemName: "tray.and.arrow.down")
        case .diverged:
            Image(systemName: "exclamationmark.triangle.fill")
        case .error:
            Image(systemName: "xmark.octagon")
        }
    }

    private var label: String {
        switch status {
        case .idle: return String(localized: "Synced")
        case .pendingCommit: return String(localized: "Change pending…")
        case .syncing: return String(localized: "Syncing…")
        case .pendingApply: return String(localized: "There's a change waiting for your review")
        case .diverged: return String(localized: "Conflict — resolution needed")
        case .error: return String(localized: "Sync error")
        }
    }

    private var color: Color {
        switch status {
        case .idle: return .secondary
        case .pendingCommit, .syncing: return .secondary
        case .pendingApply: return .blue
        case .diverged: return .orange
        case .error: return .red
        }
    }
}

/// The main detail pane: terminal surface plus the non-host editors (global,
/// includes, backups, tunnels, match blocks, raw preview). Only observes the
/// models this subtree actually renders with, so e.g. sidebar-only or
/// transfer-queue-only publishes don't force this pane to re-render.
private struct ContentDetailView: View {
    @ObservedObject var model: ConfigViewModel
    @ObservedObject var terminalWorkspace: TerminalWorkspaceModel
    @ObservedObject var terminalEngine: SwiftTermTerminalEngine
    @ObservedObject var startupFlows: StartupFlowLibrary
    @ObservedObject var tunnelWorkspace: TunnelWorkspaceModel
    @ObservedObject var snippets: SnippetLibrary
    @ObservedObject var runbooks: RunbookLibrary
    let isHostSettingsSheetPresented: Bool
    let onRequestTransfer: (String) -> Void
    let onDropFilesForUpload: ([URL], String) -> Void

    var body: some View {
        if let document = model.document {
            VStack(spacing: 0) {
                ZStack {
                    let terminalIsVisible = model.selectedHost != nil || model.selectedItem == .localTerminal
                    TerminalWorkspaceView(
                        model: terminalWorkspace,
                        startupLibrary: startupFlows,
                        engine: terminalEngine,
                        isActive: terminalIsVisible && !isHostSettingsSheetPresented,
                        isVisible: terminalIsVisible,
                        onRequestTransfer: onRequestTransfer,
                        onDropFilesForUpload: onDropFilesForUpload
                    )
                    .opacity(terminalIsVisible ? 1 : 0)
                    .allowsHitTesting(terminalIsVisible)
                    .accessibilityHidden(!terminalIsVisible)

                    if model.selectedHost == nil && model.selectedItem != .localTerminal {
                        if model.hosts.isEmpty && model.selectedItem == nil {
                            ContentUnavailableView(
                                "Add your first server",
                                systemImage: "server.rack",
                                description: Text("Tap the + button in the left menu to create a new SSH connection.")
                            )
                        } else {
                            nonHostDetail(document: document)
                        }
                    }
                }
            }
        } else if let errorMessage = model.errorMessage {
            ContentUnavailableView(
                "Config could not be loaded",
                systemImage: "exclamationmark.triangle",
                description: Text(errorMessage)
            )
        } else {
            ContentUnavailableView(
                "Waiting for SSH config",
                systemImage: "terminal",
                description: Text("Loading the ~/.ssh/config file."))
        }
    }

    @ViewBuilder
    private func nonHostDetail(document: SSHConfigDocument) -> some View {
        if let match = model.selectedMatch {
            SectionSourceEditor(
                title: match.displayName,
                source: document.source(for: match),
                message: String(localized: "This block only applies when the selected Match condition is met.")
            ) { source in
                model.replaceMatchSource(match, with: source)
            }
            .id(match.id)
        } else if model.selectedItem == .global {
            SectionSourceEditor(
                title: String(localized: "Global settings"),
                source: document.globalSource,
                message: String(localized: "These lines appear before the first Host or Match block.")
            ) { source in
                model.replaceGlobalSource(with: source)
            }
        } else if model.selectedItem == .includes {
            IncludesEditorView(
                includes: model.includes,
                onAdd: model.addInclude,
                onUpdate: model.updateInclude,
                onRemove: model.removeInclude
            )
        } else if model.selectedItem == .backups {
            BackupHistoryView(
                backups: model.backups,
                currentSource: document.source,
                previewedBackup: model.previewedBackup,
                previewedSource: model.previewedBackupSource,
                onSelect: model.selectBackup,
                onRestore: model.restore,
                onRefresh: model.refreshBackups
            )
        } else if model.selectedItem == .tunnels {
            TunnelListView(
                model: tunnelWorkspace,
                availableHosts: model.availableConnections.map(\.alias)
            )
        } else if model.selectedItem == .snippets {
            SnippetListView(library: snippets)
        } else if model.selectedItem == .runbooks {
            RunbookListView(
                library: runbooks,
                availableConnections: model.availableConnections,
                connectionGroups: model.connectionGroups
            )
        } else {
            ConfigPreviewView(source: document.source)
                .padding(24)
        }
    }
}

private struct HostSettingsSelection: Identifiable {
    let id: Int
}

private struct ConnectionGroupEditorSelection: Identifiable {
    let id: UUID
    let groupID: UUID?
}

private struct SCPTransferSelection: Identifiable {
    let id: Int
    let alias: String
}

private struct SSHDiagnosticSelection: Identifiable {
    let id: Int
    let alias: String
}

private struct KeySetupSelection: Identifiable {
    let id: Int
    let alias: String
}

private struct StartupLaunchRequest: Identifiable {
    enum Destination {
        case connections([SSHConnectionTarget])
        case group(SSHConnectionGroup, [SSHConnectionTarget])
    }

    let id = UUID()
    let destination: Destination
    let items: [StartupFlowLaunchPreviewItem]
}

private struct ConnectionGroupRow: View {
    let group: SSHConnectionGroup
    let onConnect: () -> Void
    let onShowSettings: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onConnect) {
                HStack(spacing: 8) {
                    Label(group.name, systemImage: "folder.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(group.aliases.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Image(systemName: "play.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open all SSH connections in the group")
            .accessibilityLabel("Open \(group.aliases.count) SSH connections in \(group.name)")
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Connect", systemImage: "play", action: onConnect)
            Button("Open settings", systemImage: "gearshape", action: onShowSettings)
        }
    }
}

private struct HostNavigationRow: View {
    let host: SSHHostBlock
    let isSelected: Bool
    let onConnect: () -> Void
    let onDuplicate: () -> Void
    let onDiagnose: () -> Void
    let onTransfer: () -> Void
    let onKeySetup: () -> Void
    let onShowSettings: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onConnect) {
                Label(host.displayName, systemImage: host.isPattern ? "asterisk" : "server.rack")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(host.displayName) SSH connection")
        }
        .padding(.vertical, 2)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
        .contextMenu {
            if host.patterns.contains(where: SSHLaunchPlanBuilder.isConcreteAlias) {
                Button("Test connection", systemImage: "stethoscope", action: onDiagnose)
                Button("Transfer files", systemImage: "arrow.left.arrow.right", action: onTransfer)
                Button("Key setup…", systemImage: "key", action: onKeySetup)
            }
            Button("Duplicate connection", systemImage: "plus.square.on.square", action: onDuplicate)
            Button("Open settings", systemImage: "gearshape", action: onShowSettings)
            Divider()
            Button("Delete Host", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }
}

private struct HostGroupDisclosure: View {
    let group: SSHConfigHostGroup
    let isExpanded: Binding<Bool>
    let expansionBinding: (SSHConfigHostGroup) -> Binding<Bool>
    let selectedItem: ConfigNavigationItem?
    let onConnect: (SSHHostBlock) -> Void
    let onDuplicate: (SSHHostBlock) -> Void
    let onDiagnose: (SSHHostBlock) -> Void
    let onTransfer: (SSHHostBlock) -> Void
    let onKeySetup: (SSHHostBlock) -> Void
    let onShowSettings: (SSHHostBlock) -> Void
    let onDelete: (SSHHostBlock) -> Void

    var body: some View {
        DisclosureGroup(isExpanded: isExpanded) {
            ForEach(group.hosts) { host in
                HostNavigationRow(
                    host: host,
                    isSelected: selectedItem == .host(host.id),
                    onConnect: { onConnect(host) },
                    onDuplicate: { onDuplicate(host) },
                    onDiagnose: { onDiagnose(host) },
                    onTransfer: { onTransfer(host) },
                    onKeySetup: { onKeySetup(host) },
                    onShowSettings: { onShowSettings(host) },
                    onDelete: { onDelete(host) }
                )
            }

            ForEach(group.children) { child in
                HostGroupDisclosure(
                    group: child,
                    isExpanded: expansionBinding(child),
                    expansionBinding: expansionBinding,
                    selectedItem: selectedItem,
                    onConnect: onConnect,
                    onDuplicate: onDuplicate,
                    onDiagnose: onDiagnose,
                    onTransfer: onTransfer,
                    onKeySetup: onKeySetup,
                    onShowSettings: onShowSettings,
                    onDelete: onDelete
                )
            }
        } label: {
            HStack(spacing: 8) {
                Label(group.label ?? "Group", systemImage: "folder.fill")
                Spacer()
                Text("\(group.hosts.count + group.children.reduce(0) { $0 + hostCount(in: $1) })")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("\(group.label ?? "SSH") connection group")
        .accessibilityValue("\(hostCount(in: group)) connections")
    }

    private func hostCount(in group: SSHConfigHostGroup) -> Int {
        group.hosts.count + group.children.reduce(0) { $0 + hostCount(in: $1) }
    }
}

private struct ConnectionGroupEditorSheet: View {
    let group: SSHConnectionGroup?
    let connections: [SSHConnectionTarget]
    let onSave: (String, [String], SSHConnectionGroupOpenMode) -> Bool
    let onDelete: (() -> Bool)?

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var selectedAliases: Set<String>
    @State private var openMode: SSHConnectionGroupOpenMode
    @State private var showingDeleteConfirmation = false

    init(
        group: SSHConnectionGroup?,
        connections: [SSHConnectionTarget],
        onSave: @escaping (String, [String], SSHConnectionGroupOpenMode) -> Bool,
        onDelete: (() -> Bool)?
    ) {
        self.group = group
        self.connections = connections
        self.onSave = onSave
        self.onDelete = onDelete
        _name = State(initialValue: group?.name ?? "")
        _selectedAliases = State(initialValue: Set(group?.aliases ?? []))
        _openMode = State(initialValue: group?.openMode ?? .separateTabs)
    }

    private var availableAliases: Set<String> {
        Set(connections.map(\.alias))
    }

    private var unavailableAliases: [String] {
        selectedAliases
            .subtracting(availableAliases)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !selectedAliases.isEmpty &&
            unavailableAliases.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                systemImage: group == nil ? "folder.badge.plus" : "folder.fill",
                title: group == nil ? String(localized: "Create connection group") : String(localized: "Edit connection group"),
                subtitle: Text("Opening the group starts all selected connections together.").font(.caption),
                onClose: { dismiss() }
            )

            Divider()

            Form {
                Section("Group") {
                    TextField("Group name", text: $name, prompt: Text("Prod Servers"))
                        .editorFieldStyle()
                }

                Section("Window layout") {
                    Picker("Open connections", selection: $openMode) {
                        ForEach(SSHConnectionGroupOpenMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)

                    Text(
                        openMode == .separateTabs
                            ? String(localized: "Each connection opens in its own terminal tab.")
                            : String(localized: "All connections open in one tab, carrying the group name, in separate panes.")
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                Section("Connections") {
                    if connections.isEmpty {
                        Text("No concrete SSH alias found to add to the group.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(connections) { connection in
                            Toggle(
                                connection.alias,
                                isOn: selectionBinding(for: connection.alias)
                            )
                        }
                    }
                }

                if !unavailableAliases.isEmpty {
                    Section("Not found in config") {
                        ForEach(unavailableAliases, id: \.self) { alias in
                            HStack {
                                Label(alias, systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Spacer()
                                Button("Remove") {
                                    selectedAliases.remove(alias)
                                }
                            }
                        }
                        Text("Remove connections that no longer exist to save the group.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                if onDelete != nil {
                    Button("Delete Group", role: .destructive) {
                        showingDeleteConfirmation = true
                    }
                }

                Text("\(selectedAliases.count) connections selected")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                Button(group == nil ? "Create Group" : "Save Changes") {
                    let aliases = connections
                        .map(\.alias)
                        .filter(selectedAliases.contains)
                    if onSave(name, aliases, openMode) {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding()
        }
        .frame(minWidth: 560, minHeight: 560)
        .confirmationDialog(
            "Delete the connection group?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Group", role: .destructive) {
                if onDelete?() == true {
                    dismiss()
                }
            }
        } message: {
            Text("SSH connections and the config file are unchanged; only this group is deleted.")
        }
    }

    private func selectionBinding(for alias: String) -> Binding<Bool> {
        Binding(
            get: { selectedAliases.contains(alias) },
            set: { isSelected in
                if isSelected {
                    selectedAliases.insert(alias)
                } else {
                    selectedAliases.remove(alias)
                }
            }
        )
    }
}

private struct HostSettingsSheet: View {
    let host: SSHHostBlock
    let document: SSHConfigDocument
    let startupProfile: StartupFlowProfile?
    let onIdentityFileAccepted: (String) -> Void
    let onApply: (HostDraft, StartupFlowProfile?) -> Bool

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                systemImage: "gearshape.fill",
                title: host.displayName,
                subtitle: Text("SSH connection settings").font(.caption),
                onClose: { dismiss() }
            )

            Divider()

            HostEditorView(
                host: host,
                document: document,
                startupProfile: startupProfile,
                onIdentityFileAccepted: onIdentityFileAccepted,
                onApply: onApply
            )
                .id(host.id)
        }
        .frame(minWidth: 560, minHeight: 500)
    }
}

private struct HostEditorView: View {
    let host: SSHHostBlock
    let document: SSHConfigDocument
    let onIdentityFileAccepted: (String) -> Void
    let onApply: (HostDraft, StartupFlowProfile?) -> Bool

    @State private var draft: HostDraft
    @State private var startupProfile: StartupFlowProfile?
    @State private var showingKeySetupWizard = false

    init(
        host: SSHHostBlock,
        document: SSHConfigDocument,
        startupProfile: StartupFlowProfile?,
        onIdentityFileAccepted: @escaping (String) -> Void,
        onApply: @escaping (HostDraft, StartupFlowProfile?) -> Bool
    ) {
        self.host = host
        self.document = document
        self.onIdentityFileAccepted = onIdentityFileAccepted
        self.onApply = onApply
        _draft = State(initialValue: HostDraft(host: host, document: document))
        _startupProfile = State(initialValue: startupProfile)
    }

    var body: some View {
        Form {
            Section("Identity") {
                TextField("Alias / pattern", text: $draft.patterns, prompt: Text("e.g. web-prod"))
                    .editorFieldStyle()
                TextField("HostName", text: $draft.hostName, prompt: Text("e.g. 192.168.1.10"))
                    .editorFieldStyle()
                TextField("User", text: $draft.user, prompt: Text("e.g. root"))
                    .editorFieldStyle()
                TextField("Port", text: $draft.port, prompt: Text("e.g. 22"))
                    .editorFieldStyle()
            }

            Section("Connection") {
                TextField("IdentityFile", text: $draft.identityFile, prompt: Text("e.g. ~/.ssh/id_ed25519"))
                    .editorFieldStyle()
                TextField("ProxyJump", text: $draft.proxyJump, prompt: Text("e.g. bastion"))
                    .editorFieldStyle()
            }

            Section("Key Setup") {
                Button("Key setup…", systemImage: "key") {
                    showingKeySetupWizard = true
                }
                .disabled(currentAlias == nil)
                Text("Generates a new ed25519 key, optionally adds it to the SSH agent, and copies it to the server's authorized_keys file.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if startupProfile != nil,
               case .available = currentStartupAvailability {
                StartupFlowOptionalEditorView(profile: $startupProfile)
            } else if case let .unavailable(message) = currentStartupAvailability {
                Section("Startup Flow") {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            } else if case let .available(alias) = currentStartupAvailability {
                Section("Startup Flow") {
                    Label(
                        "Preparing startup flow for \(alias).",
                        systemImage: "hourglass"
                    )
                    .foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Apply Changes") {
                    _ = onApply(draft, applicableStartupProfile)
                }
                Text("Empty base fields are removed from this Host block. You can edit all other OpenSSH directives from the Raw Config screen.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(host.displayName)
        .onChange(of: draft.patterns) { _, _ in
            guard startupProfile == nil,
                  case let .available(alias) = currentStartupAvailability else { return }
            startupProfile = StartupFlowProfile(alias: alias)
        }
        .sheet(isPresented: $showingKeySetupWizard) {
            if let currentAlias {
                KeySetupWizardView(
                    alias: currentAlias,
                    onIdentityFileAccepted: { path in
                        draft.identityFile = path
                        onIdentityFileAccepted(path)
                    }
                )
            }
        }
    }

    private var currentAlias: String? {
        draft.patterns
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
            .first(where: SSHLaunchPlanBuilder.isConcreteAlias)
    }

    private var currentStartupAvailability: StartupFlowEditingAvailability {
        let aliases = draft.patterns
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        return StartupFlowEditingPolicy.availability(for: aliases)
    }

    private var applicableStartupProfile: StartupFlowProfile? {
        guard case .available = currentStartupAvailability else { return nil }
        return startupProfile
    }
}

/// Adds the menu-triggered raw config editor and change-preview sheets to the
/// root view. Extracted into a modifier so the main view body stays within
/// the Swift type-checker's complexity budget.
private struct RawConfigAccessSupport: ViewModifier {
    @ObservedObject var model: ConfigViewModel

    @State private var showingRawConfigEditor = false
    @State private var showingChangePreview = false

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showingRawConfigEditor) {
                RawConfigEditor(
                    source: model.document?.source ?? "",
                    onApply: { model.replaceSource(with: $0) }
                )
            }
            .sheet(isPresented: $showingChangePreview) {
                ChangePreviewView(
                    original: model.snapshot?.source ?? "",
                    updated: model.document?.source ?? ""
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: .showRawConfigEditorRequested)) { _ in
                guard model.document != nil else { return }
                showingRawConfigEditor = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .showChangePreviewRequested)) { _ in
                guard model.document != nil else { return }
                showingChangePreview = true
            }
    }
}

private struct RawConfigEditor: View {
    let source: String
    let onApply: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: String

    init(source: String, onApply: @escaping (String) -> Void) {
        self.source = source
        self.onApply = onApply
        _draft = State(initialValue: source)
    }

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $draft)
                .font(.system(.body, design: .monospaced))
                .padding(12)

            Divider()
            HStack {
                Text("Applying writes the change to ~/.ssh/config immediately; the previous content is backed up.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Apply and save") {
                    onApply(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 720, minHeight: 540)
    }
}

private struct SectionSourceEditor: View {
    let title: String
    let source: String
    let message: String
    let onApply: (String) -> Void

    @State private var draft: String

    init(title: String, source: String, message: String, onApply: @escaping (String) -> Void) {
        self.title = title
        self.source = source
        self.message = message
        self.onApply = onApply
        _draft = State(initialValue: source)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2.bold())

            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)

            TextEditor(text: $draft)
                .font(.system(.body, design: .monospaced))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.quaternary)
                }

            HStack {
                Spacer()
                Button("Apply Changes") {
                    onApply(draft)
                }
            }
        }
        .padding(24)
    }
}

private struct IncludesEditorView: View {
    let includes: [SSHConfigInclude]
    let onAdd: (String) -> Void
    let onUpdate: (SSHConfigInclude, String) -> Void
    let onRemove: (SSHConfigInclude) -> Void

    @State private var newPath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Include files")
                .font(.title2.bold())

            Text("OpenSSH includes the files in these lines in the config read flow.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            List {
                ForEach(includes) { include in
                    IncludeRow(
                        include: include,
                        onUpdate: { path in onUpdate(include, path) },
                        onRemove: { onRemove(include) }
                    )
                }
            }
            .frame(minHeight: 220)

            HStack {
                TextField("New include path", text: $newPath, prompt: Text("e.g. ~/.ssh/config.d/*"))
                    .editorFieldStyle()
                Button("Add") {
                    onAdd(newPath)
                    newPath = ""
                }
                .disabled(newPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
    }
}

private struct BackupHistoryView: View {
    let backups: [SSHConfigBackup]
    let currentSource: String
    let previewedBackup: SSHConfigBackup?
    let previewedSource: String?
    let onSelect: (SSHConfigBackup?) -> Void
    let onRestore: (SSHConfigBackup) -> Void
    let onRefresh: () -> Void

    @State private var selectedID: SSHConfigBackup.ID?
    @State private var showingRestoreConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Backup history")
                        .font(.title2.bold())
                    Text("Restoring first saves the current config as a new backup.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") {
                    onRefresh()
                }
            }

            HStack(spacing: 16) {
                List(selection: $selectedID) {
                    ForEach(backups) { backup in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(backup.createdAt, format: .dateTime.day().month().year().hour().minute().second())
                            Text(ByteCountFormatter.string(fromByteCount: Int64(backup.byteCount), countStyle: .file))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(backup.id)
                    }
                }
                .frame(minWidth: 250, maxWidth: 310)
                .onChange(of: selectedID) { _, selectedID in
                    onSelect(backups.first { $0.id == selectedID })
                }

                if let previewedBackup, let previewedSource {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Selected backup")
                                .font(.headline)
                            Spacer()
                            Button("Restore this backup", role: .destructive) {
                                showingRestoreConfirmation = true
                            }
                        }

                        HStack(spacing: 0) {
                            SourceColumn(title: String(localized: "Current config"), source: currentSource)
                            Divider()
                            SourceColumn(title: String(localized: "Backup"), source: previewedSource)
                        }
                    }
                    .confirmationDialog(
                        "Restore this backup?",
                        isPresented: $showingRestoreConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Restore", role: .destructive) {
                            onRestore(previewedBackup)
                            selectedID = nil
                        }
                    } message: {
                        Text("The current config is saved as a new backup first; the restore is applied atomically.")
                    }
                } else {
                    ContentUnavailableView(
                        "No backup selected",
                        systemImage: "clock.arrow.circlepath",
                        description: Text(backups.isEmpty ? String(localized: "No backups yet. It'll show up here after your first save.") : String(localized: "Select a backup to compare or restore."))
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(24)
    }
}

private struct IncludeRow: View {
    let include: SSHConfigInclude
    let onUpdate: (String) -> Void
    let onRemove: () -> Void

    @State private var path: String

    init(include: SSHConfigInclude, onUpdate: @escaping (String) -> Void, onRemove: @escaping () -> Void) {
        self.include = include
        self.onUpdate = onUpdate
        self.onRemove = onRemove
        _path = State(initialValue: include.value)
    }

    var body: some View {
        HStack {
            TextField("Include path", text: $path, prompt: Text("e.g. ~/.ssh/config.d/*"))
                .editorFieldStyle()
            Text(include.scope.rawValue)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Apply") {
                onUpdate(path)
            }
            Button(role: .destructive) {
                onRemove()
            } label: {
                Image(systemName: "trash")
            }
            .help("Remove this include line")
        }
    }
}

private struct ChangePreviewView: View {
    let original: String
    let updated: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Compare the file on disk with the working copy")
                    .font(.headline)
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding()

            Divider()

            HStack(spacing: 0) {
                SourceColumn(title: String(localized: "Current file"), source: original)
                Divider()
                SourceColumn(title: String(localized: "Working copy"), source: updated)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}

private struct SourceColumn: View {
    let title: String
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(12)

            Divider()

            ScrollView([.horizontal, .vertical]) {
                Text(source.isEmpty ? String(localized: "(empty config)") : source)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct ConfigPreviewView: View {
    let source: String

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(source.isEmpty ? String(localized: "(empty config)") : source)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
