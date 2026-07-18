import SwiftUI

/// Ayarlar penceresindeki "Güncellemeler" sekmesi: Sparkle üzerinden manuel/otomatik
/// güncelleme denetimi. Public key placeholder'ken (bkz. `UpdaterViewModel`) denetim
/// düğmesi Sparkle'a bağlı kalır ama tıklanınca gerçek çağrı yapılmaz; bunun yerine
/// kullanıcıya kanalın henüz yapılandırılmadığı gösterilir.
struct UpdateSettingsView: View {
    @StateObject private var viewModel = UpdaterViewModel()
    @State private var isChecking = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    Button("Güncellemeleri Denetle") {
                        guard viewModel.isUpdateChannelConfigured else { return }
                        isChecking = true
                        viewModel.checkForUpdates()
                    }
                    .disabled(!viewModel.canCheckForUpdates || isChecking)

                    if isChecking {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if !viewModel.isUpdateChannelConfigured {
                    Label("Güncelleme kanalı henüz yapılandırılmadı.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("Otomatik denetle", isOn: $viewModel.automaticallyChecksForUpdates)
            } header: {
                Text("Güncellemeler")
            } footer: {
                Text("Uygulama açık kaldığı sürece arka planda otomatik olarak yeni sürüm denetlenir.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(width: 520)
        .onChange(of: viewModel.canCheckForUpdates) { _, canCheck in
            if canCheck { isChecking = false }
        }
    }
}
