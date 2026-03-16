import SwiftUI
import Observation
import Foundation

extension Notification.Name {
    static let providerUsageStoreDidChange = Notification.Name("providerUsageStoreDidChange")
    static let analyticsSegmentRequested = Notification.Name("analyticsSegmentRequested")
}

@MainActor
final class AnalyticsNavigationHub {
    static let shared = AnalyticsNavigationHub()

    private var requestedSegmentRawValue: String?

    func request(segmentRawValue: String) {
        requestedSegmentRawValue = segmentRawValue
        NotificationCenter.default.post(name: .analyticsSegmentRequested, object: self)
    }

    func takeRequestedSegmentRawValue() -> String? {
        defer { requestedSegmentRawValue = nil }
        return requestedSegmentRawValue
    }
}

struct ProviderUsageOverview: Decodable {
    let generatedAt: String
    let refreshIntervalSeconds: Int
    let staleAfterSeconds: Int
    let providers: [ProviderUsageProviderSnapshot]
}

private nonisolated(unsafe) let providerUsageDayParser: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return formatter
}()

private nonisolated(unsafe) let providerUsageTimestampParser: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

private nonisolated(unsafe) let providerUsageTimestampParserNoFraction: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}()

private nonisolated(unsafe) let providerUsageRelativeFormatter = RelativeDateTimeFormatter()

private func providerFormatTokens(_ value: Int) -> String {
    value.formatted(.number.grouping(.automatic))
}

private func providerFormatCompactTokens(_ value: Int) -> String {
    if abs(value) >= 10_000 {
        return value.formatted(.number.notation(.compactName))
    }
    return providerFormatTokens(value)
}

private func providerFormatDateLabel(_ raw: String) -> String {
    guard let date = providerUsageDayParser.date(from: raw) else { return raw }
    return date.formatted(.dateTime.month(.abbreviated).day())
}

struct ProviderUsageProviderSnapshot: Decodable, Identifiable {
    var id: String { provider }
    let provider: String
    let displayName: String
    let status: String
    let statusMessage: String?
    let repairHint: String?
    let source: String
    let accountEmail: String?
    let planLabel: String?
    let lastRefreshedAt: String
    let sessionWindow: ProviderQuotaWindow?
    let weeklyWindow: ProviderQuotaWindow?
    let modelWindows: [ProviderQuotaWindow]
    let credit: ProviderCredit?
    let localUsage: ProviderLocalUsageSummary
    let dashboardExtras: ProviderDashboardExtras?
}

struct ProviderQuotaWindow: Decodable, Identifiable {
    var id: String { label }
    let label: String
    let percentUsed: Double?
    let percentRemaining: Double?
    let resetAt: String?
}

struct ProviderCredit: Decodable {
    let label: String
    let balanceDisplay: String?
    let isUnlimited: Bool
}

struct ProviderLocalUsageSummary: Decodable {
    let requests: Int
    let inputTokens: Int
    let outputTokens: Int
    let totalTokens: Int
    let topModel: String?
    let peakDay: String?
    let peakDayTokens: Int
}

struct ProviderDashboardExtras: Decodable {
    let warning: String?
    let codeReviewRemainingPercent: Double?
    let purchaseURL: String?
}

struct ProviderUsageSettingsSnapshot: Decodable {
    let refreshIntervalSeconds: Int
    let codex: ProviderUsageProviderSettingsSnapshot
    let claude: ProviderUsageProviderSettingsSnapshot
}

struct ProviderUsageProviderSettingsSnapshot: Decodable {
    let source: String
    let webExtrasEnabled: Bool
    let keychainPromptPolicy: String
    let manualCookieConfigured: Bool
}

private struct ProviderUsageOverviewRequest: Encodable {
    let forceRefresh: Bool
    let localUsageDays: Int
}

private struct ProviderUsageSettingsSaveRequest: Encodable {
    let refreshIntervalSeconds: Int
    let codex: ProviderUsageProviderSettingsSave
    let claude: ProviderUsageProviderSettingsSave
}

