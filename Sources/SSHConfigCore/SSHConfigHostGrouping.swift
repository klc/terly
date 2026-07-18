import Foundation

public struct SSHConfigHostGroup: Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String?
    public let hosts: [SSHHostBlock]
    public let children: [SSHConfigHostGroup]

    public var isAutomaticPrefixGroup: Bool { label != nil }

    public init(
        id: String,
        label: String?,
        hosts: [SSHHostBlock],
        children: [SSHConfigHostGroup] = []
    ) {
        self.id = id
        self.label = label
        self.hosts = hosts
        self.children = children
    }
}

public extension SSHConfigDocument {
    /// Groups Host blocks by every alias segment before `-`, preserving the
    /// original config order. For example, `ams-api-prod-1` becomes
    /// `ams → api → prod`, while hosts without a hyphen remain ungrouped.
    var hostGroups: [SSHConfigHostGroup] {
        var groupedRoots: [HostGroupAccumulator] = []
        var ungroupedHosts: [SSHHostBlock] = []

        for host in hostBlocks {
            let path = Self.groupPath(for: host)

            guard let firstSegment = path.first else {
                ungroupedHosts.append(host)
                continue
            }

            if let index = groupedRoots.firstIndex(where: { $0.key == firstSegment.key }) {
                groupedRoots[index].append(host: host, remainingPath: Array(path.dropFirst()))
            } else {
                var root = HostGroupAccumulator(segment: firstSegment, parentID: "prefix")
                root.append(host: host, remainingPath: Array(path.dropFirst()))
                groupedRoots.append(root)
            }
        }

        var groups = groupedRoots.map(\.makeGroup)
        if !ungroupedHosts.isEmpty {
            groups.append(SSHConfigHostGroup(id: "ungrouped", label: nil, hosts: ungroupedHosts))
        }
        return groups
    }

    private static func groupPath(for host: SSHHostBlock) -> [GroupSegment] {
        guard let alias = host.patterns.first else { return [] }

        let segments = alias
            .split(separator: "-", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // The final token identifies the actual Host. All preceding tokens form
        // the expandable hierarchy.
        guard segments.count > 1 else { return [] }

        return segments.dropLast().map { GroupSegment(label: $0) }
    }

    private struct GroupSegment: Sendable, Equatable {
        let label: String

        var key: String { label.lowercased() }
    }

    private struct HostGroupAccumulator {
        let key: String
        let label: String
        let id: String
        var hosts: [SSHHostBlock] = []
        var children: [HostGroupAccumulator] = []

        init(segment: GroupSegment, parentID: String) {
            key = segment.key
            label = segment.label
            id = "\(parentID):\(segment.key)"
        }

        mutating func append(host: SSHHostBlock, remainingPath: [GroupSegment]) {
            guard let next = remainingPath.first else {
                hosts.append(host)
                return
            }

            if let index = children.firstIndex(where: { $0.key == next.key }) {
                children[index].append(host: host, remainingPath: Array(remainingPath.dropFirst()))
            } else {
                var child = HostGroupAccumulator(segment: next, parentID: id)
                child.append(host: host, remainingPath: Array(remainingPath.dropFirst()))
                children.append(child)
            }
        }

        var makeGroup: SSHConfigHostGroup {
            SSHConfigHostGroup(
                id: id,
                label: label,
                hosts: hosts,
                children: children.map(\.makeGroup)
            )
        }
    }
}
