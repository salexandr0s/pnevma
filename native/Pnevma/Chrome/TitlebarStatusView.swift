@preconcurrency import ObjectiveC
import Cocoa
import Observation

struct TitlebarStatusLayoutState: Equatable {
    let showsPullRequest: Bool
    let showsAgents: Bool

    static func resolved(for width: CGFloat, hasPullRequest: Bool) -> Self {
        if width >= 360 {
            return Self(showsPullRequest: hasPullRequest, showsAgents: true)
        }
        if width >= 280 {
            return Self(showsPullRequest: false, showsAgents: true)
        }
        return Self(showsPullRequest: false, showsAgents: false)
    }

    var showsLeadingSeparator: Bool {
        !showsPullRequest
    }

    var showsTrailingSeparator: Bool {
        showsPullRequest || showsAgents
    }
}

final class TitlebarStatusView: NSView {
    private let contentStack = NSStackView()
    private let branchButton = NSButton(frame: .zero)
    private let agentsLabel = NSTextField(labelWithString: "")
    let sessionsButton = NSButton(frame: .zero)
    private let sessionsContainer = NSView(frame: .zero)
    private let prPill = NSButton(frame: .zero)
    private let attentionDot = NSView(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
    private let separator1 = NSView(frame: .zero)
    private let separator2 = NSView(frame: .zero)
    nonisolated(unsafe) var themeObserver: NSObjectProtocol?
    private var sessionObservationGeneration: UInt64 = 0
    private var appliedLayoutState = TitlebarStatusLayoutState(showsPullRequest: false, showsAgents: true)

    var onSessionsClicked: (() -> Void)?
    var onBranchClicked: (() -> Void)?
    var onPRClicked: (() -> Void)?

    private var currentPRNumber: UInt64?
    private var currentPRURL: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        MainActor.assumeIsolated { setupUI() }
    }