private struct ProviderUsageProviderSettingsSave: Encodable {
    let source: String
    let webExtrasEnabled: Bool
    let keychainPromptPolicy: String
    let manualCookieValue: String?
    let clearManualCookie: Bool
}

enum ProviderUsageIndicatorState: Equatable {
    case hidden
    case ok
    case warning
    case error
}

@Observable @MainActor
final class ProviderUsageStore {
    static let shared = ProviderUsageStore()

    var overview: ProviderUsageOverview?
    var isLoading = false
    var errorMessage: String?

    @ObservationIgnored
    private let commandBus: (any CommandCalling)?
    @ObservationIgnored
    private let bridgeEventHub: BridgeEventHub
    @ObservationIgnored
    private var bridgeObserverID: UUID?
    @ObservationIgnored
    private var refreshTask: Task<Void, Never>?
    @ObservationIgnored
    private var refreshLoopTask: Task<Void, Never>?
    @ObservationIgnored
    private var settingsTask: Task<Void, Never>?
    @ObservationIgnored
    private var settingsSnapshot: ProviderUsageSettingsSnapshot?
    @ObservationIgnored
    private var lastSettingsLoad = Date.distantPast

    init(
        commandBus: (any CommandCalling)? = CommandBus.shared,
        bridgeEventHub: BridgeEventHub = .shared
    ) {
        self.commandBus = commandBus
        self.bridgeEventHub = bridgeEventHub

        bridgeObserverID = bridgeEventHub.addObserver { [weak self] event in
            switch event.name {
            case "provider_usage_updated":
                Task { @MainActor [weak self] in
                    await self?.refresh(force: false)
                }
            case "cost_updated":
                Task { @MainActor [weak self] in
                    guard let self, self.shouldRefreshForEvent else { return }
                    await self.refresh(force: false)
                }
            default:
                break
            }
        }
    }

    deinit {
        if let bridgeObserverID {
            bridgeEventHub.removeObserver(bridgeObserverID)
        }
    }

    var providerSnapshots: [ProviderUsageProviderSnapshot] {
        overview?.providers ?? []
    }

    var indicatorState: ProviderUsageIndicatorState {
        let providers = providerSnapshots
        guard !providers.isEmpty else { return .hidden }
        if providers.contains(where: { $0.status == "ok" }) {
            return providers.contains(where: { $0.status == "warning" || $0.status == "error" }) ? .warning : .ok
        }
        if providers.contains(where: { $0.status == "warning" }) {
            return .warning
        }
        if providers.contains(where: { $0.status == "error" }) {
            return .error
        }
        return .hidden
    }

    var shouldRefreshForEvent: Bool {
        guard let overview else { return true }
        guard let generated = providerUsageTimestampParser.date(from: overview.generatedAt)
            ?? providerUsageTimestampParserNoFraction.date(from: overview.generatedAt) else {
            return true
        }
        return Date().timeIntervalSince(generated) >= 30
    }

    func activate() async {
        await loadSettingsIfNeeded(force: false)
        await refresh(force: false)
        startRefreshLoopIfNeeded()
    }

    func refresh(force: Bool) async {
        guard let commandBus else {
            errorMessage = "Provider usage is unavailable because the command bus is not configured."
            notifyChanged()
            return
        }

        if !force, overview != nil, !shouldRefreshForEvent {
            return
        }

        isLoading = true
        errorMessage = nil
        notifyChanged()

        let request = ProviderUsageOverviewRequest(forceRefresh: force, localUsageDays: 30)
        do {
            let overview: ProviderUsageOverview = try await commandBus.call(
                method: "usage.providers.overview",
                params: request
            )
            self.overview = overview
            self.errorMessage = nil
        } catch {
            self.errorMessage = error.localizedDescription
        }
        isLoading = false
        notifyChanged()
    }

