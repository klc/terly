import Foundation

struct StartupFlowMarkerParseResult: Equatable, Sendable {
    let visibleBytes: [UInt8]
    let events: [StartupFlowMarkerEvent]
}

struct StartupFlowMarkerParser: Sendable {
    private let prefix: String
    private let maxMarkerLength: Int
    private var pendingMarker: [UInt8] = []
    private var isCollectingMarker = false

    init(prefix: String, maxMarkerLength: Int = 4_096) {
        self.prefix = prefix
        self.maxMarkerLength = max(32, maxMarkerLength)
    }

    mutating func process(_ bytes: ArraySlice<UInt8>) -> StartupFlowMarkerParseResult {
        var visible: [UInt8] = []
        var events: [StartupFlowMarkerEvent] = []

        for byte in bytes {
            if isCollectingMarker {
                if byte == 0x1F {
                    if let event = parse(pendingMarker) {
                        events.append(event)
                    } else {
                        visible.append(0x1E)
                        visible.append(contentsOf: pendingMarker)
                        visible.append(byte)
                    }
                    pendingMarker.removeAll(keepingCapacity: true)
                    isCollectingMarker = false
                } else {
                    pendingMarker.append(byte)
                    if pendingMarker.count > maxMarkerLength {
                        visible.append(0x1E)
                        visible.append(contentsOf: pendingMarker)
                        pendingMarker.removeAll(keepingCapacity: true)
                        isCollectingMarker = false
                    }
                }
            } else if byte == 0x1E {
                isCollectingMarker = true
                pendingMarker.removeAll(keepingCapacity: true)
            } else {
                visible.append(byte)
            }
        }

        return StartupFlowMarkerParseResult(visibleBytes: visible, events: events)
    }

    mutating func finalize() -> [UInt8] {
        guard isCollectingMarker else { return [] }
        var visible: [UInt8] = [0x1E]
        visible.append(contentsOf: pendingMarker)
        pendingMarker.removeAll(keepingCapacity: false)
        isCollectingMarker = false
        return visible
    }

    private func parse(_ bytes: [UInt8]) -> StartupFlowMarkerEvent? {
        guard let payload = String(bytes: bytes, encoding: .utf8) else { return nil }
        let fields = payload.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 2, fields[0] == prefix else { return nil }

        switch fields[1] {
        case "running":
            return .running(stepIndex: fields.count > 2 ? Int(fields[2]) : nil)
        case "completed":
            return .completed
        case "failed":
            guard fields.count == 4,
                  let stepIndex = Int(fields[2]),
                  let exitCode = Int32(fields[3]) else { return nil }
            return .failed(stepIndex: stepIndex, exitCode: exitCode)
        default:
            return nil
        }
    }
}
