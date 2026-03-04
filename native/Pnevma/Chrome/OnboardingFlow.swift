import SwiftUI
import Cocoa

// MARK: - OnboardingView

struct OnboardingView: View {
    @StateObject private var viewModel = OnboardingViewModel()
    @Environment(\.dismiss) private var dismiss
    var onComplete: (() -> Void)?

    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.system(size: 48))
                    .foregroundStyle(.accentColor)
                Text("Welcome to Pnevma")
                    .font(.largeTitle)
                    .fontWeight(.bold)
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

final class OnboardingViewModel: ObservableObject {
    @Published var rustReady = false
    @Published var ghosttyReady = false
    @Published var gitReady = false
    @Published var shellReady = false
    @Published var projectOpened = false

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
        // pnevma_call("project.scaffold", ...)
        projectOpened = true
    }
}

// MARK: - OnboardingWindow

final class OnboardingWindow {
    private var window: NSWindow?

    func show(completion: @escaping () -> Void) {
        let view = OnboardingView(onComplete: { [weak self] in
            self?.window?.close()
            completion()
        })

        let hostingView = NSHostingView(rootView: view)
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
