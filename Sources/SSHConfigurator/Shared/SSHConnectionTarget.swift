import Foundation

struct SSHConnectionTarget: Equatable, Hashable, Identifiable, Sendable {
    let hostID: Int
    let alias: String

    var id: String { alias }
}
