import AppKit
import Observation
import SwiftUI

@Observable
@MainActor
final class GitHubAuthSettingsViewModel {
    @ObservationIgnored
    private let commandBus: (any CommandCalling)?
    @ObservationIgnored
    private let bridgeEventHub: BridgeEventHub
    @ObservationIgnored
    private var bridgeObserverID: UUID?

    var snapshot: GitHubAuthSnapshot?
    var isLoading = false
    var switchingLogin: String?
    var isFixingGitHelper = false
    var actionError: String?

    init(
        commandBus: (any CommandCalling)? = CommandBus.shared,
        bridgeEventHub: BridgeEventHub = .shared
    ) {
        self.commandBus = commandBus
        self.bridgeEventHub = bridgeEventHub
        bridgeObserverID = bridgeEventHub.addObserver { [weak self] event in
            guard event.name == "github_auth_changed" else { return }
            self?.load(showLoadingState: false)
        }
    }

    deinit {
        MainActor.assumeIsolated {
            if let bridgeObserverID {
                bridgeEventHub.removeObserver(bridgeObserverID)
            }
        }
    }

    var isAuthJobRunning: Bool {
        snapshot?.authJob?.state == "running"
    }

    func load(showLoadingState: Bool = true) {
        guard let commandBus else { return }
        if showLoadingState {
            isLoading = true
        }
        Task {
            defer { isLoading = false }
            do {
                snapshot = try await commandBus.call(method: "github.auth.status", params: nil)
                actionError = nil
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    func refresh() {
        guard let commandBus else { return }
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                snapshot = try await commandBus.call(method: "github.auth.refresh", params: nil)
                actionError = nil
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    func addAccount() {
        guard let commandBus else { return }
        Task {
            do {
                snapshot = try await commandBus.call(method: "github.auth.add_account", params: nil)
                actionError = nil
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    func switchAccount(login: String) {
        guard let commandBus else { return }
        switchingLogin = login
        Task {
            defer { switchingLogin = nil }
            do {
                snapshot = try await commandBus.call(
                    method: "github.auth.switch",
                    params: GitHubAuthSwitchRequest(login: login)
                )
                actionError = nil
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    func fixGitHelper() {
        guard let commandBus else { return }
        isFixingGitHelper = true
        Task {
            defer { isFixingGitHelper = false }
            do {
                snapshot = try await commandBus.call(method: "github.auth.fix_git_helper", params: nil)
                actionError = nil
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    func installGitHubCLI() {
        guard let url = URL(string: "https://cli.github.com/") else { return }
        NSWorkspace.shared.open(url)
    }
}

struct GitHubSettingsTab: View {
    @Bindable var viewModel: GitHubAuthSettingsViewModel

    var body: some View {
        SettingsDetailPage(section: .github) {
            SettingsGroupCard(
                title: "GitHub CLI Accounts",
                description: "Manage the active GitHub CLI account used for github.com-backed issue, pull request, and CI actions."
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    headerRow

                    if viewModel.isLoading, viewModel.snapshot == nil {
                        ProgressView()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if let snapshot = viewModel.snapshot {
                        snapshotContent(snapshot)
                    } else {
                        Text("GitHub account status is unavailable.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let actionError = viewModel.actionError, !actionError.isEmpty {
                SettingsGroupCard(title: "Status") {
                    Text(actionError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            if let snapshot = viewModel.snapshot {
                Label(snapshot.cliAvailable ? "GitHub CLI detected" : "GitHub CLI missing", systemImage: snapshot.cliAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(snapshot.cliAvailable ? Color.secondary : Color.orange)
            }

            Spacer()

            Button("Refresh") { viewModel.refresh() }
            Button("Add Account") { viewModel.addAccount() }
                .disabled(
                    viewModel.isAuthJobRunning
                        || viewModel.isLoading
                        || viewModel.snapshot?.cliAvailable != true
                )
        }
    }

    private func snapshotContent(_ snapshot: GitHubAuthSnapshot) -> some View {
        Group {
            if !snapshot.cliAvailable {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Install GitHub CLI to manage GitHub accounts inside Pnevma.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Install GitHub CLI") { viewModel.installGitHubCLI() }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    if let authJob = snapshot.authJob, authJob.state == "running" {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(authJob.message ?? "Waiting for GitHub browser authentication to complete.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    HStack(spacing: 8) {
                        Text("Active account")
                            .font(.subheadline.weight(.semibold))
                        if let activeLogin = snapshot.activeLogin {
                            Text("@\(activeLogin)")
                                .font(.subheadline.monospaced())
                        } else {
                            Text("Not connected")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    if snapshot.accounts.isEmpty {
                        Text("No github.com accounts are currently connected in GitHub CLI.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(spacing: 10) {
                            ForEach(snapshot.accounts, id: \.login) { account in
                                GitHubAccountRow(
                                    account: account,
                                    isSwitching: viewModel.switchingLogin == account.login,
                                    action: { viewModel.switchAccount(login: account.login) }
                                )
                            }
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Git HTTPS helper")
                            .font(.subheadline.weight(.semibold))

                        Text(snapshot.gitHelper.detail ?? snapshot.gitHelper.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if snapshot.gitHelper.state == "warning" || snapshot.gitHelper.state == "error" {
                            Button("Fix Git auth") { viewModel.fixGitHelper() }
                                .disabled(viewModel.isFixingGitHelper)
                        }
                    }

                    if let authJob = snapshot.authJob,
                       authJob.state == "failed",
                       let message = authJob.message,
                       !message.isEmpty {
                        Divider()
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}

private struct GitHubAccountRow: View {
    let account: GitHubAuthAccount
    let isSwitching: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("@\(account.login)")
                        .font(.subheadline.monospaced())
                    if account.active {
                        Text("Active")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                    }
                    if account.state != "success" {
                        Text(account.state)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }

                let secondary = [account.gitProtocol, account.tokenSource].compactMap { $0 }.joined(separator: " • ")
                if !secondary.isEmpty {
                    Text(secondary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if !account.active {
                Button(isSwitching ? "Switching…" : "Use") { action() }
                    .disabled(isSwitching)
            }
        }
    }
}
