@preconcurrency import ObjectiveC
import Cocoa
import Observation

final class TitlebarStatusView: NSView {
    private let branchButton = NSButton(frame: .zero)
    private let agentsLabel = NSTextField(labelWithString: "")
    let sessionsButton = NSButton(frame: .zero)
    private let prPill = NSButton(frame: .zero)
    private let attentionDot = NSView(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
    private let separator1 = NSBox()
    private let separator2 = NSBox()
    nonisolated(unsafe) var themeObserver: NSObjectProtocol?
    private var sessionObservationGeneration: UInt64 = 0

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

    override var intrinsicContentSize: NSSize {
        NSSize(width: 420, height: 24)
    }

    private func setupUI() {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

        // Branch button (clickable)
        branchButton.bezelStyle = .inline
        branchButton.isBordered = false
        branchButton.font = font
        branchButton.title = "\u{E0A0} —"
        branchButton.target = self
        branchButton.action = #selector(branchClicked)
        branchButton.setAccessibilityLabel("Git branch")
        branchButton.toolTip = "Click to switch branch"
        branchButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(branchButton)

        // Agents label
        agentsLabel.font = font
        agentsLabel.isEditable = false
        agentsLabel.isBordered = false
        agentsLabel.drawsBackground = false
        agentsLabel.cell?.lineBreakMode = .byTruncatingTail
        agentsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        agentsLabel.translatesAutoresizingMaskIntoConstraints = false
        agentsLabel.setAccessibilityLabel("Active agents")
        addSubview(agentsLabel)

        // Sessions button
        sessionsButton.bezelStyle = .inline
        sessionsButton.isBordered = false
        sessionsButton.font = font
        sessionsButton.title = "0 sessions"
        sessionsButton.target = self
        sessionsButton.action = #selector(sessionsClicked)
        sessionsButton.setAccessibilityLabel("Sessions")
        sessionsButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sessionsButton)

        // PR pill (hidden by default)
        prPill.bezelStyle = .inline
        prPill.isBordered = false
        prPill.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        prPill.title = ""
        prPill.target = self
        prPill.action = #selector(prClicked)
        prPill.wantsLayer = true
        prPill.layer?.cornerRadius = 8
        prPill.setAccessibilityLabel("Pull request")
        prPill.translatesAutoresizingMaskIntoConstraints = false
        prPill.isHidden = true
        addSubview(prPill)

        // Attention dot (hidden by default)
        attentionDot.wantsLayer = true
        attentionDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        attentionDot.layer?.cornerRadius = 4
        attentionDot.translatesAutoresizingMaskIntoConstraints = false
        attentionDot.isHidden = true
        addSubview(attentionDot)

        for separator in [separator1, separator2] {
            separator.boxType = .separator
            separator.translatesAutoresizingMaskIntoConstraints = false
            addSubview(separator)
        }

        NSLayoutConstraint.activate([
            branchButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            branchButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            prPill.leadingAnchor.constraint(equalTo: branchButton.trailingAnchor, constant: 6),
            prPill.centerYAnchor.constraint(equalTo: centerYAnchor),

            separator1.leadingAnchor.constraint(equalTo: prPill.trailingAnchor, constant: 8),
            separator1.centerYAnchor.constraint(equalTo: centerYAnchor),
            separator1.widthAnchor.constraint(equalToConstant: 1),
            separator1.heightAnchor.constraint(equalToConstant: 12),

            agentsLabel.leadingAnchor.constraint(equalTo: separator1.trailingAnchor, constant: 8),
            agentsLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            separator2.leadingAnchor.constraint(equalTo: agentsLabel.trailingAnchor, constant: 8),
            separator2.centerYAnchor.constraint(equalTo: centerYAnchor),
            separator2.widthAnchor.constraint(equalToConstant: 1),
            separator2.heightAnchor.constraint(equalToConstant: 12),

            sessionsButton.leadingAnchor.constraint(equalTo: separator2.trailingAnchor, constant: 8),
            sessionsButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            sessionsButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            attentionDot.widthAnchor.constraint(equalToConstant: DesignTokens.Layout.statusDotSize),
            attentionDot.heightAnchor.constraint(equalToConstant: DesignTokens.Layout.statusDotSize),
            attentionDot.trailingAnchor.constraint(equalTo: sessionsButton.trailingAnchor, constant: 2),
            attentionDot.topAnchor.constraint(equalTo: sessionsButton.topAnchor, constant: -2),
        ])

        updateBranch(nil)
        updateAgents(0)
        updateSessions(0)

        themeObserver = NotificationCenter.default.addObserver(
            forName: GhosttyThemeProvider.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyThemeColors()
        }
        applyThemeColors()
    }

    private func applyThemeColors() {
        let color = GhosttyThemeProvider.shared.foregroundColor.withAlphaComponent(DesignTokens.TextOpacity.secondary)
        branchButton.contentTintColor = color
        agentsLabel.textColor = color
        sessionsButton.contentTintColor = color
        prPill.contentTintColor = .controlAccentColor
        prPill.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.1).cgColor
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
        branchButton.title = branch.map { "\u{E0A0} \($0)" } ?? "\u{E0A0} —"
    }

    func updateAgents(_ count: Int) {
        agentsLabel.stringValue = count > 0 ? "\(count) agent\(count == 1 ? "" : "s")" : "No agents"
    }

    func updateSessions(_ count: Int) {
        sessionsButton.title = "\(count) session\(count == 1 ? "" : "s")"
    }

    func updatePR(number: UInt64?, url: String?) {
        currentPRNumber = number
        currentPRURL = url
        if let number {
            prPill.title = "#\(number)"
            prPill.isHidden = false
        } else {
            prPill.isHidden = true
        }
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
