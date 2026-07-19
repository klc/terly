import SwiftUI

/// Ayarlar penceresindeki "Senkronizasyon" sekmesi (WP10). `SyncCoordinator`
/// tek örnek olarak `SSHConfiguratorApp`'te tutulur ve environment üzerinden
/// buraya ve sidebar göstergesine akar — Settings ayrı bir SwiftUI scene
/// olduğu için kendi `@StateObject`'ini oluşturursa debounce/commit
/// döngüsünün iki kopyası aynı anda çalışırdı.
struct SyncSettingsView: View {
    @EnvironmentObject private var coordinator: SyncCoordinator
    @State private var remoteURLText = ""
    @State private var isBusy = false
    @State private var showingDiffPreview = false

    var body: some View {
        Form {
            Section {
                TextField("Remote URL", text: $remoteURLText, prompt: Text("git@github.com:username/dotfiles.git"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { applyRemoteURL() }
                    .disabled(isBusy)

                HStack {
                    Button("Apply") { applyRemoteURL() }
                        .disabled(isBusy || remoteURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Sync Now") {
                        isBusy = true
                        Task {
                            await coordinator.syncNow()
                            isBusy = false
                        }
                    }
                    .disabled(isBusy || !coordinator.isConfigured)
                    if isBusy {
                        ProgressView().controlSize(.small)
                    }
                }

                Toggle("Automatically push after every commit", isOn: Binding(
                    get: { coordinator.autoPushEnabled },
                    set: { coordinator.setAutoPushEnabled($0) }
                ))
                .disabled(!coordinator.isConfigured)
            } header: {
                Text("Sync")
            } footer: {
                (
                    Text("The repo ")
                        + Text("must be private").fontWeight(.semibold)
                        + Text(" — everything written here is committed to the remote repo and the git history is permanent; deleting doesn't undo it. Private keys are never synced.")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                statusRow
                if let aheadBehind = coordinator.aheadBehind, aheadBehind.ahead > 0 || aheadBehind.behind > 0 {
                    Label("\(aheadBehind.ahead) commits ahead, \(aheadBehind.behind) commits behind", systemImage: "arrow.up.arrow.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let lastSyncedAt = coordinator.lastSyncedAt {
                    Label("Last synced: \(lastSyncedAt.formatted(date: .abbreviated, time: .shortened))", systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Status")
            }

            if case .pendingApply = coordinator.status {
                pendingApplySection
            }

            if case .diverged = coordinator.status {
                divergenceSection
            }

            if !coordinator.lastWarnings.isEmpty {
                Section {
                    ForEach(Array(coordinator.lastWarnings.enumerated()), id: \.offset) { _, warning in
                        Label(warning.message, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Skipped Files")
                }
            }
        }
        .padding()
        .frame(width: 520)
        .frame(minHeight: 360, maxHeight: 620)
        .onAppear { remoteURLText = coordinator.remoteURL ?? "" }
        .sheet(isPresented: $showingDiffPreview) {
            SyncApplyPreviewView(diffs: coordinator.pendingDiff) {
                showingDiffPreview = false
            }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch coordinator.status {
        case .idle:
            if coordinator.isConfigured {
                Label("Up to date", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            } else {
                Label("No remote repo configured", systemImage: "circle.dashed")
                    .foregroundStyle(.secondary)
            }
        case .pendingCommit:
            Label("Changes pending, will commit shortly…", systemImage: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
        case .syncing:
            HStack {
                ProgressView().controlSize(.small)
                Text("Syncing…")
            }
            .foregroundStyle(.secondary)
        case .pendingApply:
            Label("Incoming changes are waiting for review", systemImage: "tray.and.arrow.down")
                .foregroundStyle(.blue)
        case .diverged:
            Label("Local and remote history have diverged — choose below", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case let .error(message):
            Label(message, systemImage: "xmark.octagon")
                .foregroundStyle(.red)
                .font(.caption)
        }
    }

    private var pendingApplySection: some View {
        Section {
            ForEach(coordinator.pendingDiff) { diff in
                Label(diff.relativePath, systemImage: diff.kind == .new ? "plus.circle" : "pencil.circle")
                    .font(.caption)
            }

            if !coordinator.pendingMissingIdentityFiles.isEmpty {
                Label("IdentityFile(s) missing on this machine:", systemImage: "key.slash")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                ForEach(coordinator.pendingMissingIdentityFiles, id: \.self) { path in
                    Text(path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Review…") { showingDiffPreview = true }
                Spacer()
                Button("Cancel") { coordinator.dismissPendingChanges() }
                Button("Apply") {
                    isBusy = true
                    Task {
                        await coordinator.applyPendingChanges()
                        isBusy = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isBusy)
                if isBusy {
                    ProgressView().controlSize(.small)
                }
            }
        } header: {
            Text("Changes Waiting for Your Review")
        } footer: {
            Text("The current local state is automatically backed up before applying.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var divergenceSection: some View {
        Section {
            Text("Local and remote repos have diverged. Which one should be kept?")
                .font(.caption)
            Button("Back Up Local, Take Remote") {
                resolve(.backupLocalAndTakeRemote)
            }
            Button("Replace Remote with Local (New Commit, No Force)", role: .destructive) {
                resolve(.overwriteRemoteWithLocal)
            }
            Button("Cancel", role: .cancel) {
                resolve(.cancel)
            }
        } header: {
            Text("Conflict")
        }
    }

    private func resolve(_ choice: SyncApplyChoice) {
        isBusy = true
        Task {
            await coordinator.resolveDivergence(choice)
            isBusy = false
        }
    }

    private func applyRemoteURL() {
        isBusy = true
        Task {
            await coordinator.setRemoteURL(remoteURLText)
            isBusy = false
        }
    }
}
