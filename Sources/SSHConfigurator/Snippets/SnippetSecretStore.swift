import Foundation
import Security

/// Persists snippet secret values outside the plaintext JSON store.
///
/// Backed by the Keychain (`kSecClassGenericPassword`); each snippet's secret
/// is addressed by its stable UUID so renames don't orphan the entry.
protocol SnippetSecretStoring {
    func saveSecret(_ value: String, for id: UUID) throws
    func loadSecret(for id: UUID) throws -> String
    func deleteSecret(for id: UUID) throws
}

enum SnippetSecretStoreError: LocalizedError, Equatable {
    case encodingFailed
    case notFound
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Gizli değer metne dönüştürülemedi."
        case .notFound:
            return "Keychain'de kayıtlı bir değer bulunamadı."
        case let .unexpectedStatus(status):
            let message = SecCopyErrorMessageString(status, nil) as String?
            return "Keychain hatası (\(status))\(message.map { ": \($0)" } ?? "")."
        }
    }
}

/// Real Keychain-backed implementation. A dedicated protocol keeps
/// `SnippetLibrary` testable without touching the actual Keychain.
struct SnippetSecretStore: SnippetSecretStoring {
    static let service = "com.sshconfigurator.snippets"

    func saveSecret(_ value: String, for id: UUID) throws {
        guard let data = value.data(using: .utf8) else {
            throw SnippetSecretStoreError.encodingFailed
        }
        let query = baseQuery(account: id.uuidString)

        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw SnippetSecretStoreError.unexpectedStatus(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw SnippetSecretStoreError.unexpectedStatus(updateStatus)
        }
    }

    func loadSecret(for id: UUID) throws -> String {
        var query = baseQuery(account: id.uuidString)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            throw status == errSecItemNotFound
                ? SnippetSecretStoreError.notFound
                : SnippetSecretStoreError.unexpectedStatus(status)
        }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw SnippetSecretStoreError.encodingFailed
        }
        return value
    }

    func deleteSecret(for id: UUID) throws {
        let status = SecItemDelete(baseQuery(account: id.uuidString) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SnippetSecretStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
    }
}