    deinit {
        if let themeObserver {
            NotificationCenter.default.removeObserver(themeObserver)
        }
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: DesignTokens.Layout.titlebarGroupHeight)
    }

    var branchPopoverAnchorRect: NSRect {
        layoutSubtreeIfNeeded()
        let branchRect = convert(branchButton.bounds, from: branchButton)
        let anchorWidth = min(max(branchRect.width * 0.45, 36), 64)
        let anchorX = floor(branchRect.midX - (anchorWidth / 2))
        return NSRect(
            x: anchorX,
            y: -DesignTokens.Spacing.xs,
            width: anchorWidth,
            height: DesignTokens.Spacing.xs
        )
    }

    var sessionsPopoverAnchorRect: NSRect {
        layoutSubtreeIfNeeded()
        let sessionsRect = convert(sessionsContainer.bounds, from: sessionsContainer)
        let anchorWidth = min(max(sessionsRect.width * 0.55, 28), 44)
        let anchorX = floor(sessionsRect.midX - (anchorWidth / 2))
        return NSRect(
            x: anchorX,
            y: -DesignTokens.Spacing.xs,
            width: anchorWidth,
            height: DesignTokens.Spacing.xs
        )
    }

    override func layout() {
        super.layout()
        applyLayoutState(
            TitlebarStatusLayoutState.resolved(
                for: bounds.width,
                hasPullRequest: currentPRNumber != nil
            )
        )
    }

    private func setupUI() {
        wantsLayer = true
        layer?.cornerRadius = DesignTokens.Layout.titlebarGroupCornerRadius
        layer?.borderWidth = 0.5
        layer?.masksToBounds = true
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = 8
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)

        configureBranchButton()
        configureAgentsLabel()
        configureSessionsButton()
        configurePullRequestPill()
        configureAttentionDot()
        configureSeparator(separator1)
        configureSeparator(separator2)

        sessionsContainer.translatesAutoresizingMaskIntoConstraints = false
        sessionsContainer.addSubview(sessionsButton)
        sessionsContainer.addSubview(attentionDot)
        NSLayoutConstraint.activate([
            sessionsButton.leadingAnchor.constraint(equalTo: sessionsContainer.leadingAnchor),
            sessionsButton.trailingAnchor.constraint(equalTo: sessionsContainer.trailingAnchor),
            sessionsButton.topAnchor.constraint(equalTo: sessionsContainer.topAnchor),
            sessionsButton.bottomAnchor.constraint(equalTo: sessionsContainer.bottomAnchor),
            attentionDot.widthAnchor.constraint(equalToConstant: DesignTokens.Layout.statusDotSize),
            attentionDot.heightAnchor.constraint(equalToConstant: DesignTokens.Layout.statusDotSize),
            attentionDot.trailingAnchor.constraint(equalTo: sessionsButton.trailingAnchor, constant: 2),
            attentionDot.topAnchor.constraint(equalTo: sessionsButton.topAnchor, constant: -2),
        ])

        [
            branchButton,
            prPill,
            separator1,
            agentsLabel,
            separator2,
            sessionsContainer,
        ].forEach { contentStack.addArrangedSubview($0) }

        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            heightAnchor.constraint(equalToConstant: DesignTokens.Layout.titlebarGroupHeight),
        ])

        updateBranch(nil)
        updateAgents(0)
        updateSessions(0)
        updatePR(number: nil, url: nil)

        themeObserver = NotificationCenter.default.addObserver(
            forName: GhosttyThemeProvider.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyThemeColors() }
        }
        applyThemeColors()
        applyLayoutState(appliedLayoutState)
    }

    private func configureBranchButton() {
        branchButton.bezelStyle = .inline
        branchButton.isBordered = false
        branchButton.font = .systemFont(ofSize: 11, weight: .medium)
        branchButton.title = "No branch"
        branchButton.image = NSImage(
            systemSymbolName: "arrow.triangle.branch",
            accessibilityDescription: "Git branch"
        )?.withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        branchButton.imageScaling = .scaleProportionallyDown
        branchButton.imagePosition = .imageLeading
        branchButton.imageHugsTitle = true
        branchButton.cell?.lineBreakMode = .byTruncatingTail
        branchButton.target = self
        branchButton.action = #selector(branchClicked)
        branchButton.setAccessibilityLabel("Git branch")
        branchButton.toolTip = "Switch branch"
        branchButton.translatesAutoresizingMaskIntoConstraints = false
        branchButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func configureAgentsLabel() {
        agentsLabel.font = .systemFont(ofSize: 11, weight: .medium)
        agentsLabel.isEditable = false
        agentsLabel.isBordered = false
        agentsLabel.drawsBackground = false
        agentsLabel.cell?.lineBreakMode = .byTruncatingTail
        agentsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        agentsLabel.translatesAutoresizingMaskIntoConstraints = false
        agentsLabel.setAccessibilityLabel("Active agents")
    }

    private func configureSessionsButton() {
        sessionsButton.bezelStyle = .inline
        sessionsButton.isBordered = false
        sessionsButton.font = .systemFont(ofSize: 11, weight: .medium)
        sessionsButton.title = "0 sessions"
        sessionsButton.target = self
        sessionsButton.action = #selector(sessionsClicked)
        sessionsButton.setAccessibilityLabel("Sessions")
        sessionsButton.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configurePullRequestPill() {
        prPill.bezelStyle = .inline
        prPill.isBordered = false
        prPill.font = .systemFont(ofSize: 10, weight: .semibold)
        prPill.title = ""
        prPill.target = self
        prPill.action = #selector(prClicked)
        prPill.wantsLayer = true
        prPill.layer?.cornerRadius = 7
        prPill.setAccessibilityLabel("Pull request")
        prPill.translatesAutoresizingMaskIntoConstraints = false
        prPill.isHidden = true
    }

    private func configureAttentionDot() {
        attentionDot.wantsLayer = true
        attentionDot.layer?.cornerRadius = DesignTokens.Layout.statusDotSize / 2
        attentionDot.translatesAutoresizingMaskIntoConstraints = false
        attentionDot.isHidden = true
    }

    private func configureSeparator(_ separator: NSView) {
        separator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            separator.widthAnchor.constraint(equalToConstant: 1),
            separator.heightAnchor.constraint(equalToConstant: 12),
        ])
    }

    private func applyThemeColors() {
        let theme = GhosttyThemeProvider.shared
        let tintAmount = Double(theme.backgroundOpacity) * 0.18
        let background = ChromeSurfaceStyle.toolbar.resolvedColor(
            themeColor: theme.backgroundColor,
            tintAmount: tintAmount
        )
        layer?.backgroundColor = background.cgColor
        layer?.borderColor = theme.foregroundColor.withAlphaComponent(0.09).cgColor

        let secondaryColor = theme.foregroundColor.withAlphaComponent(DesignTokens.TextOpacity.secondary)
        let disabledColor = theme.foregroundColor.withAlphaComponent(DesignTokens.TextOpacity.tertiary)
        applyButtonTitle(branchButton, color: branchButton.isEnabled ? secondaryColor : disabledColor)
        applyButtonTitle(sessionsButton, color: sessionsButton.isEnabled ? secondaryColor : disabledColor)
        agentsLabel.textColor = secondaryColor
        separator1.wantsLayer = true
        separator1.layer?.backgroundColor = theme.foregroundColor.withAlphaComponent(0.10).cgColor
        separator2.wantsLayer = true
        separator2.layer?.backgroundColor = theme.foregroundColor.withAlphaComponent(0.10).cgColor
        prPill.contentTintColor = .controlAccentColor
        prPill.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        attentionDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
    }

    private func applyButtonTitle(_ button: NSButton, color: NSColor) {
        button.contentTintColor = color
        button.attributedTitle = NSAttributedString(
            string: button.title,
            attributes: [
                .font: button.font ?? .systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: color,
            ]
        )
    }

    private func applyLayoutState(_ state: TitlebarStatusLayoutState) {
        guard state != appliedLayoutState else { return }
        appliedLayoutState = state
        prPill.isHidden = !state.showsPullRequest || currentPRNumber == nil
        agentsLabel.isHidden = !state.showsAgents
        separator1.isHidden = !state.showsLeadingSeparator
        separator2.isHidden = !state.showsTrailingSeparator
    }

    @objc private func sessionsClicked() {
        onSessionsClicked?()
    }

    @objc private func branchClicked() {
        onBranchClicked?()
    }

    @objc private func prClicked() {
        if let url = currentPRURL, let nsURL = URL(string: url) {
            NSWorkspace.shared.open(nsURL)
        }
        onPRClicked?()
    }

    func updateBranch(_ branch: String?) {
        branchButton.title = branch ?? "No branch"
        applyThemeColors()
    }

    func updateAgents(_ count: Int) {
        agentsLabel.stringValue = count > 0 ? "\(count) agent\(count == 1 ? "" : "s")" : "No agents"
    }

    func updateSessions(_ count: Int) {
        sessionsButton.title = "\(count) session\(count == 1 ? "" : "s")"
        applyThemeColors()
    }

    func updateBranchEnabled(_ enabled: Bool) {
        branchButton.isEnabled = enabled
        applyThemeColors()
    }

    func updateSessionsEnabled(_ enabled: Bool) {
        sessionsButton.isEnabled = enabled
        applyThemeColors()
    }

    func updatePR(number: UInt64?, url: String?) {
        currentPRNumber = number
        currentPRURL = url
        if let number {
            prPill.title = "#\(number)"
        } else {
            prPill.title = ""
        }
        applyLayoutState(
            TitlebarStatusLayoutState.resolved(
                for: bounds.width,
                hasPullRequest: number != nil
            )
        )
        applyThemeColors()
    }

    func updateAttentionDot(visible: Bool) {
        attentionDot.isHidden = !visible
    }

    func bindSessionStore(_ store: SessionStore) {
        sessionObservationGeneration &+= 1
        updateSessions(store.activeCount)
        observeSessionStore(store, generation: sessionObservationGeneration)
    }

    private func observeSessionStore(_ store: SessionStore, generation: UInt64) {
        withObservationTracking {
            _ = store.sessions
            _ = store.availability
        } onChange: { [weak self, weak store] in
            Task { @MainActor [weak self, weak store] in
                guard let self, let store else { return }
                guard self.sessionObservationGeneration == generation else { return }
                self.updateSessions(store.activeCount)
                self.observeSessionStore(store, generation: generation)
            }
        }
    }
}
