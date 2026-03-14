import Cocoa
import Observation

final class TitlebarStatusView: NSView {
    private let branchLabel = NSTextField(labelWithString: "")
    private let agentsLabel = NSTextField(labelWithString: "")
    let sessionsButton = NSButton(frame: .zero)
    private let separator1 = NSBox()
    private let separator2 = NSBox()
    private var themeObserver: NSObjectProtocol?
    private var sessionObservationGeneration: UInt64 = 0

    var onSessionsClicked: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    deinit {
        if let themeObserver {
            NotificationCenter.default.removeObserver(themeObserver)
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 320, height: 24)
    }

    private func setupUI() {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        for label in [branchLabel, agentsLabel] {
            label.font = font
            label.isEditable = false
            label.isBordered = false
            label.drawsBackground = false
            label.cell?.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }

        sessionsButton.bezelStyle = .inline
        sessionsButton.isBordered = false
        sessionsButton.font = font
        sessionsButton.title = "0 sessions"
        sessionsButton.target = self
        sessionsButton.action = #selector(sessionsClicked)
        sessionsButton.setAccessibilityLabel("Sessions")
        sessionsButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sessionsButton)

        for separator in [separator1, separator2] {
            separator.boxType = .separator
            separator.translatesAutoresizingMaskIntoConstraints = false
            addSubview(separator)
        }

        NSLayoutConstraint.activate([
            branchLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            branchLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            separator1.leadingAnchor.constraint(equalTo: branchLabel.trailingAnchor, constant: 8),
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
        ])

        branchLabel.setAccessibilityLabel("Git branch")
        agentsLabel.setAccessibilityLabel("Active agents")

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
        branchLabel.textColor = color
        agentsLabel.textColor = color
        sessionsButton.contentTintColor = color
    }

    @objc private func sessionsClicked() {
        onSessionsClicked?()
    }

    func updateBranch(_ branch: String?) {
        branchLabel.stringValue = branch.map { "\u{E0A0} \($0)" } ?? "\u{E0A0} —"
    }

    func updateAgents(_ count: Int) {
        agentsLabel.stringValue = count > 0 ? "\(count) agent\(count == 1 ? "" : "s")" : "No agents"
    }

    func updateSessions(_ count: Int) {
        sessionsButton.title = "\(count) session\(count == 1 ? "" : "s")"
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
