import SwiftUI

enum GitHubAccountPickerPrimaryAction: Equatable {
    case addAccount
    case installCLI

    static func resolve(snapshot: GitHubAuthSnapshot?) -> Self? {
        guard let snapshot else { return nil }
        return snapshot.cliAvailable ? .addAccount : .installCLI
    }

    var accessibilityLabel: String {
        switch self {
        case .addAccount:
            "Add GitHub account"
        case .installCLI:
            "Install GitHub CLI"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .addAccount:
            "githubAccountPicker.header.add"
        case .installCLI:
            "githubAccountPicker.header.install"
        }
    }
}

struct GitHubAccountPickerPopover: View {
    let snapshot: GitHubAuthSnapshot?
    let onSelect: (String) -> Void
    let onAddAccount: () -> Void
    let onInstallCLI: () -> Void
    let onDismiss: () -> Void

    @State private var searchText = ""
    @State private var hoveredLogin: String?

    private var filteredAccounts: [GitHubAuthAccount] {
        guard let snapshot else { return [] }
        guard !searchText.isEmpty else { return snapshot.accounts }
        return snapshot.accounts.filter { account in
            account.login.localizedCaseInsensitiveContains(searchText)
                || (account.tokenSource?.localizedCaseInsensitiveContains(searchText) ?? false)
                || (account.gitProtocol?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    var body: some View {
        let primaryAction = GitHubAccountPickerPrimaryAction.resolve(snapshot: snapshot)
        ToolbarAttachmentScaffold(
            title: "GitHub Accounts",
            subtitle: snapshotSubtitle,
            headerActions: {
                if let primaryAction {
                    Button {
                        switch primaryAction {
                        case .addAccount:
                            onAddAccount()
                        case .installCLI:
                            onInstallCLI()
                        }
                        onDismiss()
                    } label: {
                        Label("Add account", systemImage: "plus")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(primaryAction.accessibilityLabel)
                    .accessibilityIdentifier(primaryAction.accessibilityIdentifier)
                }
            }
        ) {
            content
        }
        .frame(width: 320, height: 360)
        .accessibilityIdentifier("githubAccountPicker")
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot {
            if !snapshot.cliAvailable {
                EmptyStateView(
                    icon: "arrow.down.circle",
                    title: "GitHub CLI Required",
                    message: "Install GitHub CLI to switch or add accounts from the title bar.",
                    actionTitle: "Install GitHub CLI",
                    action: {
                        onInstallCLI()
                        onDismiss()
                    }
                )
            } else {
                VStack(spacing: 0) {
                    if snapshot.accounts.count > 5 {
                        searchField
                    }

                    if let authJob = snapshot.authJob, authJob.state == "running" {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(authJob.message ?? "Waiting for GitHub browser sign-in to complete.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, DesignTokens.Spacing.md)
                        .padding(.top, snapshot.accounts.count > 5 ? 0 : DesignTokens.Spacing.sm)
                        .padding(.bottom, DesignTokens.Spacing.sm)
                    }

                    Divider()
                        .padding(.horizontal, DesignTokens.Spacing.sm)

                    if filteredAccounts.isEmpty {
                        if snapshot.accounts.isEmpty {
                            EmptyStateView(
                                icon: "person.crop.circle.badge.plus",
                                title: "No GitHub Accounts",
                                message: "Add a GitHub account to switch CLI users directly from the title bar.",
                                actionTitle: "Add Account",
                                action: {
                                    onAddAccount()
                                    onDismiss()
                                }
                            )
                        } else {
                            EmptyStateView(
                                icon: "magnifyingglass",
                                title: "No Matching Accounts",
                                message: "Try a different login."
                            )
                        }
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 1) {
                                ForEach(filteredAccounts, id: \.login) { account in
                                    accountRow(account)
                                }
                            }
                            .padding(.horizontal, DesignTokens.Spacing.sm - 2)
                            .padding(.vertical, DesignTokens.Spacing.xs)
                        }
                    }
                }
            }
        } else {
            VStack(spacing: DesignTokens.Spacing.sm) {
                ProgressView()
                Text("Loading GitHub accounts…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var snapshotSubtitle: String? {
        guard let snapshot else { return "Checking GitHub CLI status…" }
        if let activeLogin = snapshot.activeLogin {
            return "Current account: @\(activeLogin)"
        }
        if let authJob = snapshot.authJob, authJob.state == "running" {
            return "Complete the browser flow to finish signing in."
        }
        return "Switch the active github.com account used by GitHub CLI."
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            TextField("Filter accounts…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5))
        )
        .padding(.horizontal, DesignTokens.Spacing.sm + 2)
        .padding(.top, DesignTokens.Spacing.sm)
        .padding(.bottom, DesignTokens.Spacing.sm)
    }

    @ViewBuilder
    private func accountRow(_ account: GitHubAuthAccount) -> some View {
        let isHovered = hoveredLogin == account.login
        let secondary = [account.gitProtocol, account.tokenSource].compactMap { $0 }.joined(separator: " • ")

        Button {
            guard !account.active else { return }
            onSelect(account.login)
            onDismiss()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: account.active ? "checkmark.circle.fill" : "person.crop.circle")
                    .font(.system(size: 12, weight: account.active ? .semibold : .regular))
                    .foregroundStyle(account.active ? Color.accentColor : .secondary)
                    .frame(width: 18, alignment: .center)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("@\(account.login)")
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if account.active {
                            Text("Active")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(Color.accentColor.opacity(0.12))
                                )
                        }

                        if account.state != "success" {
                            Text(account.state)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(Color.orange.opacity(0.12))
                                )
                        }
                    }

                    if !secondary.isEmpty {
                        Text(secondary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(
                        isHovered
                            ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.15)
                            : Color.clear
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(account.active)
        .onHover { isHovering in
            hoveredLogin = isHovering ? account.login : nil
        }
        .accessibilityLabel(account.active ? "@\(account.login), active GitHub account" : "@\(account.login)")
    }
}
