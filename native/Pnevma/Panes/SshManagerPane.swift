import SwiftUI
import Cocoa

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

// MARK: - SshManagerView

struct SshManagerView: View {
    @StateObject private var viewModel = SshManagerViewModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("SSH Connections")
                    .font(.headline)
                Spacer()
                Button("Add Profile") { viewModel.showAddSheet = true }
                    .buttonStyle(.bordered)
            }
            .padding(12)

            Divider()

            List {
                // SSH Profiles
                Section("Profiles") {
                    ForEach(viewModel.profiles) { profile in
                        SshProfileRow(profile: profile,
                                      onConnect: { viewModel.connect(profile) },
                                      onDisconnect: { viewModel.disconnect(profile) })
                    }
                }

                // Tailscale discovery
                if !viewModel.tailscaleDevices.isEmpty {
                    Section("Tailscale Network") {
                        ForEach(viewModel.tailscaleDevices) { device in
                            TailscaleRow(device: device,
                                         onConnect: { viewModel.connectTailscale(device) })
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .sheet(isPresented: $viewModel.showAddSheet) {
            AddSshProfileSheet(onAdd: { viewModel.addProfile($0) })
        }
        .onAppear { viewModel.load() }
    }
}

// MARK: - SshProfileRow

struct SshProfileRow: View {
    let profile: SshProfile
    let onConnect: () -> Void
    let onDisconnect: () -> Void

    var body: some View {
        HStack {
            Circle()
                .fill(profile.isConnected ? Color.green : Color.secondary.opacity(0.3))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(.body)
                Text("\(profile.user)@\(profile.host):\(profile.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if profile.isConnected {
                Button("Disconnect") { onDisconnect() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Button("Connect") { onConnect() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }
}

// MARK: - TailscaleRow

struct TailscaleRow: View {
    let device: TailscaleDevice
    let onConnect: () -> Void

    var body: some View {
        HStack {
            Circle()
                .fill(device.isOnline ? Color.green : Color.red)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.hostname)
                    .font(.body)
                Text(device.ipAddress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if device.isOnline {
                Button("SSH") { onConnect() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }
}

// MARK: - AddSshProfileSheet

struct AddSshProfileSheet: View {
    let onAdd: (SshProfile) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var user = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("Add SSH Profile")
                .font(.headline)

            Form {
                TextField("Name", text: $name)
                TextField("Host", text: $host)
                TextField("Port", text: $port)
                TextField("User", text: $user)
            }

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Add") {
                    let profile = SshProfile(
                        id: UUID().uuidString, name: name, host: host,
                        port: Int(port) ?? 22, user: user,
                        identityFile: nil, isConnected: false)
                    onAdd(profile)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || host.isEmpty || user.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

// MARK: - ViewModel

final class SshManagerViewModel: ObservableObject {
    @Published var profiles: [SshProfile] = []
    @Published var tailscaleDevices: [TailscaleDevice] = []
    @Published var showAddSheet = false

    func load() {
        guard let bus = CommandBus.shared else { return }
        Task {
            do {
                async let profilesResult: [SshProfile] = bus.call(method: "ssh.list_profiles")
                async let devicesResult: [TailscaleDevice] = bus.call(method: "ssh.discover_tailscale")
                let (p, d) = try await (profilesResult, devicesResult)
                await MainActor.run {
                    self.profiles = p
                    self.tailscaleDevices = d
                }
            } catch {
                // Log error, keep existing state
            }
        }
    }

    func addProfile(_ profile: SshProfile) {
        profiles.append(profile)
        guard let bus = CommandBus.shared else { return }
        Task {
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
                // Log error
            }
        }
    }

    func connect(_ profile: SshProfile) {
        guard let bus = CommandBus.shared else { return }
        Task {
            do {
                struct Params: Encodable { let profileId: String }
                let _: [String: Bool] = try await bus.call(method: "ssh.connect", params: Params(profileId: profile.id))
                await MainActor.run {
                    if let idx = self.profiles.firstIndex(where: { $0.id == profile.id }) {
                        self.profiles[idx].isConnected = true
                    }
                }
            } catch {
                // Log error
            }
        }
    }

    func disconnect(_ profile: SshProfile) {
        guard let bus = CommandBus.shared else { return }
        Task {
            do {
                struct Params: Encodable { let profileId: String }
                let _: [String: Bool] = try await bus.call(method: "ssh.disconnect", params: Params(profileId: profile.id))
                await MainActor.run {
                    if let idx = self.profiles.firstIndex(where: { $0.id == profile.id }) {
                        self.profiles[idx].isConnected = false
                    }
                }
            } catch {
                // Log error
            }
        }
    }

    func connectTailscale(_ device: TailscaleDevice) {
        guard let bus = CommandBus.shared else { return }
        Task {
            do {
                struct Params: Encodable { let host: String }
                let _: [String: Bool] = try await bus.call(method: "ssh.connect", params: Params(host: device.ipAddress))
            } catch {
                // Log error
            }
        }
    }
}

// MARK: - NSView Wrapper

final class SshManagerPaneView: NSView, PaneContent {
    let paneID = PaneID()
    let paneType = "ssh"
    var title: String { "SSH" }

    override init(frame: NSRect) {
        super.init(frame: frame)
        _ = addSwiftUISubview(SshManagerView())
    }

    required init?(coder: NSCoder) { fatalError() }
}
