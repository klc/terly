import SwiftUI

extension Notification.Name {
    static let showRawConfigEditorRequested = Notification.Name("Terly.showRawConfigEditorRequested")
    static let showChangePreviewRequested = Notification.Name("Terly.showChangePreviewRequested")
    /// Posted by any store whose content belongs to the WP10 sync set right
    /// after a successful save — `SyncCoordinator` observes this to debounce
    /// a local commit. One shared instance observes it (see below); a
    /// per-scene `SyncCoordinator` would double the debounce/commit cycle.
    static let syncableDataDidChange = Notification.Name("Terly.syncableDataDidChange")
}

@main
struct SSHConfiguratorApp: App {
    @StateObject private var syncCoordinator = SyncCoordinator()

    init() {
        Self.migrateLegacyApplicationSupportDirectoryIfNeeded()
    }

    /// Uygulamanın eski adından ("SSH Configurator") kalan Application Support
    /// klasörünü yeni "Terly" konumuna taşır. Yalnızca yeni klasör henüz yokken
    /// çalışır; ikisi de varsa eski klasöre dokunulmaz ki hiçbir veri ezilmesin.
    /// Store'lar klasörü lazily oluşturduğu için bu, herhangi bir store
    /// okumadan önce (`@StateObject` ilk body çiziminde kurulur) çağrılmalıdır.
    private static func migrateLegacyApplicationSupportDirectoryIfNeeded() {
        let fileManager = FileManager.default
        guard let appSupport = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first else { return }
        let legacy = appSupport.appendingPathComponent("SSH Configurator", isDirectory: true)
        let current = appSupport.appendingPathComponent("Terly", isDirectory: true)
        guard fileManager.fileExists(atPath: legacy.path),
              !fileManager.fileExists(atPath: current.path) else { return }
        try? fileManager.moveItem(at: legacy, to: current)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(syncCoordinator)
                .onReceive(NotificationCenter.default.publisher(for: .syncableDataDidChange)) { _ in
                    syncCoordinator.noteChange()
                }
                .task {
                    await syncCoordinator.pull()
                }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .newItem) {
                Divider()
                Button("Raw Config Editor…") {
                    NotificationCenter.default.post(name: .showRawConfigEditorRequested, object: nil)
                }
                Button("Change History/Preview…") {
                    NotificationCenter.default.post(name: .showChangePreviewRequested, object: nil)
                }
            }
        }

        Settings {
            TabView {
                GeneralSettingsView()
                    .tabItem {
                        Label("General", systemImage: "gearshape")
                    }
                TerminalSettingsView()
                    .tabItem {
                        Label("Terminal", systemImage: "terminal")
                    }
                SyncSettingsView()
                    .environmentObject(syncCoordinator)
                    .tabItem {
                        Label("Sync", systemImage: "arrow.triangle.2.circlepath.circle")
                    }
                UpdateSettingsView()
                    .tabItem {
                        Label("Updates", systemImage: "arrow.triangle.2.circlepath")
                    }
            }
            .frame(width: 520)
        }
    }
}
