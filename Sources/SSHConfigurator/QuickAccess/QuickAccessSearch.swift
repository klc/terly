import Foundation

struct QuickAccessSearchResult: Equatable, Identifiable, Sendable {
    let entry: QuickAccessEntry
    let score: Int

    var id: UUID { entry.id }
}

enum QuickAccessFuzzyMatcher {
    static func score(query: String, candidate: String) -> Int? {
        let query = normalize(query)
        let candidate = normalize(candidate)
        guard !query.isEmpty, !candidate.isEmpty else { return nil }
        if candidate == query { return 2_000 }
        if candidate.hasPrefix(query) { return 1_500 - candidate.count }
        if let range = candidate.range(of: query) {
            return 1_200 - candidate.distance(from: candidate.startIndex, to: range.lowerBound)
        }

        var queryIndex = query.startIndex
        var previousMatch: String.Index?
        var score = 0
        for index in candidate.indices where queryIndex < query.endIndex {
            guard candidate[index] == query[queryIndex] else { continue }
            score += 30
            if let previousMatch,
               candidate.index(after: previousMatch) == index {
                score += 22
            }
            if index == candidate.startIndex || "-_./ @".contains(candidate[candidate.index(before: index)]) {
                score += 18
            }
            previousMatch = index
            query.formIndex(after: &queryIndex)
        }
        guard queryIndex == query.endIndex else { return nil }
        return score - max(0, candidate.count - query.count)
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum QuickAccessSearchEngine {
    static func search(
        query: String,
        entries: [QuickAccessEntry],
        limit: Int = 80
    ) -> [QuickAccessSearchResult] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let results: [QuickAccessSearchResult]
        if terms.isEmpty {
            results = entries.map { QuickAccessSearchResult(entry: $0, score: 0) }
        } else {
            results = entries.compactMap { entry in
                var total = 0
                for term in terms {
                    guard let best = entry.searchFields.compactMap({
                        QuickAccessFuzzyMatcher.score(query: term, candidate: $0)
                    }).max() else { return nil }
                    total += best
                }
                return QuickAccessSearchResult(entry: entry, score: total)
            }
        }

        return Array(results.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.entry.isFavorite != rhs.entry.isFavorite { return lhs.entry.isFavorite }
            switch (lhs.entry.lastUsedAt, rhs.entry.lastUsedAt) {
            case let (.some(left), .some(right)) where left != right:
                return left > right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                return lhs.entry.title.localizedStandardCompare(rhs.entry.title) == .orderedAscending
            }
        }.prefix(max(1, limit)))
    }
}
