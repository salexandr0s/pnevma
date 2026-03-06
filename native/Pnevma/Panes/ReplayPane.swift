import SwiftUI
import Cocoa

struct ReplayTimelinePayload: Decodable {
    let data: String?
    let chunk: String?
}

struct ReplayTimelineEvent: Decodable {
    let timestamp: String
    let kind: String
    let summary: String
    let payload: ReplayTimelinePayload
}

private struct SessionTimelineParams: Encodable {
    let sessionID: String
    let limit: Int
}

enum ReplayFrameBuilder {
    private static let incrementalOutputKinds: Set<String> = ["session_output"]

    static func buildFrames(from entries: [ReplayTimelineEvent]) -> [String] {
        var frames: [String] = []
        var transcript = ""

        for entry in entries {
            if entry.kind == "ScrollbackSnapshot" {
                guard let snapshot = entry.payload.data, !snapshot.isEmpty else { continue }
                if frames.isEmpty || transcript != snapshot {
                    transcript = snapshot
                    frames.append(snapshot)
                } else {
                    transcript = snapshot
                }
                continue
            }

            let nextChunk: String?
            if let chunk = entry.payload.chunk, !chunk.isEmpty {
                nextChunk = chunk
            } else if incrementalOutputKinds.contains(entry.kind),
                      let data = entry.payload.data,
                      !data.isEmpty {
                nextChunk = data
            } else {
                nextChunk = nil
            }

            guard let nextChunk else { continue }
            transcript += nextChunk
            frames.append(transcript)
        }

        return frames
    }
}

struct ReplayView: View {
    @StateObject private var viewModel: ReplayViewModel

    init(sessionID: String?) {
        _viewModel = StateObject(wrappedValue: ReplayViewModel(sessionID: sessionID))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Session Replay")
                    .font(.headline)

                Spacer()

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
                        Text(viewModel.emptyStateMessage)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

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

final class ReplayViewModel: ObservableObject {
    @Published var currentFrame: String?
    @Published var isPlaying = false
    @Published var playbackSpeed: Double = 1.0
    @Published var progress: Double = 0.0

    var currentTimeLabel: String { formatTime(progress * totalDuration) }
    var totalTimeLabel: String { formatTime(totalDuration) }
    var emptyStateMessage: String {
        sessionID == nil ? "No session selected for replay" : "No replay data available"
    }

    private let sessionID: String?
    private var frames: [String] = []
    private var currentFrameIndex: Int = 0
    private var totalDuration: Double = 0
    private var sessionObserverID: UUID?

    init(sessionID: String?) {
        self.sessionID = sessionID
        if let sessionID {
            sessionObserverID = SessionOutputHub.shared.addObserver(for: sessionID) { [weak self] event in
                self?.appendLiveChunk(event.chunk)
            }
        }
    }

    deinit {
        if let sessionObserverID {
            SessionOutputHub.shared.removeObserver(sessionObserverID)
        }
    }

    func load() {
        guard let sessionID, let bus = CommandBus.shared else {
            currentFrame = nil
            return
        }

        Task {
            do {
                let entries: [ReplayTimelineEvent] = try await bus.call(
                    method: "session.timeline",
                    params: SessionTimelineParams(sessionID: sessionID, limit: 1000)
                )
                let rebuiltFrames = ReplayFrameBuilder.buildFrames(from: entries)
                await MainActor.run {
                    self.frames = rebuiltFrames
                    self.currentFrameIndex = max(0, rebuiltFrames.count - 1)
                    self.currentFrame = rebuiltFrames.last
                    self.totalDuration = max(Double(max(rebuiltFrames.count - 1, 0)), 1.0)
                    self.progress = rebuiltFrames.isEmpty ? 0.0 : 1.0
                }
            } catch {
                // Keep the last rendered frame if timeline loading fails.
            }
        }
    }

    func togglePlayback() { isPlaying.toggle() }

    func stepForward() {
        guard !frames.isEmpty else { return }
        let newIndex = min(frames.count - 1, currentFrameIndex + 1)
        updateFrame(index: newIndex)
    }

    func stepBackward() {
        guard !frames.isEmpty else { return }
        let newIndex = max(0, currentFrameIndex - 1)
        updateFrame(index: newIndex)
    }

    func seekToProgress() {
        guard !frames.isEmpty else { return }
        let maxIndex = max(frames.count - 1, 0)
        let index = min(maxIndex, Int(round(progress * Double(maxIndex))))
        updateFrame(index: index)
    }

    private func updateFrame(index: Int) {
        currentFrameIndex = index
        currentFrame = frames[index]
        let maxIndex = max(frames.count - 1, 1)
        progress = Double(index) / Double(maxIndex)
    }

    private func appendLiveChunk(_ chunk: String) {
        let next = (frames.last ?? "") + chunk
        frames.append(next)
        currentFrameIndex = frames.count - 1
        currentFrame = next
        totalDuration = max(Double(max(frames.count - 1, 0)), 1.0)
        progress = 1.0
    }

    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

final class ReplayPaneView: NSView, PaneContent {
    let paneID = PaneID()
    let paneType = "replay"
    let sessionID: String?
    var title: String { "Replay" }

    init(frame: NSRect, sessionID: String? = nil) {
        self.sessionID = sessionID
        super.init(frame: frame)
        _ = addSwiftUISubview(ReplayView(sessionID: sessionID))
    }

    required init?(coder: NSCoder) { fatalError() }
}
