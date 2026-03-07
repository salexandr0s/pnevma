import Cocoa

/// Bottom status bar showing git branch, active agents, pool utilization, and pane info.
final class StatusBar: NSView {

    // MARK: - Labels

    private let branchLabel = NSTextField(labelWithString: "")
    private let agentsLabel = NSTextField(labelWithString: "")
    private let paneLabel = NSTextField(labelWithString: "")
    private let separator1 = NSBox()
    private let separator2 = NSBox()

    // MARK: - Init

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

    private var themeObserver: NSObjectProtocol?

    private func setupUI() {
        wantsLayer = true

        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let secondaryColor = NSColor.secondaryLabelColor

        for label in [branchLabel, agentsLabel, paneLabel] {
            label.font = font
            label.textColor = secondaryColor
            label.isEditable = false
            label.isBordered = false
            label.drawsBackground = false
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }

        for sep in [separator1, separator2] {
            sep.boxType = .separator
            sep.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sep)
        }

        // Top border
        let topBorder = NSBox()
        topBorder.boxType = .separator
        topBorder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topBorder)

        NSLayoutConstraint.activate([
            topBorder.topAnchor.constraint(equalTo: topAnchor),
            topBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            topBorder.heightAnchor.constraint(equalToConstant: 1),

            branchLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            branchLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            separator1.leadingAnchor.constraint(equalTo: branchLabel.trailingAnchor, constant: 10),
            separator1.centerYAnchor.constraint(equalTo: centerYAnchor),
            separator1.widthAnchor.constraint(equalToConstant: 1),
            separator1.heightAnchor.constraint(equalToConstant: 14),

            agentsLabel.leadingAnchor.constraint(equalTo: separator1.trailingAnchor, constant: 10),
            agentsLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            separator2.leadingAnchor.constraint(equalTo: agentsLabel.trailingAnchor, constant: 10),
            separator2.centerYAnchor.constraint(equalTo: centerYAnchor),
            separator2.widthAnchor.constraint(equalToConstant: 1),
            separator2.heightAnchor.constraint(equalToConstant: 14),

            paneLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            paneLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        // Accessibility
        branchLabel.setAccessibilityLabel("Git branch")
        agentsLabel.setAccessibilityLabel("Active agents")
        paneLabel.setAccessibilityLabel("Active pane")

        // Defaults
        updateBranch(nil)
        updateAgents(0)
        updateActivePane("Terminal")

        // Observe theme changes
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
        let theme = GhosttyThemeProvider.shared
        let fgColor = theme.foregroundColor.withAlphaComponent(0.6)
        for label in [branchLabel, agentsLabel, paneLabel] {
            label.textColor = fgColor
        }
        needsDisplay = true
    }

    // MARK: - Updates

    func updateBranch(_ branch: String?) {
        branchLabel.stringValue = branch.map { "\u{E0A0} \($0)" } ?? "\u{E0A0} —"
    }

    func updateAgents(_ count: Int) {
        agentsLabel.stringValue = count > 0 ? "\(count) agent\(count == 1 ? "" : "s")" : "No agents"
    }

    func updateActivePane(_ title: String) {
        paneLabel.stringValue = title
    }

    // MARK: - Drawing
    override func draw(_ dirtyRect: NSRect) {
        GhosttyThemeProvider.shared.backgroundColor.setFill()
        bounds.fill()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: DesignTokens.Layout.statusBarHeight)
    }

    // MARK: - Accessibility
    override func accessibilityLabel() -> String? { "Status Bar" }
    override func accessibilityRole() -> NSAccessibility.Role? { .toolbar }
}
