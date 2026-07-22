import Foundation

struct AsciicastHeader: Codable, Equatable, Sendable {
    let version: Int
    let width: Int
    let height: Int
    let timestamp: TimeInterval?
    let title: String?
}

struct AsciicastEvent: Equatable, Sendable {
    let time: TimeInterval
    let kind: String
    let data: String
}

struct AsciicastFile: Equatable, Sendable {
    static let maximumFileSize = 150 * 1024 * 1024

    let header: AsciicastHeader
    let events: [AsciicastEvent]

    var duration: TimeInterval { events.last?.time ?? 0 }

    enum ParseError: LocalizedError, Equatable {
        case emptyFile
        case invalidHeader
        case unsupportedVersion(Int)
        case fileTooLarge

        var errorDescription: String? {
            switch self {
            case .emptyFile: String(localized: "The recording is empty.")
            case .invalidHeader: String(localized: "The recording header is invalid.")
            case let .unsupportedVersion(version):
                String(localized: "Asciicast version \(version) is not supported.")
            case .fileTooLarge: String(localized: "The recording is too large to open.")
            }
        }
    }

    nonisolated static func load(url: URL) throws -> AsciicastFile {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = values.fileSize, fileSize > maximumFileSize {
            throw ParseError.fileTooLarge
        }

        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maximumFileSize else { throw ParseError.fileTooLarge }
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        guard let headerLine = lines.first, !headerLine.isEmpty else { throw ParseError.emptyFile }

        let header: AsciicastHeader
        do {
            header = try JSONDecoder().decode(AsciicastHeader.self, from: Data(headerLine))
        } catch {
            throw ParseError.invalidHeader
        }
        guard header.version == 2 else { throw ParseError.unsupportedVersion(header.version) }

        var previousTime: TimeInterval = 0
        var events: [AsciicastEvent] = []
        events.reserveCapacity(max(0, lines.count - 1))
        for line in lines.dropFirst() where !line.isEmpty {
            guard
                let value = try? JSONSerialization.jsonObject(with: Data(line)),
                let array = value as? [Any], array.count >= 3,
                let rawTime = array[0] as? NSNumber,
                let kind = array[1] as? String,
                let eventData = array[2] as? String
            else { continue }

            let time = max(previousTime, rawTime.doubleValue)
            previousTime = time
            events.append(AsciicastEvent(time: time, kind: kind, data: eventData))
        }
        return AsciicastFile(header: header, events: events)
    }

    nonisolated static func quickDuration(url: URL) -> TimeInterval? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        do {
            let size = try handle.seekToEnd()
            let tailSize = min(UInt64(64 * 1024), size)
            try handle.seek(toOffset: size - tailSize)
            guard let data = try handle.read(upToCount: Int(tailSize)) else { return nil }
            for line in data.split(separator: 0x0A).reversed() {
                guard
                    let value = try? JSONSerialization.jsonObject(with: Data(line)),
                    let array = value as? [Any], array.count >= 3,
                    let time = array[0] as? NSNumber,
                    array[1] is String, array[2] is String
                else { continue }
                return time.doubleValue
            }
        } catch {
            return nil
        }
        return nil
    }
}
