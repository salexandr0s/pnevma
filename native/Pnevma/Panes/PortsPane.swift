import Cocoa
import SwiftUI

// MARK: - PortsView (SwiftUI)

struct PortsView: View {
    @Bindable var viewModel: PortsViewModel
    @Environment(GhosttyThemeProvider.self) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Label("Listening Ports", systemImage: "network.badge.shield.half.filled")
                    .font(.headline)
                Spacer()
                if viewModel.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(DesignTokens.Spacing.md)

            Divider()

            if viewModel.visiblePorts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "network.slash")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("No listening ports detected")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(viewModel.visiblePorts) { port in
                            PortRow(port: port, viewModel: viewModel)
                        }
                    }
                    .padding(DesignTokens.Spacing.sm)
                }
            }
        }
        .accessibilityIdentifier("portsPane")
    }
}

// MARK: - PortRow

struct PortRow: View {
    let port: PortEntry
    let viewModel: PortsViewModel
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            // Port number
            Text("\(port.port)")
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .frame(width: 56, alignment: .trailing)

            // Label & process
            VStack(alignment: .leading, spacing: 1) {
                Text(port.displayLabel)
                    .font(.body)
                Text(port.processName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isHovering {
                Button("Open") {
                    viewModel.openInBrowser(port: port)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    viewModel.copyAddress(port: port)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Copy address")

                Button {
                    viewModel.dismissPort(port)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Dismiss")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? Color.accentColor.opacity(0.06) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Open in Browser") { viewModel.openInBrowser(port: port) }
            Button("Copy Address") { viewModel.copyAddress(port: port) }
            Divider()
            Button("Dismiss") { viewModel.dismissPort(port) }
        }
        .accessibilityIdentifier("port.row.\(port.port)")
    }
}

// MARK: - PortsPaneView (NSView + PaneContent)

final class PortsPaneView: NSView, PaneContent {
    let paneID: PaneID
    let paneType = "ports"
    let title = "Ports"
    let viewModel = PortsViewModel()
    private var hostingView: NSHostingView<AnyView>?
    private var activeBus: (any CommandCalling)?

    init(paneID: PaneID) {
        self.paneID = paneID
        super.init(frame: .zero)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        let rootView = PortsView(viewModel: viewModel)
            .environment(GhosttyThemeProvider.shared)
        let hosting = NSHostingView(rootView: AnyView(rootView))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        hostingView = hosting
    }

    func activate() {
        // Polling will be started when commandBus is provided via the pane factory
    }

    func deactivate() {
        viewModel.stopPolling()
    }

    func dispose() {
        viewModel.stopPolling()
    }

    /// Call after activate to begin port polling with the workspace's command bus.
    func startPolling(using bus: any CommandCalling) {
        activeBus = bus
        viewModel.startPolling(using: bus)
    }
}
