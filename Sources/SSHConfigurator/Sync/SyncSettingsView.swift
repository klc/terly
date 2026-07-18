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
                TextField("Remote URL", text: $remoteURLText, prompt: Text("git@github.com:kullanici/dotfiles.git"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { applyRemoteURL() }
                    .disabled(isBusy)

                HStack {
                    Button("Uygula") { applyRemoteURL() }
                        .disabled(isBusy || remoteURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Şimdi Senkronize Et") {
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

                Toggle("Her commit'ten sonra otomatik push", isOn: Binding(
                    get: { coordinator.autoPushEnabled },
                    set: { coordinator.setAutoPushEnabled($0) }
                ))
                .disabled(!coordinator.isConfigured)
            } header: {
                Text("Senkronizasyon")
            } footer: {
                (
                    Text("Repo ")
                        + Text("private").fontWeight(.semibold)
                        + Text(" olmalı — buraya yazılan her şey uzak repoya commit edilir ve git geçmişi kalıcıdır, silme geri almaz. Özel anahtarlar hiçbir zaman senkronize edilmez.")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                statusRow
                if let aheadBehind = coordinator.aheadBehind, aheadBehind.ahead > 0 || aheadBehind.behind > 0 {
                    Label("\(aheadBehind.ahead) commit ileride, \(aheadBehind.behind) commit geride", systemImage: "arrow.up.arrow.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let lastSyncedAt = coordinator.lastSyncedAt {
                    Label("Son senkronizasyon: \(lastSyncedAt.formatted(date: .abbreviated, time: .shortened))", systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Durum")
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
                    Text("Atlanan dosyalar")
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
                Label("Güncel", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            } else {
                Label("Uzak repo ayarlanmadı", systemImage: "circle.dashed")
                    .foregroundStyle(.secondary)
            }
        case .pendingCommit:
            Label("Değişiklik bekleniyor, birazdan commit edilecek…", systemImage: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
        case .syncing:
            HStack {
                ProgressView().controlSize(.small)
                Text("Senkronize ediliyor…")
            }
            .foregroundStyle(.secondary)
        case .pendingApply:
            Label("Uzaktan gelen değişiklikler inceleme bekliyor", systemImage: "tray.and.arrow.down")
                .foregroundStyle(.blue)
        case .diverged:
            Label("Yerel ve uzak geçmiş ayrıştı — aşağıdan seçim yap", systemImage: "exclamationmark.triangle.fill")
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
                Label("Bu makinede eksik IdentityFile'lar:", systemImage: "key.slash")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                ForEach(coordinator.pendingMissingIdentityFiles, id: \.self) { path in
                    Text(path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("İncele…") { showingDiffPreview = true }
                Spacer()
                Button("Vazgeç") { coordinator.dismissPendingChanges() }
                Button("Uygula") {
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
            Text("İncelemeni bekleyen değişiklikler")
        } footer: {
            Text("Uygulamadan önce mevcut yerel durum otomatik olarak yedeklenir.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var divergenceSection: some View {
        Section {
            Text("Yerel ve uzak repo farklı yönlerde ilerlemiş. Hangisi kalsın?")
                .font(.caption)
            Button("Yereli yedekle, uzaktakini al") {
                resolve(.backupLocalAndTakeRemote)
            }
            Button("Uzaktakini yerelimle değiştir (yeni commit, force yok)", role: .destructive) {
                resolve(.overwriteRemoteWithLocal)
            }
            Button("İptal", role: .cancel) {
                resolve(.cancel)
            }
        } header: {
            Text("Çakışma")
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
