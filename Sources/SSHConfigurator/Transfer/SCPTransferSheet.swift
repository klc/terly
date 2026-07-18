import AppKit
import SwiftUI

/// Entry-point sheet for enqueuing file/folder transfers.
///
/// Two tabs:
/// - "Yeni Aktarım": file/folder selection form
/// - "Kuyruk": live progress for all queued items
///
/// After items are enqueued the sheet stays open and switches to the Kuyruk tab.
/// "Arkaplanda Devam Et" dismisses the sheet while transfers keep running.
/// Re-opening the sheet when items are active shows the Kuyruk tab immediately.
struct SCPTransferSheet: View {
    let alias: String
    @ObservedObject var workspace: SCPTransferWorkspaceModel
    let hasUnsavedChanges: Bool
    @ObservedObject var queue: TransferQueue
    let engine: TransferQueueEngine

    @Environment(\.dismiss) private var dismiss

    // MARK: Tab

    private enum SheetTab { case newTransfer, queue, history }
    @State private var selectedTab: SheetTab = .newTransfer

    // MARK: Form state

    @State private var direction: SCPTransferDirection = .upload
    @State private var selectedLocalItems: [LocalTransferItem] = []
    @State private var selectedRemoteFile: RemoteFileEntry?
    @State private var downloadLocalURL: URL?
    @State private var remoteDirectory: String
    @State private var showingRemoteBrowser = false
    @State private var shouldPromptForDownloadDestination = false
    @State private var showingLocalOverwriteConfirmation = false
    @State private var validationMessage: String?
    @State private var transferProtocol: TransferProtocol = .scp
    @State private var concurrencyLimit: Int = 3
    @AppStorage("scp.verifyChecksumAfterTransfer") private var verifyChecksumAfterTransfer = false

    private let listingService = SFTPDirectoryListingService()