    func loadSettingsIfNeeded(force: Bool) async {
        guard force || Date().timeIntervalSince(lastSettingsLoad) > 30 else { return }
        guard let commandBus else { return }
        settingsTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot: ProviderUsageSettingsSnapshot = try await commandBus.call(
                    method: "usage.providers.settings.get",
                    params: nil
                )
                self.settingsSnapshot = snapshot
                self.lastSettingsLoad = Date()
                self.startRefreshLoopIfNeeded()
                self.notifyChanged()
            } catch {
                self.lastSettingsLoad = Date()
            }
        }
        settingsTask = task
        await task.value
    }

    private func startRefreshLoopIfNeeded() {
        guard refreshLoopTask == nil else { return }
        refreshLoopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let interval = max(30, self.settingsSnapshot?.refreshIntervalSeconds ?? self.overview?.refreshIntervalSeconds ?? 120)
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                await self.refresh(force: false)
            }
        }
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: .providerUsageStoreDidChange, object: self)
    }
}

@Observable @MainActor
final class ProviderUsageSettingsViewModel {
    private let commandBus: (any CommandCalling)?

    var refreshIntervalSeconds = 120

    var codexSource = "auto"
    var codexWebExtrasEnabled = false
    var codexKeychainPromptPolicy = "user_action"
    var codexManualCookieConfigured = false
    var codexManualCookieInput = ""

    var claudeSource = "auto"
    var claudeWebExtrasEnabled = false
    var claudeKeychainPromptPolicy = "user_action"
    var claudeManualCookieConfigured = false
    var claudeManualCookieInput = ""

    var statusMessage: String?
    var isLoading = false

    init(commandBus: (any CommandCalling)? = CommandBus.shared) {
        self.commandBus = commandBus
    }

