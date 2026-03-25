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
    private let hintLabel = NSTextField(labelWithString: "")

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

        // Hint label for prefix shortcuts
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.isEditable = false
        hintLabel.isBordered = false
        hintLabel.drawsBackground = false
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.alignment = .center
        let fg = GhosttyThemeProvider.shared.foregroundColor
        hintLabel.textColor = fg.withAlphaComponent(DesignTokens.TextOpacity.tertiary)
        hintLabel.stringValue = ">  Commands     :  Files     @  Workspaces     #  Tasks"
        contentView.addSubview(hintLabel)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            searchField.heightAnchor.constraint(equalToConstant: 32),

            hintLabel.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
            hintLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            hintLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 4),
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

    /// Show the palette with a prefix pre-filled (e.g. ":" for files).
    func show(prefix: String) {
        searchField.stringValue = prefix
        makeKeyAndOrderFront(nil)
        searchField.becomeFirstResponder()
        // Position cursor at end of prefix
        if let editor = searchField.currentEditor() {
            editor.selectedRange = NSRange(location: prefix.utf16.count, length: 0)
        }
        searchChanged()
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
        let query = searchField.stringValue
        hintLabel.isHidden = !query.isEmpty
        if query.isEmpty {
            filteredCommands = allCommands
        } else if let firstChar = query.first,
                  let category = PaletteCategory.allCases.first(where: { $0.filterPrefix == firstChar }) {
            let searchText = String(query.dropFirst()).trimmingCharacters(in: .whitespaces).lowercased()
            // For command prefix (>), all palette items are commands — show all.
            // For other prefixes, filter by the matching category key.
            let categoryItems = category == .command
                ? allCommands
                : allCommands.filter { $0.category == category.commandItemKey }
            if searchText.isEmpty {
                filteredCommands = categoryItems
            } else {
                filteredCommands = categoryItems.filter { item in
                    fuzzyMatch(query: searchText, target: item.title.lowercased())
                }
            }
        } else {
            let lowerQuery = query.lowercased()
            filteredCommands = allCommands.filter { item in
                fuzzyMatch(query: lowerQuery, target: item.title.lowercased())
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

    /// Returns indices of matched characters in `target`, or nil if no match.
    private func fuzzyMatchIndices(query: String, target: String) -> [Int]? {
        var queryIndex = query.startIndex
        var targetIndex = target.startIndex
        var matches: [Int] = []
        var position = 0

        while queryIndex < query.endIndex && targetIndex < target.endIndex {
            if query[queryIndex] == target[targetIndex] {
                matches.append(position)
                queryIndex = query.index(after: queryIndex)
            }
            targetIndex = target.index(after: targetIndex)
            position += 1
        }
        return queryIndex == query.endIndex ? matches : nil
    }

    private func fuzzyMatch(query: String, target: String) -> Bool {
        fuzzyMatchIndices(query: query, target: target) != nil
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

        // Compute match indices for highlighting
        let query = searchField.stringValue.lowercased()
        let matchIndices: [Int]?
        if query.isEmpty {
            matchIndices = nil
        } else if let first = query.first,
                  PaletteCategory.allCases.contains(where: { $0.filterPrefix == first }) {
            let stripped = String(query.dropFirst()).trimmingCharacters(in: .whitespaces).lowercased()
            matchIndices = stripped.isEmpty ? nil : fuzzyMatchIndices(query: stripped, target: item.title.lowercased())
        } else {
            matchIndices = fuzzyMatchIndices(query: query, target: item.title.lowercased())
        }

        // Map category to icon
        let categoryIcon = PaletteCategory.allCases
            .first { $0.commandItemKey == item.category }?.icon ?? "terminal"

        cell.configure(
            title: item.title,
            category: item.category,
            shortcut: item.shortcut,
            description: item.description,
            categoryIcon: categoryIcon,
            matchIndices: matchIndices
        )
        return cell
    }
}

// MARK: - CommandCellView

private final class CommandCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let categoryLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let descriptionLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

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

        addSubview(iconView)
        for label in [titleLabel, categoryLabel, shortcutLabel, descriptionLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.isEditable = false
            label.isBordered = false
            label.drawsBackground = false
            addSubview(label)
        }

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: categoryLabel.leadingAnchor, constant: -4),

            descriptionLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
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
        iconView.contentTintColor = fg.withAlphaComponent(DesignTokens.TextOpacity.tertiary)
    }

    func configure(
        title: String,
        category: String,
        shortcut: String?,
        description: String? = nil,
        categoryIcon: String = "terminal",
        matchIndices: [Int]? = nil
    ) {
        // Category icon
        iconView.image = NSImage(
            systemSymbolName: categoryIcon,
            accessibilityDescription: category
        )?.withSymbolConfiguration(.init(pointSize: 12, weight: .medium))

        // Title with fuzzy match highlighting
        if let matchIndices, !matchIndices.isEmpty {
            let fg = GhosttyThemeProvider.shared.foregroundColor
            let attributed = NSMutableAttributedString(
                string: title,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13),
                    .foregroundColor: fg.withAlphaComponent(0.85),
                ]
            )
            let matchSet = Set(matchIndices)
            for i in 0..<title.count where matchSet.contains(i) {
                let range = NSRange(location: i, length: 1)
                attributed.addAttributes([
                    .font: NSFont.systemFont(ofSize: 13, weight: .bold),
                    .foregroundColor: NSColor.controlAccentColor,
                ], range: range)
            }
            titleLabel.attributedStringValue = attributed
        } else {
            titleLabel.stringValue = title
        }

        categoryLabel.stringValue = category
        shortcutLabel.stringValue = shortcut ?? ""
        descriptionLabel.stringValue = description ?? ""
        descriptionLabel.isHidden = (description ?? "").isEmpty
    }
}
