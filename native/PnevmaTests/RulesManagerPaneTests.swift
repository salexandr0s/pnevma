import XCTest
@testable import Pnevma

@MainActor
final class RulesManagerPaneTests: XCTestCase {
    private func waitUntil(
        timeoutNanos: UInt64 = 1_000_000_000,
        pollIntervalNanos: UInt64 = 10_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping () async -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanos
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(nanoseconds: pollIntervalNanos)
        }
        XCTFail("Timed out waiting for rules-manager condition", file: file, line: line)
    }

    func testOpeningStateShowsWaitingMessageInsteadOfNoProjectState() async throws {
        let activationHub = ActiveWorkspaceActivationHub()
        let viewModel = RulesManagerViewModel(commandBus: nil, activationHub: activationHub)

        activationHub.update(.opening(workspaceID: UUID(), generation: 1))

        try await waitUntil {
            !viewModel.isProjectOpen
                && viewModel.projectStatusMessage == "Waiting for project activation..."
                && viewModel.rules.isEmpty
        }
    }
}
