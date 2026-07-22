import CoreTransferable
import Foundation
import UniformTypeIdentifiers

extension UTType {
    static let terlySSHConnection = UTType(exportedAs: "com.terly.ssh-connection")
}

struct ConnectionDragPayload: Codable, Transferable {
    let hostID: Int
    let alias: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .terlySSHConnection)
    }
}
