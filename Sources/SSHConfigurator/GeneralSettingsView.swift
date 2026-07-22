import AppKit
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
    @ObservedObject private var recordingSettings = RecordingSettings.shared

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

            Section("Recordings") {
                LabeledContent("Storage location") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(recordingSettings.resolvedRootURL().path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        if recordingSettings.customRootPath == nil {
                            Text("Default")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                HStack {
                    Button("Change…") { chooseRecordingFolder() }
                    Button("Restore Default") {
                        recordingSettings.customRootPath = nil
                    }
                    .disabled(recordingSettings.customRootPath == nil)
                }

                Text("Changing the location does not move existing recordings. New recordings and the Recordings list use the selected folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    private func chooseRecordingFolder() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose Recordings Folder")
        panel.prompt = String(localized: "Choose")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = recordingSettings.resolvedRootURL().deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        recordingSettings.customRootPath = url.path
    }
}