    func load() {
        guard let commandBus else {
            statusMessage = "Provider usage settings are unavailable because the command bus is not configured."
            return
        }

        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                let snapshot: ProviderUsageSettingsSnapshot = try await commandBus.call(
                    method: "usage.providers.settings.get",
                    params: nil
                )
                apply(snapshot)
                statusMessage = nil
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    func saveGeneralSettings() {
        save(codexManualCookieValue: nil, clearCodexManualCookie: false, claudeManualCookieValue: nil, clearClaudeManualCookie: false)
    }

    func storeCodexManualCookie() {
        save(
            codexManualCookieValue: codexManualCookieInput.trimmingCharacters(in: .whitespacesAndNewlines),
            clearCodexManualCookie: false,
            claudeManualCookieValue: nil,
            clearClaudeManualCookie: false
        )
    }

    func clearCodexManualCookie() {
        codexManualCookieInput = ""
        save(codexManualCookieValue: nil, clearCodexManualCookie: true, claudeManualCookieValue: nil, clearClaudeManualCookie: false)
    }

    func storeClaudeManualCookie() {
        save(
            codexManualCookieValue: nil,
            clearCodexManualCookie: false,
            claudeManualCookieValue: claudeManualCookieInput.trimmingCharacters(in: .whitespacesAndNewlines),
            clearClaudeManualCookie: false
        )
    }

    func clearClaudeManualCookie() {
        claudeManualCookieInput = ""
        save(codexManualCookieValue: nil, clearCodexManualCookie: false, claudeManualCookieValue: nil, clearClaudeManualCookie: true)
    }

    private func save(
        codexManualCookieValue: String?,
        clearCodexManualCookie: Bool,
        claudeManualCookieValue: String?,
        clearClaudeManualCookie: Bool
    ) {
        guard let commandBus else {
            statusMessage = "Provider usage settings are unavailable because the command bus is not configured."
            return
        }

        isLoading = true
        let request = ProviderUsageSettingsSaveRequest(
            refreshIntervalSeconds: refreshIntervalSeconds,
            codex: ProviderUsageProviderSettingsSave(
                source: codexSource,
                webExtrasEnabled: codexWebExtrasEnabled,
                keychainPromptPolicy: codexKeychainPromptPolicy,
                manualCookieValue: codexManualCookieValue,
                clearManualCookie: clearCodexManualCookie
            ),
            claude: ProviderUsageProviderSettingsSave(
                source: claudeSource,
                webExtrasEnabled: claudeWebExtrasEnabled,
                keychainPromptPolicy: claudeKeychainPromptPolicy,
                manualCookieValue: claudeManualCookieValue,
                clearManualCookie: clearClaudeManualCookie
            )
        )

        Task {
            defer { isLoading = false }
            do {
                let snapshot: ProviderUsageSettingsSnapshot = try await commandBus.call(
                    method: "usage.providers.settings.set",
                    params: request
                )
                apply(snapshot)
                statusMessage = "Saved"
                await ProviderUsageStore.shared.loadSettingsIfNeeded(force: true)
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    private func apply(_ snapshot: ProviderUsageSettingsSnapshot) {
        refreshIntervalSeconds = snapshot.refreshIntervalSeconds

        codexSource = snapshot.codex.source
        codexWebExtrasEnabled = snapshot.codex.webExtrasEnabled
        codexKeychainPromptPolicy = snapshot.codex.keychainPromptPolicy
        codexManualCookieConfigured = snapshot.codex.manualCookieConfigured

        claudeSource = snapshot.claude.source
        claudeWebExtrasEnabled = snapshot.claude.webExtrasEnabled
        claudeKeychainPromptPolicy = snapshot.claude.keychainPromptPolicy
        claudeManualCookieConfigured = snapshot.claude.manualCookieConfigured
    }
}

struct ProviderUsagePopoverView: View {
    @State private var store: ProviderUsageStore
    var onOpenDashboard: (() -> Void)?

    @MainActor
    init(
        store: ProviderUsageStore? = nil,
        onOpenDashboard: (() -> Void)? = nil
    ) {
        _store = State(initialValue: store ?? ProviderUsageStore.shared)
        self.onOpenDashboard = onOpenDashboard
    }

    var body: some View {
        VStack(spacing: 0) {
            ProviderUsagePopoverHeader(
                overview: store.overview,
                snapshots: store.providerSnapshots,
                isLoading: store.isLoading,
                onRefresh: { Task { await store.refresh(force: true) } }
            )
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.top, DesignTokens.Spacing.md)
            .padding(.bottom, DesignTokens.Spacing.sm)

            Divider()

            Group {
                if let errorMessage = store.errorMessage, store.providerSnapshots.isEmpty {
                    ContentUnavailableView(
                        "Provider Usage Unavailable",
                        systemImage: "chart.bar.xaxis",
                        description: Text(errorMessage)
                    )
                    .padding(DesignTokens.Spacing.lg)
                } else {
                    ScrollView {
                        VStack(spacing: DesignTokens.Spacing.md) {
                            if let errorMessage = store.errorMessage {
                                ProviderUsageInlineNotice(title: "Refresh issue", message: errorMessage)
                            }

                            ForEach(store.providerSnapshots) { snapshot in
                                ProviderUsageCard(snapshot: snapshot, compact: true)
                            }
                        }
                        .padding(DesignTokens.Spacing.md)
                    }
                }
            }
            .frame(minHeight: 320)

            Divider()

            HStack {
                Button(action: { onOpenDashboard?() }) {
                    Text("Open Dashboard")
                }
                .buttonStyle(.borderless)
                Spacer()
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.sm + DesignTokens.Spacing.md)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await store.activate()
        }
    }
}

struct ProviderUsageDashboardView: View {
    @State private var store: ProviderUsageStore

    @MainActor
    init(store: ProviderUsageStore? = nil) {
        _store = State(initialValue: store ?? ProviderUsageStore.shared)
    }

    var body: some View {
        Group {
            if let errorMessage = store.errorMessage, store.providerSnapshots.isEmpty {
                EmptyStateView(
                    icon: "chart.bar.xaxis",
                    title: "Provider Usage Unavailable",
                    message: errorMessage
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let errorMessage = store.errorMessage {
                            ProviderUsageInlineNotice(title: "Refresh issue", message: errorMessage)
                        }
                        ForEach(store.providerSnapshots) { snapshot in
                            ProviderUsageCard(snapshot: snapshot, compact: false)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .task {
            await store.activate()
        }
    }
}

struct ProviderUsageSettingsTab: View {
    @Bindable var viewModel: ProviderUsageSettingsViewModel

    var body: some View {
        Form {
            Stepper(
                "Refresh cadence: \(viewModel.refreshIntervalSeconds)s",
                value: $viewModel.refreshIntervalSeconds,
                in: 30...900,
                step: 30
            )

            providerSection(
                title: "Codex",
                source: $viewModel.codexSource,
                webExtrasEnabled: $viewModel.codexWebExtrasEnabled,
                keychainPromptPolicy: $viewModel.codexKeychainPromptPolicy,
                manualCookieConfigured: viewModel.codexManualCookieConfigured,
                manualCookieInput: $viewModel.codexManualCookieInput,
                onStoreCookie: { viewModel.storeCodexManualCookie() },
                onClearCookie: { viewModel.clearCodexManualCookie() }
            )

            providerSection(
                title: "Claude",
                source: $viewModel.claudeSource,
                webExtrasEnabled: $viewModel.claudeWebExtrasEnabled,
                keychainPromptPolicy: $viewModel.claudeKeychainPromptPolicy,
                manualCookieConfigured: viewModel.claudeManualCookieConfigured,
                manualCookieInput: $viewModel.claudeManualCookieInput,
                onStoreCookie: { viewModel.storeClaudeManualCookie() },
                onClearCookie: { viewModel.clearClaudeManualCookie() }
            )

            HStack {
                Button("Save Settings") {
                    viewModel.saveGeneralSettings()
                }
                .disabled(viewModel.isLoading)

                if viewModel.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()

                if let statusMessage = viewModel.statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func providerSection(
        title: String,
        source: Binding<String>,
        webExtrasEnabled: Binding<Bool>,
        keychainPromptPolicy: Binding<String>,
        manualCookieConfigured: Bool,
        manualCookieInput: Binding<String>,
        onStoreCookie: @escaping () -> Void,
        onClearCookie: @escaping () -> Void
    ) -> some View {
        Section(title) {
            Picker("Source", selection: source) {
                Text("Auto").tag("auto")
                Text("CLI").tag("cli")
                Text("OAuth").tag("oauth")
                Text("Local only").tag("local")
            }

            Picker("Keychain prompts", selection: keychainPromptPolicy) {
                Text("Only on user action").tag("user_action")
                Text("Never").tag("never")
                Text("Always").tag("always")
            }

            Toggle("Enable web/dashboard extras", isOn: webExtrasEnabled)

            SecureField("Manual cookie/header", text: manualCookieInput)
            HStack {
                Text(manualCookieConfigured ? "Manual cookie configured" : "No manual cookie stored")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Store") { onStoreCookie() }
                    .disabled(viewModel.isLoading)
                Button("Clear") { onClearCookie() }
                    .disabled(viewModel.isLoading)
            }
        }
    }
}

private struct ProviderUsageCard: View {
    let snapshot: ProviderUsageProviderSnapshot
    let compact: Bool

    var body: some View {
        let brand = ProviderBrand(provider: snapshot.provider)

        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                ProviderLogoMark(brand: brand)

                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    Text(snapshot.displayName)
                        .font(.headline)
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        ProviderUsageTag(text: snapshot.source.uppercased(), accent: brand.accent)
                        ProviderStatusPill(status: snapshot.status)
                    }
                }

                Spacer(minLength: DesignTokens.Spacing.sm)

                VStack(alignment: .trailing, spacing: DesignTokens.Spacing.xs) {
                    if let planLabel = snapshot.planLabel {
                        Text(planLabel)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text("Local 30-day usage")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if let accountEmail = snapshot.accountEmail {
                ProviderDetailRow(label: "Account", value: accountEmail)
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: DesignTokens.Spacing.sm),
                    GridItem(.flexible(), spacing: DesignTokens.Spacing.sm),
                    GridItem(.flexible(), spacing: DesignTokens.Spacing.sm)
                ],
                spacing: DesignTokens.Spacing.sm
            ) {
                ProviderUsageMetricTile(title: "Requests", value: providerFormatTokens(snapshot.localUsage.requests), accent: brand.accent)
                ProviderUsageMetricTile(title: "Input", value: providerFormatCompactTokens(snapshot.localUsage.inputTokens), accent: brand.accent)
                ProviderUsageMetricTile(title: "Output", value: providerFormatCompactTokens(snapshot.localUsage.outputTokens), accent: brand.accent)
            }

            if let sessionWindow = snapshot.sessionWindow {
                ProviderWindowRow(window: sessionWindow, accent: brand.accent)
            }

            if let weeklyWindow = snapshot.weeklyWindow {
                ProviderWindowRow(window: weeklyWindow, accent: brand.accent)
            }

            if !compact {
                ForEach(snapshot.modelWindows) { window in
                    ProviderWindowRow(window: window, accent: brand.accent)
                }
            } else if let modelWindow = snapshot.modelWindows.first {
                ProviderWindowRow(window: modelWindow, accent: brand.accent)
            }

            if let credit = snapshot.credit {
                ProviderDetailRow(
                    label: credit.label,
                    value: credit.isUnlimited
                        ? "Unlimited"
                        : (credit.balanceDisplay ?? "Available")
                )
            }

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                if let topModel = snapshot.localUsage.topModel {
                    ProviderDetailRow(label: "Top model", value: topModel)
                }
                if let peakDay = snapshot.localUsage.peakDay {
                    ProviderDetailRow(
                        label: "Peak day",
                        value: "\(providerFormatDateLabel(peakDay)) • \(providerFormatCompactTokens(snapshot.localUsage.peakDayTokens)) tok"
                    )
                }
                ProviderDetailRow(
                    label: "Total tokens",
                    value: providerFormatCompactTokens(snapshot.localUsage.totalTokens)
                )
            }

            if let statusMessage = snapshot.statusMessage {
                ProviderUsageCallout(
                    title: statusTitle,
                    message: statusMessage,
                    accent: snapshot.status == "error" ? .red : .orange
                )
            }
            if let repairHint = snapshot.repairHint {
                ProviderUsageCallout(title: "Suggested fix", message: repairHint, accent: brand.accent)
            }
            if let warning = snapshot.dashboardExtras?.warning {
                ProviderUsageCallout(title: "Provider note", message: warning, accent: brand.accent)
            }
        }
        .padding(DesignTokens.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.secondary.opacity(0.10))
                .overlay {
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
                }
        )
    }

    private var statusTitle: String {
        if snapshot.status == "error" {
            return "Connection issue"
        }
        if snapshot.statusMessage?.localizedCaseInsensitiveContains("cached live") == true {
            return "Using cached live data"
        }
        if snapshot.source == "local" {
            return "Using fallback data"
        }
        return "Live quota unavailable"
    }
}

private struct ProviderUsageCompactCard: View {
    let snapshot: ProviderUsageProviderSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                ProviderUsageCompactMark(title: snapshot.displayName)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        Text(snapshot.displayName)
                            .font(.headline)
                        ProviderUsageCompactStatus(status: snapshot.status)
                    }

                    Text(metaLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: DesignTokens.Spacing.sm)

                if let planLabel = snapshot.planLabel {
                    Text(planLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                }
            }

            HStack(spacing: DesignTokens.Spacing.md) {
                ProviderUsageCompactMetric(
                    title: "Requests",
                    value: providerFormatTokens(snapshot.localUsage.requests)
                )
                ProviderUsageCompactMetric(
                    title: "Tokens",
                    value: providerFormatCompactTokens(snapshot.localUsage.totalTokens)
                )
                if let creditLine {
                    ProviderUsageCompactMetric(
                        title: creditTitle,
                        value: creditLine
                    )
                }
            }

            if let quotaSummary {
                Text(quotaSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let detailLine {
                Text(detailLine)
                    .font(.subheadline)
                    .foregroundStyle(detailTone)
                    .lineLimit(2)
            }
        }
        .padding(DesignTokens.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.10))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
        }
    }

    private var metaLine: String {
        var parts = [snapshot.source.uppercased()]
        if let accountEmail = snapshot.accountEmail, !accountEmail.isEmpty {
            parts.append(accountEmail)
        } else if let topModel = snapshot.localUsage.topModel, !topModel.isEmpty {
            parts.append(topModel)
        }
        return parts.joined(separator: " • ")
    }

    private var quotaSummary: String? {
        let window = snapshot.sessionWindow ?? snapshot.weeklyWindow ?? snapshot.modelWindows.first
        guard let window else { return nil }

        var parts = [window.label]
        if let percentUsed = window.percentUsed {
            parts.append("\(percentUsed.formatted(.number.precision(.fractionLength(0))))% used")
        } else if let percentRemaining = window.percentRemaining {
            parts.append("\(percentRemaining.formatted(.number.precision(.fractionLength(0))))% left")
        }
        if let resetAt = window.resetAt {
            parts.append("resets \(formatProviderReset(resetAt))")
        }
        return parts.joined(separator: " • ")
    }

    private var detailLine: String? {
        snapshot.statusMessage
            ?? snapshot.dashboardExtras?.warning
            ?? snapshot.repairHint
    }

    private var detailTone: Color {
        switch snapshot.status {
        case "error":
            return .red
        case "warning":
            return .orange
        default:
            return .secondary
        }
    }

    private var creditTitle: String {
        snapshot.credit?.label ?? "Credit"
    }

    private var creditLine: String? {
        guard let credit = snapshot.credit else { return nil }
        if credit.isUnlimited {
            return "Unlimited"
        }
        return credit.balanceDisplay ?? "Available"
    }
}

private struct ProviderWindowRow: View {
    let window: ProviderQuotaWindow
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack {
                Text(window.label)
                    .font(.subheadline)
                Spacer()
                if let percentUsed = window.percentUsed {
                    Text("\(percentUsed, specifier: "%.0f")% used")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if let normalizedProgress {
                ProgressView(value: normalizedProgress)
                    .progressViewStyle(.linear)
                    .tint(accent)
            } else {
                Text("Usage unavailable")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let resetAt = window.resetAt {
                Text("Resets \(formatProviderReset(resetAt))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var normalizedProgress: Double? {
        guard let percentUsed = window.percentUsed else { return nil }
        return min(max(percentUsed / 100.0, 0), 1)
    }
}

private struct ProviderUsageInlineNotice: View {
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .bold()
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(DesignTokens.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
        }
    }
}

private func formatProviderReset(_ raw: String) -> String {
    let date = providerUsageTimestampParser.date(from: raw)
        ?? providerUsageTimestampParserNoFraction.date(from: raw)
    guard let date else { return raw }
    let relative = providerUsageRelativeFormatter.localizedString(for: date, relativeTo: .now)
    return relative
}

private struct ProviderUsageTag: View {
    let text: String
    let accent: Color

    var body: some View {
        Text(text)
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.14)))
    }
}

private struct ProviderStatusPill: View {
    let status: String

    private var symbolName: String {
        switch status {
        case "ok": return "checkmark.circle.fill"
        case "warning": return "exclamationmark.triangle.fill"
        case "error": return "xmark.octagon.fill"
        default: return "circle.fill"
        }
    }

    private var color: Color {
        switch status {
        case "ok": return .secondary
        case "warning": return .orange
        case "error": return .red
        default: return .secondary
        }
    }

    var body: some View {
        Label(status.capitalized, systemImage: symbolName)
            .font(.caption.bold())
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.14)))
    }
}

