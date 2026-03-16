import XCTest
@testable import Pnevma

@MainActor
final class SshManagerModelsTests: XCTestCase {
    func testTailscaleDeviceDecodesDevicePayload() throws {
        let data = Data(
            #"[{"id":"dev-1","hostname":"worker.tailnet.ts.net","ip_address":"100.64.0.10","is_online":false}]"#
                .utf8
        )

        let devices = try PnevmaJSON.decoder().decode([TailscaleDevice].self, from: data)

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].id, "dev-1")
        XCTAssertEqual(devices[0].hostname, "worker.tailnet.ts.net")
        XCTAssertEqual(devices[0].ipAddress, "100.64.0.10")
        XCTAssertFalse(devices[0].isOnline)
    }

    func testTailscaleDeviceDecodesLegacySshProfilePayload() throws {
        let data = Data(
            #"[{"id":"profile-1","name":"worker.tailnet.ts.net","host":"worker.tailnet.ts.net","port":22,"user":null,"identity_file":null,"proxy_jump":null,"tags":["tailscale"],"source":"tailscale","created_at":"2026-03-11T09:00:00Z","updated_at":"2026-03-11T09:00:00Z"}]"#
                .utf8
        )

        let devices = try PnevmaJSON.decoder().decode([TailscaleDevice].self, from: data)

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].id, "profile-1")
        XCTAssertEqual(devices[0].hostname, "worker.tailnet.ts.net")
        XCTAssertEqual(devices[0].ipAddress, "worker.tailnet.ts.net")
        XCTAssertTrue(devices[0].isOnline)
    }

    func testTailscaleDeviceBuildsRemoteWorkspaceTarget() {
        let device = TailscaleDevice(
            id: "nodekey:abc123",
            hostname: "worker.tailnet.ts.net",
            ipAddress: "100.64.0.10",
            isOnline: true
        )

        let target = device.remoteWorkspaceTarget(
            user: "ops",
            port: 2222,
            remotePath: "~/repo"
        )

        XCTAssertEqual(target.sshProfileID, "tailscale-nodekey-abc123")
        XCTAssertEqual(target.sshProfileName, "worker.tailnet.ts.net")
        XCTAssertEqual(target.host, "worker.tailnet.ts.net")
        XCTAssertEqual(target.port, 2222)
        XCTAssertEqual(target.user, "ops")
        XCTAssertEqual(target.remotePath, "~/repo")
        XCTAssertNil(target.identityFile)
        XCTAssertNil(target.proxyJump)
    }
}
