import Foundation

struct Snippet: Identifiable, Equatable, Sendable {
    let id: UUID
    var key: String
    var value: String
    /// When true, `value` is kept in the system Keychain rather than in the
    /// plaintext JSON store — see `SnippetSecretStore`. `SnippetLibrary` is
    /// responsible for loading the real value back into this property after
    /// decoding; on disk it is always written out as an empty string.
    var isSecret: Bool

    init(id: UUID = UUID(), key: String = "", value: String = "", isSecret: Bool = false) {
        self.id = id
        self.key = key
        self.value = value
        self.isSecret = isSecret
    }
}

extension Snippet: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, key, value, isSecret
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        key = try container.decode(String.self, forKey: .key)
        value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
        isSecret = try container.decodeIfPresent(Bool.self, forKey: .isSecret) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(key, forKey: .key)
        // Secret values never touch the plaintext JSON store; the real value
        // lives only in the Keychain and in memory (see SnippetLibrary.load()).
        try container.encode(isSecret ? "" : value, forKey: .value)
        try container.encode(isSecret, forKey: .isSecret)
    }
}

enum SnippetSearch {
    /// Secret snippets are matched by key only — their value is never
    /// searched so it doesn't leak into UI state while typing a query.
    static func filter(_ snippets: [Snippet], query: String) -> [Snippet] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return snippets }
        let needle = trimmed.lowercased()
        return snippets.filter { snippet in
            if snippet.key.lowercased().contains(needle) { return true }
            guard !snippet.isSecret else { return false }
            return snippet.value.lowercased().contains(needle)
        }
    }
}