private struct ProviderDetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.subheadline)
        }
    }
}

private struct ProviderUsagePopoverHeader: View {
    let overview: ProviderUsageOverview?
    let snapshots: [ProviderUsageProviderSnapshot]
    let isLoading: Bool
    let onRefresh: () -> Void

    private var totalRequests: Int {
        snapshots.reduce(0) { $0 + $1.localUsage.requests }
    }

    private var totalTokens: Int {
        snapshots.reduce(0) { $0 + $1.localUsage.totalTokens }
    }

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Text("Provider Usage")
                    .font(.headline)
                    .bold()
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: DesignTokens.Spacing.sm)

            Button(action: onRefresh) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(minWidth: 16)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .accessibilityLabel("Refresh usage provider data")
        }
    }

    private var subtitle: String {
        var parts = ["\(providerFormatTokens(snapshots.count)) providers"]
        if totalRequests > 0 {
            parts.append("\(providerFormatTokens(totalRequests)) requests")
        }
        if totalTokens > 0 {
            parts.append("\(providerFormatCompactTokens(totalTokens)) tokens")
        }
        if let generatedAt = overview?.generatedAt {
            parts.append("updated \(formatProviderReset(generatedAt))")
        }
        return parts.joined(separator: " • ")
    }
}

private struct ProviderUsageCompactMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(value)
                .font(.subheadline)
                .bold()
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProviderUsageMetricTile: View {
    let title: String
    let value: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(value)
                .font(.headline)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.secondary.opacity(0.10))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
        }
    }
}

