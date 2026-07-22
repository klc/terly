import Combine
import Foundation

@MainActor
final class RecordingSettings: ObservableObject {
    static let shared = RecordingSettings()

    private static let rootPathKey = "recordings.rootPath"
    private let defaults: UserDefaults

    @Published var customRootPath: String? {
        didSet {
            if let customRootPath {
                defaults.set(customRootPath, forKey: Self.rootPathKey)
            } else {
                defaults.removeObject(forKey: Self.rootPathKey)
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        customRootPath = defaults.string(forKey: Self.rootPathKey)
    }

    func resolvedRootURL(fileManager: FileManager = .default) -> URL {
        Self.resolveRootURL(customPath: customRootPath, fileManager: fileManager)
    }

    nonisolated static func resolveRootURL(
        customPath: String?,
        fileManager: FileManager = .default
    ) -> URL {
        if let customPath, !customPath.isEmpty {
            let expandedPath = (customPath as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: expandedPath, isDirectory: &isDirectory), isDirectory.boolValue {
                return URL(fileURLWithPath: expandedPath, isDirectory: true)
            }
        }
        return defaultRootURL(fileManager: fileManager)
    }

    nonisolated static func defaultRootURL(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Terly", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
    }
}
