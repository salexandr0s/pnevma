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

struct TailscaleDevice: Identifiable, Decodable {
    let id: String
    let hostname: String
    let ipAddress: String
    let isOnline: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case hostname
        case ipAddress
        case isOnline
        case name
        case host
    }

    init(
        id: String,
        hostname: String,
        ipAddress: String,
        isOnline: Bool
    ) {
        self.id = id
        self.hostname = hostname
        self.ipAddress = ipAddress
        self.isOnline = isOnline
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let hostname = try container.decodeIfPresent(String.self, forKey: .hostname)
            ?? container.decodeIfPresent(String.self, forKey: .name)
            ?? container.decodeIfPresent(String.self, forKey: .host)
        guard let hostname else {
            throw DecodingError.keyNotFound(
                CodingKeys.hostname,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected either hostname, name, or host."
                )
            )
        }

        let ipAddress = try container.decodeIfPresent(String.self, forKey: .ipAddress)
            ?? container.decodeIfPresent(String.self, forKey: .host)
            ?? hostname
        let isOnline = try container.decodeIfPresent(Bool.self, forKey: .isOnline) ?? true

        self.init(
            id: id,
            hostname: hostname,
            ipAddress: ipAddress,
            isOnline: isOnline
        )
    }
}

extension TailscaleDevice {
    var remoteWorkspaceProfileID: String {
        let sanitizedID = id
            .replacing(":", with: "-")
            .replacing("/", with: "-")
        return "tailscale-\(sanitizedID)"
    }

    func remoteWorkspaceTarget(
        user: String,
        port: Int = 22,
        remotePath: String
    ) -> WorkspaceRemoteTarget {
        WorkspaceRemoteTarget(
            sshProfileID: remoteWorkspaceProfileID,
            sshProfileName: hostname,
            host: hostname,
            port: port,
            user: user,
            identityFile: nil,
            proxyJump: nil,
            remotePath: remotePath
        )
    }
}