private struct ProviderUsageCompactMark: View {
    let title: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.16))
                .frame(width: 30, height: 30)
            Text(String(title.prefix(1)).uppercased())
                .font(.subheadline)
                .bold()
                .foregroundStyle(.secondary)
        }
        .accessibilityHidden(true)
    }
}

private struct ProviderUsageCompactStatus: View {
    let status: String

    private var symbolName: String {
        switch status {
        case "ok": return "checkmark.circle.fill"
        case "warning": return "exclamationmark.triangle.fill"
        case "error": return "xmark.octagon.fill"
        default: return "circle.fill"
        }
    }

    private var tone: Color {
        switch status {
        case "warning":
            return .orange
        case "error":
            return .red
        default:
            return .secondary
        }
    }

    var body: some View {
        Image(systemName: symbolName)
            .font(.caption)
            .foregroundStyle(tone)
            .accessibilityLabel(status.capitalized)
    }
}

private struct ProviderUsageCallout: View {
    let title: String
    let message: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Label(title, systemImage: "info.circle.fill")
                .font(.subheadline)
                .bold()
                .foregroundStyle(.secondary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.secondary.opacity(0.10))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
        }
    }
}

private struct ProviderLogoMark: View {
    let brand: ProviderBrand

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.secondary.opacity(0.10))
                .frame(width: 42, height: 42)
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
                }

            if let assetName = brand.logoAssetName {
                Image(assetName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
            } else {
                Text(brand.monogram)
                    .font(.subheadline)
                    .bold()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ProviderBrand {
    let provider: String

    var logoAssetName: String? {
        switch provider {
        case "codex": return "openai-logo"
        case "claude": return "anthropic-logo"
        default: return nil
        }
    }

    var accent: Color {
        switch provider {
        case "codex":
            return Color(red: 0.30, green: 0.75, blue: 0.45)
        case "claude":
            return Color(red: 0.85, green: 0.55, blue: 0.35)
        default:
            return .accentColor
        }
    }

    var monogram: String {
        switch provider {
        case "codex": return "C"
        case "claude": return "A"
        default: return String(provider.prefix(1)).uppercased()
        }
    }
}
