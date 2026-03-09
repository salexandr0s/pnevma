import SwiftUI
import Observation
import Cocoa
import os

// MARK: - OnboardingView

struct OnboardingView: View {
    @State private var viewModel: OnboardingViewModel
    var onComplete: (() -> Void)?

    init(commandBus: CommandBus? = nil, onComplete: (() -> Void)? = nil) {
        _viewModel = State(wrappedValue: OnboardingViewModel(commandBus: commandBus))
        self.onComplete = onComplete
    }

    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text("Welcome to Pnevma")
                    .font(.largeTitle)
                    .bold()
                Text("AI-native terminal workspace")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 32)

            Divider()

            // Environment readiness checks
            GroupBox("Environment Readiness") {
                VStack(alignment: .leading, spacing: 8) {
                    ReadinessRow(label: "Rust backend", isReady: viewModel.rustReady)
                    ReadinessRow(label: "Ghostty terminal", isReady: viewModel.ghosttyReady)
                    ReadinessRow(label: "Git", isReady: viewModel.gitReady)
                    ReadinessRow(label: "Shell", isReady: viewModel.shellReady)
                }
                .padding(.vertical, 4)
            }

            // First project setup
            if viewModel.allReady {
                GroupBox("Get Started") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Open a project to begin, or create a new one with pnevma.toml configuration.")
                            .font(.body)
                            .foregroundStyle(.secondary)

                        Text("Agents run in isolated git worktrees, not in an OS sandbox. They keep this macOS user's filesystem and network access.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 12) {
                            Button("Open Existing Project") {
                                viewModel.openProject()
                            }
                            .buttonStyle(.borderedProminent)

                            Button("Create New Project") {
                                viewModel.scaffoldProject()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }

            Spacer()

            // Footer
            HStack {
                Button("Skip") {
                    onComplete?()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                if viewModel.projectOpened {
                    Button("Get Started") {
                        onComplete?()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 32)
        .frame(width: 520, height: 560)
        .onAppear { viewModel.checkReadiness() }
    }
}

// MARK: - ReadinessRow

struct ReadinessRow: View {
    let label: String
    let isReady: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isReady ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(isReady ? .green : .red)
            Text(label)
                .font(.body)
            Spacer()
            Text(isReady ? "Ready" : "Not found")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - ViewModel

@Observable @MainActor
final class OnboardingViewModel {
    var rustReady = false
    var ghosttyReady = false
    var gitReady = false
    var shellReady = false
    var projectOpened = false

    /// Injected command bus for backend calls.
    let commandBus: CommandBus?

    init(commandBus: CommandBus? = nil) {
        self.commandBus = commandBus
    }

    var allReady: Bool { rustReady && ghosttyReady && gitReady && shellReady }

    func checkReadiness() {
        // Check Rust bridge
        rustReady = true  // If we got here, the bridge loaded

        // Check ghostty
        #if canImport(GhosttyKit)
        ghosttyReady = true
        #else
        ghosttyReady = false
        #endif

        // Check git
        gitReady = FileManager.default.isExecutableFile(atPath: "/usr/bin/git")

        // Check shell
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        shellReady = FileManager.default.isExecutableFile(atPath: shell)
    }

    func openProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a project directory"

        if panel.runModal() == .OK, panel.url != nil {
            projectOpened = true
        }
    }

    func scaffoldProject() {
        guard let commandBus = commandBus else {
            Log.general.warning("CommandBus not available for scaffold")
            projectOpened = true
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a directory for the new project"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            do {
                struct ScaffoldParams: Encodable { let path: String }
                let _: EmptyScaffoldResponse = try await commandBus.call(
                    method: "project.initialize_scaffold",
                    params: ScaffoldParams(path: url.path)
                )
                await MainActor.run {
                    projectOpened = true
                }
            } catch {
                Log.general.error("Scaffold failed: \(error)")
                await MainActor.run {
                    projectOpened = true // Allow continuing even on error
                }
            }
        }
    }
}

private struct EmptyScaffoldResponse: Decodable {}

// MARK: - OnboardingWindow

final class OnboardingWindow {
    private var window: NSWindow?

    func show(commandBus: CommandBus? = nil, completion: @escaping () -> Void) {
        let view = OnboardingView(commandBus: commandBus, onComplete: { [weak self] in
            self?.window?.close()
            completion()
        })

        let hostingView = NSHostingView(rootView: view.environment(GhosttyThemeProvider.shared))
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                           styleMask: [.titled, .closable],
                           backing: .buffered, defer: false)
        win.title = "Welcome to Pnevma"
        win.contentView = hostingView
        win.center()
        win.makeKeyAndOrderFront(nil)
        self.window = win
    }
}
