import Cocoa

// MARK: - Command Item

struct CommandItem {
    let id: String
    let title: String
    let category: String  // e.g. "command", "pane", "tool", "file"
    let shortcut: String?
    let description: String?
    let action: () -> Void

    init(id: String, title: String, category: String, shortcut: String? = nil, description: String? = nil, action: @escaping () -> Void) {
        self.id = id
        self.title = title
        self.category = category
        self.shortcut = shortcut
        self.description = description
        self.action = action
    }
}

// MARK: - CommandPalette

/// Floating NSPanel command palette (Shift+Cmd+P).
/// Fuzzy-searches registered commands and dispatches the selected one.
final class CommandPalette: NSPanel {

    // MARK: - Properties

    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    private var allCommands: [CommandItem] = []
    private var filteredCommands: [CommandItem] = []

    // MARK: - Init

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    init() {
        let width: CGFloat = 500
        let height: CGFloat = 340
        let screen = NSScreen.main?.frame ?? .zero
        let origin = NSPoint(x: (screen.width - width) / 2, y: screen.height * 0.6)
        let contentRect = NSRect(origin: origin, size: NSSize(width: width, height: height))

        super.init(contentRect: contentRect,
                   styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: true)

        isFloatingPanel = true
        level = .floating
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = true
        backgroundColor = GhosttyThemeProvider.shared.backgroundColor

        NotificationCenter.default.addObserver(
            forName: GhosttyThemeProvider.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.backgroundColor = GhosttyThemeProvider.shared.backgroundColor
            }
        }

        setupUI()
    }

    // MARK: - Setup

    private func setupUI() {
        guard let contentView = contentView else { return }

        // Search field
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Type a command..."
        searchField.font = .systemFont(ofSize: 16)
        searchField.delegate = self
        searchField.setAccessibilityLabel("Command search")
        contentView.addSubview(searchField)

        // Table view for results
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
        column.title = ""
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = 42
        tableView.style = .plain
        tableView.target = self
        tableView.doubleAction = #selector(executeSelected)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        contentView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            searchField.heightAnchor.constraint(equalToConstant: 32),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    // MARK: - Public API

    /// Register commands that appear in the palette.
    func registerCommands(_ commands: [CommandItem]) {
        allCommands = commands
        filteredCommands = commands
        tableView.reloadData()
    }

    /// Show the palette and focus the search field.
    func show() {
        searchField.stringValue = ""
        filteredCommands = allCommands
        tableView.reloadData()
        makeKeyAndOrderFront(nil)
        searchField.becomeFirstResponder()
        if !filteredCommands.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    /// Hide the palette.
    func dismiss() {
        orderOut(nil)
    }

    // MARK: - Key Handling

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape
            dismiss()
        case 36: // Return
            executeSelected()
        case 125: // Down arrow
            guard filteredCommands.count > 0 else { break }
            let next = (tableView.selectedRow + 1) % filteredCommands.count
            tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
            tableView.scrollRowToVisible(next)
        case 126: // Up arrow
            guard filteredCommands.count > 0 else { break }
            let current = tableView.selectedRow < 0 ? 0 : tableView.selectedRow
            let prev = (current - 1 + filteredCommands.count) % filteredCommands.count
            tableView.selectRowIndexes(IndexSet(integer: prev), byExtendingSelection: false)
            tableView.scrollRowToVisible(prev)
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Actions

    @objc private func searchChanged() {
        let query = searchField.stringValue.lowercased()
        if query.isEmpty {
            filteredCommands = allCommands
        } else {
            filteredCommands = allCommands.filter { item in
                fuzzyMatch(query: query, target: item.title.lowercased())
            }
        }
        tableView.reloadData()
        if !filteredCommands.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    @objc private func executeSelected() {
        let row = tableView.selectedRow
        guard row >= 0, row < filteredCommands.count else { return }
        let command = filteredCommands[row]
        dismiss()
        command.action()
    }

    // MARK: - Fuzzy Match

    private func fuzzyMatch(query: String, target: String) -> Bool {
        var queryIndex = query.startIndex
        var targetIndex = target.startIndex

        while queryIndex < query.endIndex && targetIndex < target.endIndex {
            if query[queryIndex] == target[targetIndex] {
                queryIndex = query.index(after: queryIndex)
            }
            targetIndex = target.index(after: targetIndex)
        }
        return queryIndex == query.endIndex
    }
}

// MARK: - NSSearchFieldDelegate

extension CommandPalette: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        searchChanged()
    }
}

// MARK: - NSTableViewDataSource

extension CommandPalette: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredCommands.count
    }
}

// MARK: - NSTableViewDelegate

extension CommandPalette: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = filteredCommands[row]
        let cellID = NSUserInterfaceItemIdentifier("CommandCell")

        let cell = tableView.makeView(withIdentifier: cellID, owner: nil) as? CommandCellView
            ?? CommandCellView(identifier: cellID)

        cell.configure(title: item.title, category: item.category, shortcut: item.shortcut, description: item.description)
        return cell
    }
}

// MARK: - CommandCellView

private final class CommandCellView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let categoryLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let descriptionLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        categoryLabel.font = .systemFont(ofSize: 10)
        shortcutLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        descriptionLabel.font = .systemFont(ofSize: 10)
        descriptionLabel.lineBreakMode = .byTruncatingTail
        applyThemeColors()

        NotificationCenter.default.addObserver(
            forName: GhosttyThemeProvider.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.applyThemeColors()
            }
        }

        for label in [titleLabel, categoryLabel, shortcutLabel, descriptionLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.isEditable = false
            label.isBordered = false
            label.drawsBackground = false
            addSubview(label)
        }

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: categoryLabel.leadingAnchor, constant: -4),

            descriptionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            descriptionLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            descriptionLabel.trailingAnchor.constraint(lessThanOrEqualTo: shortcutLabel.leadingAnchor, constant: -8),

            categoryLabel.trailingAnchor.constraint(lessThanOrEqualTo: shortcutLabel.leadingAnchor, constant: -8),
            categoryLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            shortcutLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            shortcutLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func applyThemeColors() {
        let fg = GhosttyThemeProvider.shared.foregroundColor
        titleLabel.textColor = fg.withAlphaComponent(0.85)
        categoryLabel.textColor = fg.withAlphaComponent(DesignTokens.TextOpacity.tertiary)
        shortcutLabel.textColor = fg.withAlphaComponent(DesignTokens.TextOpacity.tertiary)
        descriptionLabel.textColor = fg.withAlphaComponent(DesignTokens.TextOpacity.tertiary)
    }

    func configure(title: String, category: String, shortcut: String?, description: String? = nil) {
        titleLabel.stringValue = title
        categoryLabel.stringValue = category
        shortcutLabel.stringValue = shortcut ?? ""
        descriptionLabel.stringValue = description ?? ""
        descriptionLabel.isHidden = (description ?? "").isEmpty
    }
}
