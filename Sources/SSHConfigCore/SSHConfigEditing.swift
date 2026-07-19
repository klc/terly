import Foundation

public struct SSHConfigDirective: Sendable, Equatable {
    public let keyword: String
    public let value: String

    public init(keyword: String, value: String) {
        self.keyword = keyword
        self.value = value
    }
}

public enum SSHConfigEditError: LocalizedError {
    case hostBlockNotFound
    case invalidHostPattern

    public var errorDescription: String? {
        switch self {
        case .hostBlockNotFound:
            return String(localized: "The Host block to edit wasn't found. The file may have been changed externally.", bundle: .core)
        case .invalidHostPattern:
            return String(localized: "At least one Host name or pattern is required.", bundle: .core)
        }
    }
}

public extension SSHConfigDocument {
    var containsMatchExec: Bool {
        lines.contains {
            guard case let .section(kind: .match, arguments: arguments) = $0.kind else {
                return false
            }

            return arguments
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .contains { $0.lowercased() == "exec" }
        }
    }

    func directiveValue(named keyword: String, in hostBlock: SSHHostBlock) -> String? {
        guard hostBlocks.contains(where: { $0.id == hostBlock.id }) else { return nil }

        for line in lines where hostBlock.lineRange.contains(line.number) {
            guard case let .directive(existingKeyword, value) = line.kind,
                  existingKeyword.caseInsensitiveCompare(keyword) == .orderedSame else {
                continue
            }

            return Self.valueWithoutInlineComment(value)
        }

        return nil
    }

    func replacingHostPatterns(
        in hostBlock: SSHHostBlock,
        with patterns: [String]
    ) throws -> SSHConfigDocument {
        let sanitizedPatterns = patterns.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !sanitizedPatterns.isEmpty else {
            throw SSHConfigEditError.invalidHostPattern
        }

        guard let header = lines.first(where: { $0.number == hostBlock.headerLine }) else {
            throw SSHConfigEditError.hostBlockNotFound
        }

        let replacement = "\(Self.indentation(of: header.raw))Host \(sanitizedPatterns.joined(separator: " "))"
        return replacingLine(number: hostBlock.headerLine, with: replacement)
    }

    func updatingDirective(
        named keyword: String,
        to value: String?,
        in hostBlock: SSHHostBlock
    ) throws -> SSHConfigDocument {
        guard hostBlocks.contains(where: { $0.id == hostBlock.id }) else {
            throw SSHConfigEditError.hostBlockNotFound
        }

        let normalizedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchingLine = lines.first { line in
            guard hostBlock.lineRange.contains(line.number),
                  case let .directive(existingKeyword, _) = line.kind else {
                return false
            }

            return existingKeyword.caseInsensitiveCompare(keyword) == .orderedSame
        }

        if let matchingLine {
            guard let normalizedValue, !normalizedValue.isEmpty else {
                return removingLine(number: matchingLine.number)
            }

            let inlineComment = Self.inlineComment(in: matchingLine.raw)
            let existingKeyword: String
            if case let .directive(parsedKeyword, _) = matchingLine.kind {
                existingKeyword = parsedKeyword
            } else {
                existingKeyword = keyword
            }

            let commentSuffix = inlineComment.isEmpty ? "" : " \(inlineComment)"
            let replacement = "\(Self.indentation(of: matchingLine.raw))\(existingKeyword) \(normalizedValue)\(commentSuffix)"
            return replacingLine(number: matchingLine.number, with: replacement)
        }

        guard let normalizedValue, !normalizedValue.isEmpty else {
            return self
        }

        let insertionLine = hostBlock.lineRange.upperBound
        return insertingLine(
            "  \(keyword) \(normalizedValue)",
            after: insertionLine
        )
    }

