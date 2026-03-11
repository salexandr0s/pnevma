import SwiftUI
import Observation

// MARK: - ViewModel

@Observable @MainActor
final class DailyBriefViewModel {
    private enum ViewState: Equatable {
        case waiting(String)
        case loading
        case ready
        case failed(String)
    }

    var brief: DailyBrief?
    private var viewState: ViewState = .waiting("Open a project to load the daily brief.")

    @ObservationIgnored
    private let commandBus: (any CommandCalling)?
    @ObservationIgnored
    private let activationHub: ActiveWorkspaceActivationHub
    @ObservationIgnored
    private var activationObserverID: UUID?

    init(
        commandBus: (any CommandCalling)? = CommandBus.shared,
        activationHub: ActiveWorkspaceActivationHub = .shared
    ) {
        self.commandBus = commandBus
        self.activationHub = activationHub

        activationObserverID = activationHub.addObserver { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleActivationState(state)
            }
        }
    }

    deinit {
        if let activationObserverID {
            activationHub.removeObserver(activationObserverID)
        }
    }

    var statusMessage: String? {
        switch viewState {
        case .waiting(let message), .failed(let message):
            return message
        case .loading:
            return "Loading daily brief..."
        case .ready:
            return nil
        }
    }

    var isLoading: Bool {
        if case .loading = viewState { return true }
        return false
    }

    func activate() async {
        handleActivationState(activationHub.currentState)
    }

    private var loadTask: Task<Void, Never>?

    func load() {
        guard let bus = commandBus else {
            viewState = .failed("Daily brief is unavailable because the command bus is not configured.")
            return
        }
        if brief == nil {
            viewState = .loading
        }
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result: DailyBrief = try await bus.call(method: "project.daily_brief", params: nil)
                guard !Task.isCancelled else { return }
                self.brief = result
                self.viewState = .ready
            } catch {
                guard !Task.isCancelled else { return }
                self.handleLoadFailure(error)
            }
        }
    }

    private func handleActivationState(_ state: ActiveWorkspaceActivationState) {
        switch state {
        case .idle:
            viewState = .waiting("Waiting for project activation...")
        case .opening:
            viewState = .waiting("Waiting for project activation...")
        case .open:
            load()
        case .failed(_, _, let message):
            viewState = .failed(message)
        case .closed:
            loadTask?.cancel()
            brief = nil
            viewState = .waiting("Open a project to load the daily brief.")
        }
    }

    private func handleLoadFailure(_ error: Error) {
        if PnevmaError.isProjectNotReady(error) {
            viewState = .waiting("Waiting for project activation...")
            return
        }
        viewState = .failed(error.localizedDescription)
    }
}
