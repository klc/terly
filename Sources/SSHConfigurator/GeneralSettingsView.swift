import SwiftUI

/// App display language override. `system` clears the per-app override so
/// macOS falls back to the user's system/per-app language settings; the
/// other cases write an `AppleLanguages` override into the app's defaults
/// domain. Either way the change only applies after relaunch.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case turkish = "tr"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: String(localized: "System")
        case .english: "English"
        case .turkish: "Türkçe"
        }
    }

    static var current: AppLanguage {
        guard let override = UserDefaults.standard.array(forKey: "AppleLanguages")?.first as? String else {
            return .system
        }
        if override.hasPrefix("tr") { return .turkish }
        if override.hasPrefix("en") { return .english }
        return .system
    }

    func apply() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }
}

struct GeneralSettingsView: View {
    @State private var language: AppLanguage = .current

    var body: some View {
        Form {
            Picker("Language", selection: $language) {
                ForEach(AppLanguage.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .onChange(of: language) { _, newValue in
                newValue.apply()
            }
            Text("The language change takes effect the next time Terly starts.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }
}
