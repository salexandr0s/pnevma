import SwiftUI
import Observation
import Cocoa

// MARK: - SshManagerView

struct SshManagerView: View {
    @State private var viewModel = SshManagerViewModel()
    @Environment(GhosttyThemeProvider.self) var theme

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
        .overlay(alignment: .bottom) {
            if let error = viewModel.actionError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: theme.backgroundColor))
            }
        }
        // sheet(isPresented:) is intentional: the sheet creates a new profile from scratch
        // with no pre-existing item, so sheet(item:) does not apply here.
        .sheet(isPresented: $viewModel.showAddSheet) {
            AddSshProfileSheet(onAdd: { viewModel.addProfile($0) })
        }
        .task { await viewModel.activate() }
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

// MARK: - NSView Wrapper

final class SshManagerPaneView: NSView, PaneContent {
    let paneID = PaneID()
    let paneType = "ssh"
    let shouldPersist = false
    var title: String { "SSH" }

    override init(frame: NSRect) {
        super.init(frame: frame)
        _ = addSwiftUISubview(SshManagerView())
    }

    required init?(coder: NSCoder) { fatalError() }
}
