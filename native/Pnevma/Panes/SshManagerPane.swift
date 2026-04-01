import SwiftUI
import Observation
import Cocoa

// MARK: - SshManagerView

struct SshManagerView: View {
    @State private var viewModel = SshManagerViewModel()

    var body: some View {
        NativePaneScaffold(
            title: "SSH Connections",
            subtitle: "Profiles, discovery, and remote workspace entry points",
            systemImage: "network",
            role: .manager,
            inlineHeaderIdentifier: "pane.ssh.inlineHeader",
            inlineHeaderLabel: "SSH inline header"
        ) {
            Button("Add Profile") { viewModel.showAddSheet = true }
                .buttonStyle(.bordered)
                .keyboardShortcut("n", modifiers: .command)
        } content: {
            if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.profiles.isEmpty && viewModel.tailscaleDevices.isEmpty {
                EmptyStateView(
                    icon: "network",
                    title: "No SSH Profiles",
                    actionTitle: "Add Profile",
                    action: { viewModel.showAddSheet = true }
                )
            } else {
                NativeCollectionShell {
                    List {
                        Section("Profiles") {
                            ForEach(viewModel.profiles) { profile in
                                SshProfileRow(profile: profile,
                                              onConnect: { viewModel.connect(profile) },
                                              onDisconnect: { viewModel.disconnect(profile) })
                                    .accessibilityElement(children: .combine)
                            }
                        }

                        if !viewModel.tailscaleDevices.isEmpty {
                            Section("Tailscale Network") {
                                ForEach(viewModel.tailscaleDevices) { device in
                                    TailscaleRow(device: device,
                                                 onOpenWorkspace: { viewModel.openWorkspace(device) })
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                }
            }
        }
        .overlay(alignment: .bottom) { ErrorBanner(message: viewModel.actionError) }
        // sheet(isPresented:) is intentional: the sheet creates a new profile from scratch
        // with no pre-existing item, so sheet(item:) does not apply here.
        .sheet(isPresented: $viewModel.showAddSheet) {
            AddSshProfileSheet(onAdd: { viewModel.addProfile($0) })
        }
        .task { await viewModel.activate() }
        .accessibilityIdentifier("pane.ssh")
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
    let onOpenWorkspace: () -> Void

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
                Button("Open Workspace") { onOpenWorkspace() }
                    .buttonStyle(.borderedProminent)
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
    @State private var port = 22
    @State private var user = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("Add SSH Profile")
                .font(.headline)

            Form {
                TextField("Name", text: $name)
                TextField("Host", text: $host)
                TextField("Port", value: $port, format: .number)
                TextField("User", text: $user)
            }

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Add") {
                    let profile = SshProfile(
                        id: UUID().uuidString, name: name, host: host,
                        port: port, user: user,
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
    let shouldPersist = true
    var title: String { "SSH" }

    init(frame: NSRect, chromeContext: PaneChromeContext = .standard) {
        super.init(frame: frame)
        _ = addSwiftUISubview(SshManagerView(), chromeContext: chromeContext)
    }

    required init?(coder: NSCoder) { fatalError() }
}
