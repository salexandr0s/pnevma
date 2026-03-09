import SwiftUI
import Observation

// MARK: - ViewModel

@Observable @MainActor
final class SshManagerViewModel {
    var profiles: [SshProfile] = []
    var tailscaleDevices: [TailscaleDevice] = []
    var showAddSheet = false
    var actionError: String?

    func activate() async {
        load()
    }

    func load() {
        guard let bus = CommandBus.shared else {
            actionError = "Backend connection unavailable"
            scheduleDismissActionError()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                async let profilesResult: [SshProfile] = bus.call(method: "ssh.list_profiles")
                async let devicesResult: [TailscaleDevice] = bus.call(method: "ssh.discover_tailscale")
                let (p, d) = try await (profilesResult, devicesResult)
                self.profiles = p
                self.tailscaleDevices = d
            } catch {
                self.actionError = error.localizedDescription
                self.scheduleDismissActionError()
            }
        }
    }

    func addProfile(_ profile: SshProfile) {
        profiles.append(profile)
        guard let bus = CommandBus.shared else {
            actionError = "Backend connection unavailable"
            scheduleDismissActionError()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                struct Params: Encodable {
                    let name: String; let host: String; let port: Int
                    let user: String; let identityFile: String?
                }
                let _: SshProfile = try await bus.call(
                    method: "ssh.create_profile",
                    params: Params(name: profile.name, host: profile.host, port: profile.port,
                                   user: profile.user, identityFile: profile.identityFile)
                )
            } catch {
                self.actionError = error.localizedDescription
                self.scheduleDismissActionError()
            }
        }
    }

    func connect(_ profile: SshProfile) {
        guard let bus = CommandBus.shared else {
            actionError = "Backend connection unavailable"
            scheduleDismissActionError()
            return
        }
        Task { [weak self] in
            do {
                struct Params: Encodable { let profileId: String }
                let _: [String: Bool] = try await bus.call(method: "ssh.connect", params: Params(profileId: profile.id))
                if let idx = self?.profiles.firstIndex(where: { $0.id == profile.id }) {
                    self?.profiles[idx].isConnected = true
                }
            } catch {
                self?.actionError = error.localizedDescription
                self?.scheduleDismissActionError()
            }
        }
    }

    func disconnect(_ profile: SshProfile) {
        guard let bus = CommandBus.shared else {
            actionError = "Backend connection unavailable"
            scheduleDismissActionError()
            return
        }
        Task { [weak self] in
            do {
                struct Params: Encodable { let profileId: String }
                let _: [String: Bool] = try await bus.call(method: "ssh.disconnect", params: Params(profileId: profile.id))
                if let idx = self?.profiles.firstIndex(where: { $0.id == profile.id }) {
                    self?.profiles[idx].isConnected = false
                }
            } catch {
                self?.actionError = error.localizedDescription
                self?.scheduleDismissActionError()
            }
        }
    }

    func connectTailscale(_ device: TailscaleDevice) {
        guard let bus = CommandBus.shared else {
            actionError = "Backend connection unavailable"
            scheduleDismissActionError()
            return
        }
        Task { [weak self] in
            do {
                struct Params: Encodable { let host: String }
                let _: [String: Bool] = try await bus.call(method: "ssh.connect", params: Params(host: device.ipAddress))
            } catch {
                self?.actionError = error.localizedDescription
                self?.scheduleDismissActionError()
            }
        }
    }

    private func scheduleDismissActionError() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.actionError = nil
        }
    }
}
