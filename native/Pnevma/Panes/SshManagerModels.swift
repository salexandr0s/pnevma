import Foundation

// MARK: - Data Models

struct SshProfile: Identifiable, Codable {
    let id: String
    var name: String
    var host: String
    var port: Int
    var user: String
    var identityFile: String?
    var proxyJump: String?
    var isConnected: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case host
        case port
        case user
        case identityFile
        case proxyJump
        case isConnected
    }

    init(
        id: String,
        name: String,
        host: String,
        port: Int,
        user: String,
        identityFile: String?,
        proxyJump: String? = nil,
        isConnected: Bool
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.user = user
        self.identityFile = identityFile
        self.proxyJump = proxyJump
        self.isConnected = isConnected
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        user = try container.decodeIfPresent(String.self, forKey: .user) ?? NSUserName()
        identityFile = try container.decodeIfPresent(String.self, forKey: .identityFile)
        proxyJump = try container.decodeIfPresent(String.self, forKey: .proxyJump)
        isConnected = try container.decodeIfPresent(Bool.self, forKey: .isConnected) ?? false
    }
}

struct TailscaleDevice: Identifiable, Codable {
    let id: String
    let hostname: String
    let ipAddress: String
    let isOnline: Bool
}
