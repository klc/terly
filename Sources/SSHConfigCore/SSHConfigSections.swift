import Foundation

public struct SSHConfigMatchBlock: Sendable, Equatable, Identifiable {
    public let headerLine: Int
    public let lineRange: ClosedRange<Int>
    public let conditions: String

    public var id: Int { headerLine }
    public var displayName: String { conditions.isEmpty ? "Match" : "Match \(conditions)" }
}

public struct SSHConfigDirectiveOccurrence: Sendable, Equatable, Identifiable {
    public let line: Int
    public let keyword: String
    public let value: String

    public var id: Int { line }
}

public enum SSHConfigIncludeScope: String, Sendable, Equatable {
    case global
    case host
    case match
}

public struct SSHConfigInclude: Sendable, Equatable, Identifiable {
    public let line: Int
    public let value: String
    public let scope: SSHConfigIncludeScope

    public var id: Int { line }
}

public extension SSHConfigDocument {
    var globalLineRange: ClosedRange<Int>? {
        guard !lines.isEmpty else { return nil }

        if let firstSection = lines.first(where: {
            if case .section = $0.kind { return true }
            return false
        }) {
            guard firstSection.number > 1 else { return nil }
            return 1...(firstSection.number - 1)
        }

        return 1...lines.count
    }

    var globalDirectives: [SSHConfigDirectiveOccurrence] {
        guard let globalLineRange else { return [] }

        return lines.compactMap { line in
            guard globalLineRange.contains(line.number),
                  case let .directive(keyword, value) = line.kind else {
                return nil
            }
            return SSHConfigDirectiveOccurrence(line: line.number, keyword: keyword, value: value)
        }
    }

    var matchBlocks: [SSHConfigMatchBlock] {
        var blocks: [SSHConfigMatchBlock] = []
        var activeHeader: (line: Int, conditions: String)?

        for line in lines {
            switch line.kind {
            case let .section(kind: .match, arguments: arguments):
                if let header = activeHeader {
                    blocks.append(
                        SSHConfigMatchBlock(
                            headerLine: header.line,
                            lineRange: header.line...max(header.line, line.number - 1),
                            conditions: header.conditions
                        )
                    )
                }
                activeHeader = (line.number, arguments)

            case .section:
                if let header = activeHeader {
                    blocks.append(
                        SSHConfigMatchBlock(
                            headerLine: header.line,
                            lineRange: header.line...max(header.line, line.number - 1),
                            conditions: header.conditions
                        )
                    )
                    activeHeader = nil
                }

            default:
                break
            }
        }

        if let header = activeHeader {
            blocks.append(
                SSHConfigMatchBlock(
                    headerLine: header.line,
                    lineRange: header.line...max(header.line, lines.count),
                    conditions: header.conditions
                )
            )
        }

        return blocks
    }

    var includes: [SSHConfigInclude] {
        var activeSection: SSHConfigSectionKind?

        return lines.compactMap { line in
            if case let .section(kind, _) = line.kind {
                activeSection = kind
                return nil
            }

            guard case let .directive(keyword, value) = line.kind,
                  keyword.caseInsensitiveCompare("Include") == .orderedSame else {
                return nil
            }

            let scope: SSHConfigIncludeScope
            switch activeSection {
            case .host: scope = .host
            case .match: scope = .match
            case nil: scope = .global
            }
            return SSHConfigInclude(line: line.number, value: Self.valueWithoutInlineComment(value), scope: scope)
        }
    }

    func source(in lineRange: ClosedRange<Int>) -> String {
        lines
            .filter { lineRange.contains($0.number) }
            .map(\.raw)
            .joined(separator: preferredDisplayLineEnding)
    }

    func source(for matchBlock: SSHConfigMatchBlock) -> String {
        source(in: matchBlock.lineRange)
    }

    var globalSource: String {
        globalLineRange.map { source(in: $0) } ?? ""
    }

    private var preferredDisplayLineEnding: String {
        source.contains("\r\n") ? "\r\n" : "\n"
    }
}
