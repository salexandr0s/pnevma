import SwiftUI
import Cocoa

// MARK: - ReplayView

struct ReplayView: View {
    @StateObject private var viewModel = ReplayViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 12) {
                Text("Session Replay")
                    .font(.headline)

                Spacer()

                // Playback controls
                Button(action: { viewModel.stepBackward() }) {
                    Image(systemName: "backward.frame.fill")
                }
                .buttonStyle(.plain)

                Button(action: { viewModel.togglePlayback() }) {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.plain)

                Button(action: { viewModel.stepForward() }) {
                    Image(systemName: "forward.frame.fill")
                }
                .buttonStyle(.plain)

                // Speed control
                Picker("Speed", selection: $viewModel.playbackSpeed) {
                    Text("0.5x").tag(0.5)
                    Text("1x").tag(1.0)
                    Text("2x").tag(2.0)
                    Text("4x").tag(4.0)
                }
                .frame(width: 100)
            }
            .padding(12)

            Divider()

            // Terminal replay area (placeholder — would use read-only ghostty surface)
            ZStack {
                Color(nsColor: .textBackgroundColor)

                if let content = viewModel.currentFrame {
                    ScrollView {
                        Text(content)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "play.rectangle")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No session selected for replay")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            // Timeline scrubber
            HStack(spacing: 8) {
                Text(viewModel.currentTimeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 60)

                Slider(value: $viewModel.progress, in: 0...1) { editing in
                    if !editing { viewModel.seekToProgress() }
                }

                Text(viewModel.totalTimeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 60)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .onAppear { viewModel.load() }
    }
}

// MARK: - ViewModel

final class ReplayViewModel: ObservableObject {
    @Published var currentFrame: String?
    @Published var isPlaying = false
    @Published var playbackSpeed: Double = 1.0
    @Published var progress: Double = 0.0

    var currentTimeLabel: String { formatTime(progress * totalDuration) }
    var totalTimeLabel: String { formatTime(totalDuration) }

    private var totalDuration: Double = 0

    func load() {
        // pnevma_call("session.scrollback", ...)
    }

    func togglePlayback() { isPlaying.toggle() }
    func stepForward() { progress = min(1.0, progress + 0.01) }
    func stepBackward() { progress = max(0.0, progress - 0.01) }
    func seekToProgress() {
        // Seek to the frame at the given progress point
    }

    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - NSView Wrapper

final class ReplayPaneView: NSView, PaneContent {
    let paneID = PaneID()
    let paneType = "replay"
    var title: String { "Replay" }

    override init(frame: NSRect) {
        super.init(frame: frame)
        _ = addSwiftUISubview(ReplayView())
    }

    required init?(coder: NSCoder) { fatalError() }
}
