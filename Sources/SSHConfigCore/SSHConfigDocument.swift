import Foundation

public enum SSHConfigSectionKind: String, Sendable, Equatable {
    case host
    case match
}

public enum SSHConfigLineKind: Sendable, Equatable {
    case blank
    case comment
    case section(kind: SSHConfigSectionKind, arguments: String)
    case directive(keyword: String, value: String)
    case unknown
}

/// A line from an SSH config file. `raw` is never normalized, so formatting can
/// be preserved when the document later gains editing support.
public struct SSHConfigLine: Sendable, Equatable {
    public let number: Int
    public let raw: String
    public let kind: SSHConfigLineKind
}

public struct SSHHostBlock: Sendable, Equatable, Identifiable {
    public let headerLine: Int
    public let lineRange: ClosedRange<Int>
    public let patterns: [String]

    public var id: Int { headerLine }
    public var displayName: String { patterns.joined(separator: " ") }
    public var isPattern: Bool {
        patterns.contains { $0.contains("*") || $0.contains("!") || $0.contains("?") }
    }
}

/// A lossless, read-only representation of `ssh_config(5)` source.
/// Editing APIs will operate on this source model instead of regenerating the
/// whole file from a limited set of known directives.
public struct SSHConfigDocument: Sendable, Equatable {
    public let source: String
    public let lines: [SSHConfigLine]

    public init(source: String) {
        self.source = source
        self.lines = Self.makeLines(from: source)
    }

    /// Returns the original source verbatim. This is the round-trip invariant
    /// for documents that have not been edited.
    public var rendered: String { source }

    public var hostBlocks: [SSHHostBlock] {
        var blocks: [SSHHostBlock] = []
        var activeHeader: (line: Int, patterns: [String])?

        for line in lines {
            switch line.kind {
            case let .section(kind: .host, arguments: arguments):
                if let header = activeHeader {
                    blocks.append(
                        SSHHostBlock(
                            headerLine: header.line,
                            lineRange: header.line...max(header.line, line.number - 1),
                            patterns: header.patterns
                        )
                    )
                }
                activeHeader = (line.number, Self.hostPatterns(from: arguments))

            case .section:
                if let header = activeHeader {
                    blocks.append(
                        SSHHostBlock(
                            headerLine: header.line,
                            lineRange: header.line...max(header.line, line.number - 1),
                            patterns: header.patterns
                        )
                    )
                    activeHeader = nil
                }

            default:
                break
            }
        }

        if let activeHeader {
            blocks.append(
                SSHHostBlock(
                    headerLine: activeHeader.line,
                    lineRange: activeHeader.line...max(activeHeader.line, lines.count),
                    patterns: activeHeader.patterns
                )
            )
        }

        return blocks
    }

    public func source(for hostBlock: SSHHostBlock) -> String {
        lines
            .filter { hostBlock.lineRange.contains($0.number) }
            .map(\.raw)
            .joined(separator: "\n")
    }

    private static func makeLines(from source: String) -> [SSHConfigLine] {
        guard !source.isEmpty else { return [] }

        var fragments = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        // A final line ending terminates the preceding line; it does not create
        // an additional blank config line. Real trailing blank lines remain.
        if source.hasSuffix("\n") {
            fragments.removeLast()
        }

        return fragments
            .enumerated()
            .map { offset, fragment in
                let raw = fragment.trimmingSuffix("\r")
                return SSHConfigLine(number: offset + 1, raw: raw, kind: classify(raw))
            }
    }

    private static func classify(_ raw: String) -> SSHConfigLineKind {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else { return .blank }
        guard !trimmed.hasPrefix("#") else { return .comment }

        let components = trimmed.split(
            maxSplits: 1,
            omittingEmptySubsequences: true,
            whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" }
        )

        guard let keywordComponent = components.first else { return .unknown }

        let keyword = String(keywordComponent)
        let value = components.dropFirst().first.map(String.init) ?? ""

        switch keyword.lowercased() {
        case SSHConfigSectionKind.host.rawValue:
            return .section(kind: .host, arguments: value)
        case SSHConfigSectionKind.match.rawValue:
            return .section(kind: .match, arguments: value)
        default:
            return .directive(keyword: keyword, value: value)
        }
    }

    private static func hostPatterns(from arguments: String) -> [String] {
        arguments
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
    }
}

private extension String {
    func trimmingSuffix(_ suffix: Character) -> String {
        guard last == suffix else { return self }
        return String(dropLast())
    }
}
