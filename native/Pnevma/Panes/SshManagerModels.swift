import Foundation

// MARK: - Data Models

struct SshProfile: Identifiable, Codable {
    let id: String
    var name: String
    var host: String
    var port: Int
    var user: String
    var identityFile: String?
    var isConnected: Bool
}

struct TailscaleDevice: Identifiable, Codable {
    let id: String
    let hostname: String
    let ipAddress: String
    let isOnline: Bool
}