    func appendingHost(
        patterns: [String],
        directives: [SSHConfigDirective] = []
    ) throws -> SSHConfigDocument {
        let sanitizedPatterns = patterns.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !sanitizedPatterns.isEmpty else {
            throw SSHConfigEditError.invalidHostPattern
        }

        let ending = preferredLineEnding
        var appendedSource = source

        if !appendedSource.isEmpty, !appendedSource.hasSuffix("\n") {
            appendedSource += ending
        }
        if !appendedSource.isEmpty, !appendedSource.hasSuffix("\(ending)\(ending)") {
            appendedSource += ending
        }

        appendedSource += "Host \(sanitizedPatterns.joined(separator: " "))\(ending)"
        for directive in directives where !directive.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendedSource += "  \(directive.keyword) \(directive.value)\(ending)"
        }

        return SSHConfigDocument(source: appendedSource)
    }

    func duplicatingHostBlock(
        _ hostBlock: SSHHostBlock,
        with patterns: [String]
    ) throws -> SSHConfigDocument {
        let sanitizedPatterns = patterns.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !sanitizedPatterns.isEmpty else {
            throw SSHConfigEditError.invalidHostPattern
        }

        guard let header = lines.first(where: { $0.number == hostBlock.headerLine }) else {
            throw SSHConfigEditError.hostBlockNotFound
        }

        var duplicatedLines = lines
            .filter { hostBlock.lineRange.contains($0.number) }
            .map(\.raw)
        while duplicatedLines.last?.isEmpty == true {
            duplicatedLines.removeLast()
        }
        guard !duplicatedLines.isEmpty else {
            throw SSHConfigEditError.hostBlockNotFound
        }

        var duplicatedSource = source
        let ending = preferredLineEnding
        if !duplicatedSource.isEmpty, !duplicatedSource.hasSuffix("\n") {
            duplicatedSource += ending
        }
        if !duplicatedSource.isEmpty, !duplicatedSource.hasSuffix("\(ending)\(ending)") {
            duplicatedSource += ending
        }

        let headerComment = Self.inlineComment(in: header.raw)
        let commentSuffix = headerComment.isEmpty ? "" : " \(headerComment)"
        let duplicatedHeader = "\(Self.indentation(of: header.raw))Host \(sanitizedPatterns.joined(separator: " "))\(commentSuffix)"
        duplicatedSource += ([duplicatedHeader] + duplicatedLines.dropFirst()).joined(separator: ending)
        if !duplicatedSource.hasSuffix(ending) {
            duplicatedSource += ending
        }

        return SSHConfigDocument(source: duplicatedSource)
    }

    func deletingHostBlock(_ hostBlock: SSHHostBlock) throws -> SSHConfigDocument {
        guard hostBlocks.contains(where: { $0.id == hostBlock.id }) else {
            throw SSHConfigEditError.hostBlockNotFound
        }

        var mutable = editableLines
        let lower = hostBlock.lineRange.lowerBound - 1
        let upper = hostBlock.lineRange.upperBound - 1
        mutable.lines.removeSubrange(lower...upper)
        return SSHConfigDocument(source: Self.render(lines: mutable.lines, ending: mutable.ending, hasTrailingEnding: mutable.hasTrailingEnding))
    }

    func replacingSource(in lineRange: ClosedRange<Int>, with replacementSource: String) -> SSHConfigDocument {
        var mutable = editableLines
        guard mutable.lines.indices.contains(lineRange.lowerBound - 1),
              mutable.lines.indices.contains(lineRange.upperBound - 1) else {
            return self
        }

        let replacementLines = Self.lines(from: replacementSource)
        mutable.lines.replaceSubrange((lineRange.lowerBound - 1)...(lineRange.upperBound - 1), with: replacementLines)
        return SSHConfigDocument(source: Self.render(lines: mutable.lines, ending: mutable.ending, hasTrailingEnding: mutable.hasTrailingEnding))
    }

    func replacingGlobalSource(with replacementSource: String) -> SSHConfigDocument {
        if let globalLineRange {
            return replacingSource(in: globalLineRange, with: replacementSource)
        }

        var mutable = editableLines
        let replacementLines = Self.lines(from: replacementSource)
        mutable.lines.insert(contentsOf: replacementLines, at: 0)
        let needsTrailingEnding = mutable.hasTrailingEnding || !replacementLines.isEmpty
        return SSHConfigDocument(source: Self.render(lines: mutable.lines, ending: mutable.ending, hasTrailingEnding: needsTrailingEnding))
    }

    func appendingGlobalDirective(_ directive: SSHConfigDirective) -> SSHConfigDocument {
        var mutable = editableLines
        let newLine = "\(directive.keyword) \(directive.value)"

        if let globalLineRange {
            mutable.lines.insert(newLine, at: globalLineRange.upperBound)
        } else {
            mutable.lines.insert(newLine, at: 0)
        }

        return SSHConfigDocument(source: Self.render(lines: mutable.lines, ending: mutable.ending, hasTrailingEnding: true))
    }

    func updatingDirective(atLine lineNumber: Int, to value: String) -> SSHConfigDocument {
        guard let line = lines.first(where: { $0.number == lineNumber }),
              case let .directive(keyword, _) = line.kind else {
            return self
        }

        let inlineComment = Self.inlineComment(in: line.raw)
        let commentSuffix = inlineComment.isEmpty ? "" : " \(inlineComment)"
        return replacingLine(
            number: lineNumber,
            with: "\(Self.indentation(of: line.raw))\(keyword) \(value.trimmingCharacters(in: .whitespacesAndNewlines))\(commentSuffix)"
        )
    }

    func removingDirective(atLine lineNumber: Int) -> SSHConfigDocument {
        removingLine(number: lineNumber)
    }

    private var preferredLineEnding: String {
        source.contains("\r\n") ? "\r\n" : "\n"
    }

    private var editableLines: (lines: [String], ending: String, hasTrailingEnding: Bool) {
        let ending = preferredLineEnding
        let hasTrailingEnding = source.hasSuffix(ending)
        var mutable = source.components(separatedBy: ending)
        if hasTrailingEnding {
            mutable.removeLast()
        }

        return (mutable, ending, hasTrailingEnding)
    }

    private func replacingLine(number: Int, with replacement: String) -> SSHConfigDocument {
        var mutable = editableLines
        guard mutable.lines.indices.contains(number - 1) else { return self }
        mutable.lines[number - 1] = replacement
        return SSHConfigDocument(source: Self.render(lines: mutable.lines, ending: mutable.ending, hasTrailingEnding: mutable.hasTrailingEnding))
    }

    private func removingLine(number: Int) -> SSHConfigDocument {
        var mutable = editableLines
        guard mutable.lines.indices.contains(number - 1) else { return self }
        mutable.lines.remove(at: number - 1)
        return SSHConfigDocument(source: Self.render(lines: mutable.lines, ending: mutable.ending, hasTrailingEnding: mutable.hasTrailingEnding))
    }

    private func insertingLine(_ line: String, after number: Int) -> SSHConfigDocument {
        var mutable = editableLines
        let insertionIndex = min(max(number, 0), mutable.lines.count)
        mutable.lines.insert(line, at: insertionIndex)
        return SSHConfigDocument(source: Self.render(lines: mutable.lines, ending: mutable.ending, hasTrailingEnding: true))
    }

    private static func render(lines: [String], ending: String, hasTrailingEnding: Bool) -> String {
        var rendered = lines.joined(separator: ending)
        if hasTrailingEnding, !rendered.isEmpty {
            rendered += ending
        }
        return rendered
    }

    private static func lines(from source: String) -> [String] {
        guard !source.isEmpty else { return [] }

        var splitLines = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if source.hasSuffix("\n") {
            splitLines.removeLast()
        }
        return splitLines
    }

    private static func indentation(of line: String) -> String {
        String(line.prefix { $0 == " " || $0 == "\t" })
    }

    private static func inlineComment(in line: String) -> String {
        var isEscaped = false
        var quote: Character?

        for index in line.indices {
            let character = line[index]
            if isEscaped {
                isEscaped = false
                continue
            }
            if character == "\\" {
                isEscaped = true
                continue
            }
            if character == "\"" || character == "'" {
                quote = quote == character ? nil : (quote ?? character)
                continue
            }
            if character == "#", quote == nil {
                return String(line[index...])
            }
        }

        return ""
    }

    static func valueWithoutInlineComment(_ value: String) -> String {
        let comment = inlineComment(in: value)
        guard !comment.isEmpty, let range = value.range(of: comment) else {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(value[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
