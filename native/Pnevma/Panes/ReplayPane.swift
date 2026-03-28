import SwiftUI
import Observation
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
    @State private var viewModel: ReplayViewModel

    @MainActor
    init(sessionID: String?, viewModel: ReplayViewModel? = nil) {
        _viewModel = State(wrappedValue: viewModel ?? ReplayViewModel(sessionID: sessionID))
    }

    var body: some View {
        NativePaneScaffold(
            title: "Session Replay",
            subtitle: "Scrub recorded terminal output with playback controls",
            systemImage: "play.rectangle",
            role: .utility,
            inlineHeaderIdentifier: "pane.replay.inlineHeader",
            inlineHeaderLabel: "Session Replay inline header"
        ) {
            Button(action: { viewModel.stepBackward() }) {
                Image(systemName: "backward.frame.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Step backward")
            .accessibilityIdentifier("pane.replay.backward")

            Button(action: { viewModel.togglePlayback() }) {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(viewModel.isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("pane.replay.playPause")

            Button(action: { viewModel.stepForward() }) {
                Image(systemName: "forward.frame.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Step forward")
            .accessibilityIdentifier("pane.replay.forward")

            Picker("Speed", selection: $viewModel.playbackSpeed) {
                Text("0.5x").tag(0.5)
                Text("1x").tag(1.0)
                Text("2x").tag(2.0)
                Text("4x").tag(4.0)
            }
            .frame(width: 100)
            .accessibilityLabel("Playback speed")
            .accessibilityIdentifier("pane.replay.speed")
        } content: {
            VStack(spacing: 0) {
                ZStack {
                    Color.clear

                    if let content = viewModel.currentFrame {
                        ScrollView {
                            Text(content)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(DesignTokens.Spacing.md)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        EmptyStateView(
                            icon: "play.rectangle",
                            title: viewModel.emptyStateMessage
                        )
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
                    .accessibilityLabel("Replay progress")

                    Text(viewModel.totalTimeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 60)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(ChromeSurfaceStyle.toolbar.color)
            }
        }
        .task { await viewModel.activate() }
        .accessibilityIdentifier("pane.replay")
    }
}

@Observable @MainActor
final class ReplayViewModel {
    private enum ViewState: Equatable {
        case noSession
        case closed(String)
        case waiting(String)
        case loading(String)
        case ready
        case failed(String)
    }

    var currentFrame: String?
    var isPlaying = false
    var playbackSpeed: Double = 1.0
    var progress: Double = 0.0

    var currentTimeLabel: String { formatTime(progress * totalDuration) }
    var totalTimeLabel: String { formatTime(totalDuration) }
    var emptyStateMessage: String {
        switch viewState {
        case .noSession:
            return "No session selected for replay"
        case .closed(let message), .waiting(let message), .loading(let message), .failed(let message):
            return message
        case .ready:
            return "No replay data available"
        }
    }

    @ObservationIgnored
    private let sessionID: String?
    @ObservationIgnored
    private let commandBus: (any CommandCalling)?
    @ObservationIgnored
    private let activationHub: ActiveWorkspaceActivationHub
    @ObservationIgnored
    private let sessionOutputHub: SessionOutputHub
    private var frames: [String] = []
    private var currentFrameIndex: Int = 0
    private var totalDuration: Double = 0
    private var viewState: ViewState
    @ObservationIgnored
    private var sessionObserverID: UUID?
    @ObservationIgnored
    private var activationObserverID: UUID?
    @ObservationIgnored
    private var bufferedLiveChunks: [String] = []
    private enum BootstrapPhase {
        case idle, inProgress, completed
    }
    private var bootstrapPhase: BootstrapPhase = .idle

    init(
        sessionID: String?,
        commandBus: (any CommandCalling)? = CommandBus.shared,
        activationHub: ActiveWorkspaceActivationHub = .shared,
        sessionOutputHub: SessionOutputHub = .shared
    ) {
        self.sessionID = sessionID
        self.commandBus = commandBus
        self.activationHub = activationHub
        self.sessionOutputHub = sessionOutputHub
        self.viewState = sessionID == nil ? .noSession : .closed("Open a project to load replay.")
        if let sessionID {
            sessionObserverID = sessionOutputHub.addObserver(for: sessionID) { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.handleLiveChunk(event.chunk)
                }
            }
        }
        activationObserverID = activationHub.addObserver { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleActivationState(state)
            }
        }
    }

    deinit {
        if let sessionObserverID {
            sessionOutputHub.removeObserver(sessionObserverID)
        }
        if let activationObserverID {
            activationHub.removeObserver(activationObserverID)
        }
    }

    func activate() async {
        handleActivationState(activationHub.currentState)
    }

    func load() {
        guard let sessionID else {
            currentFrame = nil
            viewState = .noSession
            return
        }
        guard let bus = commandBus else {
            viewState = .failed("Replay loading is unavailable because the command bus is not configured.")
            return
        }
        guard bootstrapPhase != .inProgress else { return }

        viewState = .loading("Loading replay...")
        bootstrapPhase = .inProgress
        Task { [weak self] in
            guard let self else { return }
            do {
                let entries: [ReplayTimelineEvent] = try await bus.call(
                    method: "session.timeline",
                    params: SessionTimelineParams(sessionID: sessionID, limit: 1000)
                )
                let rebuiltFrames = ReplayFrameBuilder.buildFrames(from: entries)
                self.finishBootstrap(with: rebuiltFrames)
            } catch {
                self.handleBootstrapFailure(error)
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

    private func handleActivationState(_ state: ActiveWorkspaceActivationState) {
        guard sessionID != nil else {
            viewState = .noSession
            return
        }

        switch state {
        case .idle:
            if bootstrapPhase != .completed {
                viewState = .waiting("Waiting for project activation...")
            }
        case .opening:
            if bootstrapPhase != .completed {
                viewState = .waiting("Waiting for project activation...")
            }
        case .open:
            if bootstrapPhase != .completed {
                load()
            }
        case .failed(_, _, let message):
            if bootstrapPhase != .completed {
                viewState = .failed(message)
            }
        case .closed:
            bootstrapPhase = .idle
            bufferedLiveChunks.removeAll()
            viewState = .closed("Open a project to load replay.")
        }
    }

    private func handleLiveChunk(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        if bootstrapPhase != .completed {
            bufferedLiveChunks.append(chunk)
            return
        }
        appendLiveChunk(chunk)
    }

    private func finishBootstrap(with rebuiltFrames: [String]) {
        bootstrapPhase = .completed
        frames = Self.framesByApplyingBufferedChunks(rebuiltFrames, bufferedChunks: bufferedLiveChunks)
        bufferedLiveChunks.removeAll()
        currentFrameIndex = max(0, frames.count - 1)
        currentFrame = frames.last
        totalDuration = max(Double(max(frames.count - 1, 0)), 1.0)
        progress = frames.isEmpty ? 0.0 : 1.0
        viewState = .ready
    }

    private func handleBootstrapFailure(_ error: Error) {
        bootstrapPhase = .idle
        if PnevmaError.isProjectNotReady(error) {
            viewState = .waiting("Waiting for project activation...")
            return
        }
        viewState = .failed(error.localizedDescription)
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

    private static func framesByApplyingBufferedChunks(
        _ rebuiltFrames: [String],
        bufferedChunks: [String]
    ) -> [String] {
        guard !bufferedChunks.isEmpty else { return rebuiltFrames }

        var mergedFrames = rebuiltFrames
        var transcript = rebuiltFrames.last ?? ""
        for chunk in bufferedChunks {
            let suffix = nonOverlappingSuffix(for: chunk, onto: transcript)
            guard !suffix.isEmpty else { continue }
            transcript += suffix
            mergedFrames.append(transcript)
        }
        return mergedFrames
    }

    private static func nonOverlappingSuffix(for chunk: String, onto transcript: String) -> String {
        guard !chunk.isEmpty else { return "" }
        let maxOverlap = min(chunk.count, transcript.count)
        for length in stride(from: maxOverlap, through: 1, by: -1) {
            if transcript.hasSuffix(String(chunk.prefix(length))) {
                return String(chunk.dropFirst(length))
            }
        }
        return chunk
    }

    private func formatTime(_ seconds: Double) -> String {
        let duration = Duration.seconds(seconds)
        return duration.formatted(.time(pattern: .minuteSecond))
    }
}

final class ReplayPaneView: NSView, PaneContent {
    let paneID = PaneID()
    let paneType = "replay"
    let shouldPersist = true
    let sessionID: String?
    var title: String { "Replay" }

    init(
        frame: NSRect,
        sessionID: String? = nil,
        chromeContext: PaneChromeContext = .standard
    ) {
        self.sessionID = sessionID
        super.init(frame: frame)
        _ = addSwiftUISubview(ReplayView(sessionID: sessionID), chromeContext: chromeContext)
    }

    required init?(coder: NSCoder) { fatalError() }
}