    init(
        alias: String,
        workspace: SCPTransferWorkspaceModel,
        hasUnsavedChanges: Bool,
        queue: TransferQueue,
        engine: TransferQueueEngine
    ) {
        self.alias = alias
        self.workspace = workspace
        self.hasUnsavedChanges = hasUnsavedChanges
        self.queue = queue
        self.engine = engine
        _remoteDirectory = State(
            initialValue: UserDefaults.standard.string(forKey: Self.remoteDirectoryKey(alias: alias)) ?? ""
        )
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            tabContent
            Divider()
            footer
        }
        .frame(width: 660)
        .frame(minHeight: 480)
        .sheet(isPresented: $showingRemoteBrowser) {
            RemoteFileBrowserSheet(
                alias: alias,
                initialPath: remoteDirectory.isEmpty ? "." : remoteDirectory,
                mode: direction == .upload ? .directory : .file,
                onSelect: handleRemoteSelection
            )
        }
        .onAppear {
            workspace.resetStatus()
            // If there are already running/waiting items, jump straight to the queue tab.
            if queue.hasActiveOrPending {
                selectedTab = .queue
            }
        }
        .onChange(of: showingRemoteBrowser) { _, isShowing in
            guard !isShowing, shouldPromptForDownloadDestination else { return }
            shouldPromptForDownloadDestination = false
            DispatchQueue.main.async { chooseDownloadDestination() }
        }
        .confirmationDialog(
            "Yerel dosyanın üzerine yazılsın mı?",
            isPresented: $showingLocalOverwriteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Üzerine yaz ve indir", role: .destructive) { submitEnqueue() }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Seçilen yerel dosya zaten var ve indirilen dosyayla değiştirilecek.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Dosya aktar")
                    .font(.title2.weight(.semibold))
                Text(alias)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // Tab picker
            Picker("Sekme", selection: $selectedTab) {
                Text("Yeni Aktarım").tag(SheetTab.newTransfer)
                Text(queueTabLabel).tag(SheetTab.queue)
                Text(historyTabLabel).tag(SheetTab.history)
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private var queueTabLabel: String {
        let count = queue.items.count
        return count == 0 ? "Kuyruk" : "Kuyruk (\(count))"
    }

    private var historyTabLabel: String {
        let count = engine.historyLibrary.records.count
        return count == 0 ? "Geçmiş" : "Geçmiş (\(count))"
    }

    // MARK: - Tab content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .newTransfer:
            newTransferForm
        case .queue:
            queueContent
        case .history:
            TransferHistoryView(
                historyLibrary: engine.historyLibrary,
                engine: engine,
                onRetryEnqueued: { selectedTab = .queue }
            )
        }
    }

    // MARK: - New Transfer form

    private var newTransferForm: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("İşlem", selection: $direction) {
                        ForEach(SCPTransferDirection.allCases) { d in
                            Text(d.label).tag(d)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .onChange(of: direction) { _, _ in resetDraft() }
                }

                if direction == .upload {
                    uploadSections
                } else {
                    downloadSections
                }

                Section("Gelişmiş") {
                    Picker("Protokol", selection: $transferProtocol) {
                        ForEach(TransferProtocol.allCases) { proto in
                            Text(proto.label).tag(proto)
                        }
                    }
                    .pickerStyle(.segmented)

                    if transferProtocol.requiresSubsystem {
                        Label(
                            "SFTP sunucuda etkin olmalıdır (sftp-server alt sistemi).",
                            systemImage: "info.circle"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }

                    Stepper("Eşzamanlı aktarım: \(concurrencyLimit)", value: $concurrencyLimit, in: 1 ... 5)

                    Toggle("Aktarım sonrası checksum doğrula", isOn: $verifyChecksumAfterTransfer)
                    Text("Klasör aktarımlarında checksum doğrulaması atlanır.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            // Validation / hint strip
            if let msg = validationMessage ?? workspace.errorMessage {
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Queue tab content

    @ViewBuilder
    private var queueContent: some View {
        if queue.items.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "tray")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text("Kuyrukta aktarım yok")
                    .foregroundStyle(.secondary)
                Button("Yeni Aktarım Ekle") {
                    selectedTab = .newTransfer
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            queueList
        }
    }

    private var queueList: some View {
        VStack(spacing: 0) {
            // Summary bar
            if queue.hasActiveOrPending, let total = queue.totalProgress {
                VStack(spacing: 4) {
                    ProgressView(value: total, total: 1)
                    Text("Toplam ilerleme: %\(Int((total * 100).rounded()))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                Divider()
            }

            List(queue.items) { item in
                InlineTransferItemRow(item: item, engine: engine)
                    .listRowSeparator(.visible)
            }
            .listStyle(.plain)
            .animation(.easeInOut(duration: 0.2), value: queue.items.map(\.id))

            // Batch actions bar
            if !queue.items.allSatisfy(\.isTerminal) {
                Divider()
                HStack(spacing: 12) {
                    Button("Tümünü İptal Et", role: .destructive) { engine.cancelAll() }
                        .controlSize(.small)
                    Spacer()
                    Button("Tamamlananları Temizle") { engine.clearFinished() }
                        .controlSize(.small)
                        .disabled(queue.items.allSatisfy { !$0.isTerminal })
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            // Validate hint in footer only on queue tab
            if selectedTab == .queue && !queue.hasActiveOrPending && !queue.items.isEmpty {
                Button("Listeyi Temizle") { engine.clearFinished() }
                    .controlSize(.small)
            }

            Spacer()

            // "Arkaplanda Devam Et" — visible whenever there are active/waiting transfers
            if queue.hasActiveOrPending {
                Button("Arkaplanda Devam Et") {
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])
            }

            // Primary action depends on tab
            if selectedTab == .newTransfer {
                Button("Kuyruğa Ekle") { enqueueItems() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canEnqueue)
            } else {
                Button("Kapat") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                    .disabled(queue.hasActiveOrPending)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Upload sections

    @ViewBuilder
    private var uploadSections: some View {
        Section("Yerel dosya ve klasörler") {
            if selectedLocalItems.isEmpty {
                Text("Dosya veya klasör seçilmedi")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(selectedLocalItems) { item in
                    HStack(spacing: 8) {
                        Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.url.lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(item.url.deletingLastPathComponent().path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button {
                            selectedLocalItems.removeAll { $0.id == item.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            Button("Dosya veya Klasör Ekle") { chooseLocalItems() }
        }

        Section("Sunucudaki hedef klasör") {
            selectionRow(
                icon: "folder",
                title: remoteDirectory.isEmpty ? "Klasör seçilmedi" : remoteDirectory,
                detail: remoteDirectory.isEmpty ? "Dosyaların yükleneceği uzak klasörü seç" : nil,
                buttonTitle: remoteDirectory.isEmpty ? "Klasör seç" : "Değiştir"
            ) {
                showingRemoteBrowser = true
            }
        }
    }

    // MARK: - Download sections

    @ViewBuilder
    private var downloadSections: some View {
        Section("Sunucudaki dosya") {
            selectionRow(
                icon: "externaldrive.connected.to.line.below",
                title: selectedRemoteFile?.name ?? "Dosya seçilmedi",
                detail: selectedRemoteFile.map { RemotePath.parent(of: $0.path) }
                    ?? "Sunucudaki klasörleri gezerek indirilecek dosyayı seç",
                buttonTitle: selectedRemoteFile == nil ? "Dosya seç" : "Değiştir"
            ) {
                showingRemoteBrowser = true
            }
        }

        Section("Yerel kayıt yeri") {
            selectionRow(
                icon: "folder.badge.plus",
                title: downloadLocalURL?.lastPathComponent ?? "Kayıt yeri seçilmedi",
                detail: downloadLocalURL?.deletingLastPathComponent().path
                    ?? (selectedRemoteFile == nil
                        ? "Önce uzak dosyayı seç"
                        : "Dosya adı hazır olarak getirilecek"),
                buttonTitle: downloadLocalURL == nil ? "Kayıt yeri seç" : "Değiştir"
            ) {
                chooseDownloadDestination()
            }
            .disabled(selectedRemoteFile == nil)
        }
    }

    // MARK: - Shared helpers

    private func selectionRow(
        icon: String,
        title: String,
        detail: String?,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1).truncationMode(.middle)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            Button(buttonTitle, action: action)
        }
    }

    // MARK: - Computed

    private var canEnqueue: Bool {
        switch direction {
        case .upload:
            return !selectedLocalItems.isEmpty && !remoteDirectory.isEmpty
        case .download:
            return selectedRemoteFile != nil && downloadLocalURL != nil
        }
    }

    // MARK: - Actions

    private func enqueueItems() {
        guard canEnqueue else { return }

        if hasUnsavedChanges {
            validationMessage = SCPTransferError.unsavedChanges.localizedDescription
            return
        }

        switch direction {
        case .upload:
            let items = selectedLocalItems.map { local in
                let targetPath = RemotePath.appending(local.url.lastPathComponent, to: remoteDirectory)
                return TransferItem(
                    direction: .upload,
                    alias: alias,
                    localURL: local.url,
                    remotePath: targetPath,
                    isDirectory: local.isDirectory,
                    transferProtocol: transferProtocol,
                    verifyChecksum: verifyChecksumAfterTransfer && !local.isDirectory
                )
            }
            queue.concurrencyLimit = concurrencyLimit
            engine.enqueue(items)
            // Stay open — switch to queue tab so user sees progress.
            resetDraft()
            selectedTab = .queue

        case .download:
            guard let _ = selectedRemoteFile, let localURL = downloadLocalURL else { return }
            if FileManager.default.fileExists(atPath: localURL.path) {
                showingLocalOverwriteConfirmation = true
            } else {
                submitEnqueue()
            }
        }
    }

    private func submitEnqueue() {
        guard let remoteFile = selectedRemoteFile, let localURL = downloadLocalURL else { return }
        let item = TransferItem(
            direction: .download,
            alias: alias,
            localURL: localURL,
            remotePath: remoteFile.path,
            isDirectory: remoteFile.kind == .directory,
            transferProtocol: transferProtocol,
            verifyChecksum: verifyChecksumAfterTransfer && remoteFile.kind != .directory
        )
        queue.concurrencyLimit = concurrencyLimit
        engine.enqueue([item])
        // Stay open — switch to queue tab.
        resetDraft()
        selectedTab = .queue
    }

    private func resetDraft() {
        selectedLocalItems = []
        selectedRemoteFile = nil
        downloadLocalURL = nil
        validationMessage = nil
        workspace.resetStatus()
    }

    private func chooseLocalItems() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if let lastDirectory = UserDefaults.standard.string(forKey: Self.lastUploadDirectoryKey),
           FileManager.default.fileExists(atPath: lastDirectory) {
            panel.directoryURL = URL(fileURLWithPath: lastDirectory, isDirectory: true)
        }
        guard panel.runModal() == .OK else { return }
        let newItems = panel.urls.map { url in
            LocalTransferItem(url: url, isDirectory: directoryCheck(url))
        }
        let existing = Set(selectedLocalItems.map(\.url.path))
        selectedLocalItems += newItems.filter { !existing.contains($0.url.path) }
        if let first = panel.urls.first {
            UserDefaults.standard.set(
                first.deletingLastPathComponent().path,
                forKey: Self.lastUploadDirectoryKey
            )
        }
        validationMessage = nil
    }

    private func chooseDownloadDestination() {
        guard let selectedRemoteFile else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = selectedRemoteFile.name
        if let lastDirectory = UserDefaults.standard.string(forKey: Self.lastDownloadDirectoryKey),
           FileManager.default.fileExists(atPath: lastDirectory) {
            panel.directoryURL = URL(fileURLWithPath: lastDirectory, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        downloadLocalURL = url
        validationMessage = nil
        UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: Self.lastDownloadDirectoryKey)
    }

    private func handleRemoteSelection(_ selection: RemoteFileBrowserSelection) {
        switch selection {
        case let .directory(snapshot):
            remoteDirectory = snapshot.path
            selectedRemoteFile = nil
            UserDefaults.standard.set(snapshot.path, forKey: Self.remoteDirectoryKey(alias: alias))
        case let .file(file):
            selectedRemoteFile = file
            remoteDirectory = RemotePath.parent(of: file.path)
            UserDefaults.standard.set(remoteDirectory, forKey: Self.remoteDirectoryKey(alias: alias))
            downloadLocalURL = nil
            shouldPromptForDownloadDestination = true
        }
        validationMessage = nil
    }

    private func directoryCheck(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return isDir.boolValue
    }

    private static func remoteDirectoryKey(alias: String) -> String {
        "scp.lastRemoteDirectory.\(alias)"
    }

    private static let lastUploadDirectoryKey = "scp.lastLocalUploadDirectory"
    private static let lastDownloadDirectoryKey = "scp.lastLocalDownloadDirectory"
}

// MARK: - Inline queue row (compact variant for use inside the sheet)

private struct InlineTransferItemRow: View {
    let item: TransferItem
    let engine: TransferQueueEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: directionIcon)
                    .foregroundStyle(stateColor)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.displayName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(item.localURL.deletingLastPathComponent().path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                statusLabel
                actionButton
            }

            if item.state == .active {
                if let progress = item.progress {
                    ProgressView(value: progress, total: 1)
                } else {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let rate = item.transferRate {
                    Text(rate)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var directionIcon: String {
        switch item.direction {
        case .upload: return item.isDirectory ? "folder.fill.badge.plus" : "arrow.up.doc.fill"
        case .download: return item.isDirectory ? "folder.badge.arrow.down" : "arrow.down.doc.fill"
        }
    }

    private var stateColor: Color {
        switch item.state {
        case .active: return .accentColor
        case .succeeded: return .green
        case .failed: return .red
        default: return .secondary
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch item.state {
        case .waiting:
            Text("Bekliyor").font(.caption).foregroundStyle(.secondary)
        case .active:
            if let progress = item.progress {
                Text("%\(Int((progress * 100).rounded()))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text("Başlatılıyor…").font(.caption).foregroundStyle(.secondary)
            }
        case .succeeded:
            HStack(spacing: 6) {
                Label("Tamamlandı", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if let checksumState = item.checksumState {
                    ChecksumStatusLabel(state: checksumState)
                }
            }
            .font(.caption)
        case let .failed(msg):
            Label(msg, systemImage: "exclamationmark.circle.fill")
                .font(.caption).foregroundStyle(.red)
                .lineLimit(1)
                .help(msg)
        case .cancelled:
            Text("İptal edildi").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch item.state {
        case .active, .waiting:
            Button {
                engine.cancel(itemID: item.id)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .help("İptal et")
        case .failed, .cancelled:
            Button {
                engine.retry(itemID: item.id)
            } label: {
                Image(systemName: "arrow.clockwise.circle")
            }
            .buttonStyle(.borderless)
            .help("Yeniden dene")
        case .succeeded:
            EmptyView()
        }
    }
}

// MARK: - Local item model

private struct LocalTransferItem: Identifiable {
    let id = UUID()
    let url: URL
    let isDirectory: Bool
}
