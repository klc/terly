import Foundation

@MainActor
struct StartupFlowHostEditService {
    @discardableResult
    func apply(
        preparedConfigSource: String,
        profile: StartupFlowProfile?,
        newAlias: String?,
        persistedAliases: Set<String>,
        library: StartupFlowLibrary,
        commitConfigWorkingCopy: () -> Void
    ) -> Bool {
        guard var profile, let newAlias else {
            commitConfigWorkingCopy()
            return true
        }

        profile.alias = newAlias
        // HostName/User gibi alanlar profil bağlantısının geçerliliğini etkilemez.
        // Metadata yalnızca hedef alias henüz diskte yoksa config kaydını beklemeli.
        let requiresConfigCommit = !persistedAliases.contains(newAlias)
        let fingerprint = requiresConfigCommit
            ? StartupFlowConfigFingerprint.make(preparedConfigSource)
            : nil

        guard library.save(
            profile,
            pendingUntilConfigFingerprint: fingerprint
        ) else {
            return false
        }
        commitConfigWorkingCopy()
        return true
    }
}
