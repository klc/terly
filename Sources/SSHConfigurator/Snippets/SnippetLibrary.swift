import Foundation
import Combine

@MainActor
final class SnippetLibrary: ObservableObject {
    @Published private(set) var snippets: [Snippet] = []
    @Published var errorMessage: String?

    private let store: any SnippetPersisting
    private let secretStore: any SnippetSecretStoring

    init(
        store: any SnippetPersisting = SnippetStore(),
        secretStore: any SnippetSecretStoring = SnippetSecretStore()
    ) {
        self.store = store
        self.secretStore = secretStore
    }

    func load() {
        do {
            var loaded = try store.load()
            var unreadableKeys: [String] = []
            for index in loaded.indices where loaded[index].isSecret {
                do {
                    loaded[index].value = try secretStore.loadSecret(for: loaded[index].id)
                } catch {
                    loaded[index].value = ""
                    unreadableKeys.append(loaded[index].key.isEmpty ? "(isimsiz)" : loaded[index].key)
                }
            }
            snippets = loaded
            errorMessage = unreadableKeys.isEmpty
                ? nil
                : "Şu snippet'lerin gizli değeri Keychain'den okunamadı: \(unreadableKeys.joined(separator: ", "))"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addOrUpdate(_ snippet: Snippet) {
        let wasSecret = snippets.first(where: { $0.id == snippet.id })?.isSecret ?? false
        var keychainError: String?

        if snippet.isSecret {
            do {
                try secretStore.saveSecret(snippet.value, for: snippet.id)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        } else if wasSecret {
            // Toggled back to plaintext: drop the now-orphaned Keychain entry.
            keychainError = deleteSecretQuietly(for: snippet.id)
        }

        if let index = snippets.firstIndex(where: { $0.id == snippet.id }) {
            snippets[index] = snippet
        } else {
            snippets.append(snippet)
        }
        persist(additionalError: keychainError)
    }

    func remove(_ snippet: Snippet) {
        snippets.removeAll { $0.id == snippet.id }
        let keychainError = snippet.isSecret ? deleteSecretQuietly(for: snippet.id) : nil
        persist(additionalError: keychainError)
    }

    func remove(at offsets: IndexSet) {
        let removed = offsets.map { snippets[$0] }
        snippets.remove(atOffsets: offsets)
        let keychainErrors = removed.compactMap { snippet in
            snippet.isSecret ? deleteSecretQuietly(for: snippet.id) : nil
        }
        persist(additionalError: keychainErrors.isEmpty ? nil : keychainErrors.joined(separator: "\n"))
    }

    func dismissError() {
        errorMessage = nil
    }

    private func deleteSecretQuietly(for id: UUID) -> String? {
        do {
            try secretStore.deleteSecret(for: id)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func persist(additionalError: String? = nil) {
        do {
            try store.save(snippets)
            errorMessage = additionalError
        } catch {
            if let additionalError {
                errorMessage = "\(additionalError)\n\(error.localizedDescription)"
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }
}
