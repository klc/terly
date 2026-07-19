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
                    Button("Check for Updates") {
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
                    Label("The update channel hasn't been configured yet.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("Check automatically", isOn: $viewModel.automaticallyChecksForUpdates)
            } header: {
                Text("Updates")
            } footer: {
                Text("New versions are checked for automatically in the background while the app is open.")
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
