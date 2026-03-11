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

private let providerUsageDayParser: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return formatter
}()

private let providerUsageTimestampParser: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

private let providerUsageTimestampParserNoFraction: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}()

private let providerUsageRelativeFormatter = RelativeDateTimeFormatter()

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
            HStack {
                Text("Usage")
                    .font(.headline)
                Spacer()
                if store.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    Task { await store.refresh(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Refresh usage provider data")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            Group {
                if let errorMessage = store.errorMessage, store.providerSnapshots.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "chart.bar.xaxis")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary.opacity(0.5))
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(store.providerSnapshots) { snapshot in
                                ProviderUsageCard(snapshot: snapshot, compact: true)
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .frame(minHeight: 260)

            Divider()

            Button(action: { onOpenDashboard?() }) {
                Text("Open Usage Dashboard")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
        }
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
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(snapshot.displayName)
                            .font(.headline)
                        HStack(spacing: 8) {
                            ProviderUsageTag(text: snapshot.source.uppercased())
                            ProviderStatusPill(status: snapshot.status)
                        }
                    }
                    Spacer()
                    if let planLabel = snapshot.planLabel {
                        Text(planLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let accountEmail = snapshot.accountEmail {
                    ProviderDetailRow(label: "Account", value: accountEmail)
                }

                if let sessionWindow = snapshot.sessionWindow {
                    ProviderWindowRow(window: sessionWindow)
                }

                if let weeklyWindow = snapshot.weeklyWindow {
                    ProviderWindowRow(window: weeklyWindow)
                }

                if !compact {
                    ForEach(snapshot.modelWindows) { window in
                        ProviderWindowRow(window: window)
                    }
                } else if let modelWindow = snapshot.modelWindows.first {
                    ProviderWindowRow(window: modelWindow)
                }

                if let credit = snapshot.credit {
                    ProviderDetailRow(
                        label: credit.label,
                        value: credit.isUnlimited
                            ? "Unlimited"
                            : (credit.balanceDisplay ?? "Available")
                    )
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Local 30-day usage")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        ProviderDetailRow(label: "Requests", value: providerFormatTokens(snapshot.localUsage.requests))
                        ProviderDetailRow(label: "Input", value: providerFormatCompactTokens(snapshot.localUsage.inputTokens))
                        ProviderDetailRow(label: "Output", value: providerFormatCompactTokens(snapshot.localUsage.outputTokens))
                    }
                    if let topModel = snapshot.localUsage.topModel {
                        ProviderDetailRow(label: "Top model", value: topModel)
                    }
                    if let peakDay = snapshot.localUsage.peakDay {
                        ProviderDetailRow(
                            label: "Peak day",
                            value: "\(providerFormatDateLabel(peakDay)) • \(providerFormatCompactTokens(snapshot.localUsage.peakDayTokens)) tok"
                        )
                    }
                }

                if let statusMessage = snapshot.statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(snapshot.status == "error" ? .red : .secondary)
                }
                if let repairHint = snapshot.repairHint {
                    Text(repairHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct ProviderWindowRow: View {
    let window: ProviderQuotaWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(window.label)
                    .font(.subheadline)
                Spacer()
                if let percentUsed = window.percentUsed {
                    Text("\(percentUsed, specifier: "%.0f")% used")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: normalizedProgress)
                .progressViewStyle(.linear)
            if let resetAt = window.resetAt {
                    Text("Resets \(formatProviderReset(resetAt))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
            }
        }
    }

    private var normalizedProgress: Double {
        guard let percentUsed = window.percentUsed else { return 0 }
        return min(max(percentUsed / 100.0, 0), 1)
    }
}

private struct ProviderUsageInlineNotice: View {
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.08)))
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

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.secondary.opacity(0.18)))
    }
}

private struct ProviderStatusPill: View {
    let status: String

    private var color: Color {
        switch status {
        case "ok": return .green
        case "warning": return .orange
        case "error": return .red
        default: return .secondary
        }
    }

    var body: some View {
        Text(status.capitalized)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

private struct ProviderDetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption)
        }
    }
}
