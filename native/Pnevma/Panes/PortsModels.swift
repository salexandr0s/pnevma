import Foundation

struct PortEntry: Identifiable, Decodable {
    let port: UInt16
    let pid: UInt32
    let processName: String
    let workspaceName: String?
    let sessionID: String?
    let label: String?
    let `protocol`: String
    let detectedAt: String

    var id: Int { Int(port) }

    var displayAddress: String {
        "localhost:\(port)"
    }

    var displayLabel: String {
        label ?? processName
    }
}
