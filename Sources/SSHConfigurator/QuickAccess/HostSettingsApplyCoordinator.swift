import Foundation

@MainActor
struct HostSettingsApplyCoordinator {
    private let startupFlowService: StartupFlowHostEditService

    init(startupFlowService: StartupFlowHostEditService = StartupFlowHostEditService()) {
        self.startupFlowService = startupFlowService
    }

    @discardableResult
    func apply(
        preparedConfigSource: String,
        profile: StartupFlowProfile?,
        oldAlias: String?,
        newAlias: String?,
        persistedAliases: Set<String>,
        rollbackCatalog: QuickAccessCatalog,
        startupFlows: StartupFlowLibrary,
        quickAccess: QuickAccessLibrary,
        commitConfigWorkingCopy: () -> Void
    ) -> Bool {
        guard quickAccess.migrateHostAlias(from: oldAlias, to: newAlias) else {
            return false
        }

        guard startupFlowService.apply(
            preparedConfigSource: preparedConfigSource,
            profile: profile,
            newAlias: newAlias,
            persistedAliases: persistedAliases,
            library: startupFlows,
            commitConfigWorkingCopy: commitConfigWorkingCopy
        ) else {
            // Quick-access geçişi önce hazırlanır. Startup metadata hazırlığı
            // başarısızsa eski katalog aliasHistory üzerinden aynı UUID'ye geri döner.
            // Reconcile save'i de başarısız olursa QuickAccessLibrary hata mesajını korur.
            _ = quickAccess.reconcile(catalog: rollbackCatalog)
            return false
        }

        return true
    }
}
