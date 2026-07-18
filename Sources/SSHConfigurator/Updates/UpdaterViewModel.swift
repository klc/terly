import Combine
import Sparkle
import SwiftUI

/// Ayarlar penceresindeki "Güncellemeler" bölümünü besleyen ince bir sarmalayıcı.
/// Gerçek denetim/indirme/imza doğrulama mantığı tamamen Sparkle'a (`SPUStandardUpdaterController`)
/// bırakılır; burada yalnızca SwiftUI'ya uygun `@Published` durum ve placeholder-anahtar
/// koruması eklenir.
@MainActor
final class UpdaterViewModel: ObservableObject {
    /// `project.yml` içindeki `SUPublicEDKey` placeholder değeriyle birebir aynı olmalı.
    /// Mustafa `generate_keys` ile üretilen gerçek public key'i buraya koyduğunda
    /// `isUpdateChannelConfigured` otomatik olarak `true` döner.
    static let placeholderPublicKey = "REPLACE_WITH_SPARKLE_PUBLIC_KEY"

    private let controller: SPUStandardUpdaterController
    private var cancellables: Set<AnyCancellable> = []

    @Published private(set) var canCheckForUpdates = false

    /// Sparkle'ın kendi kalıcılığını (UserDefaults) kullanan otomatik denetim tercihi.
    /// Değiştirildiğinde doğrudan `SPUUpdater`'a yazılır; okuma da oradan yapılır,
    /// böylece bu görünüm ile başka bir yerden (ör. ileride eklenecek bir menü eylemi)
    /// yapılan değişiklik her zaman senkron kalır.
    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            guard controller.updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates else { return }
            controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    /// Sparkle henüz gerçek bir EdDSA public key ile yapılandırılmadıysa güncelleme
    /// denetimi anlamlı bir sonuç üretemez (appcast imzası asla doğrulanamaz). Bu
    /// placeholder algılandığı sürece arayüz kullanıcıyı bilgilendirir ve gerçek
    /// denetimi tetiklemekten kaçınır — düğmenin kendisi yine de Sparkle'a bağlıdır,
    /// yalnızca placeholder durumunda çağrı yapılmaz.
    var isUpdateChannelConfigured: Bool {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else {
            return false
        }
        return !key.isEmpty && key != Self.placeholderPublicKey
    }

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates

        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
    }

    /// Yalnızca güncelleme kanalı yapılandırılmışken çağrılmalıdır; çağıran taraf
    /// (bkz. `UpdateSettingsView`) placeholder durumunda bunun yerine bir uyarı gösterir.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
