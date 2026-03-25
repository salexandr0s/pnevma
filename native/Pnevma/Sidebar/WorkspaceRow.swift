import Cocoa
import SwiftUI

// MARK: - WorkspaceRow

struct WorkspaceRow: View {
    var workspace: Workspace
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    var onRename: ((String) -> Void)?
    var onPin: (() -> Void)?
    var onSetColor: ((String?) -> Void)?

    @State private var isHovering = false
    @State private var isRenaming = false
    @State private var renameText = ""
    @FocusState private var isRenameFieldFocused: Bool

    private var totalNotifications: Int {
        workspace.unreadNotifications + workspace.terminalNotificationCount
    }

    /// Resolved project color: user override → automatic from project name → fallback.
    private var projectColor: Color {
        if let hex = workspace.customColor, let nsColor = NSColor(hexString: hex) {
            return Color(nsColor: nsColor)
        }
        if let root = workspace.projectRoot {
            return ProjectColorPalette.color(for: root)
        }
        return Color(nsColor: GhosttyThemeProvider.shared.foregroundColor)
    }

    /// Indicator color modulated by operational state.
    private var indicatorColor: Color {
        let stateOpacity = ProjectColorPalette.stateOpacity(workspace.operationalState)
        return isActive ? projectColor.opacity(stateOpacity) : projectColor.opacity(0.20)
    }

    private var modeLabel: String {
        switch workspace.location {
        case .local:
            return workspace.kind == .terminal ? "Terminal" : "Local"
        case .remote:
            return "Remote"
        }
    }

    private var failureMessage: String? {
        guard isActive else { return nil }
        return workspace.activationFailureMessage
    }

    private var workspaceTypeIcon: String {
        switch workspace.kind {
        case .terminal: return "terminal"
        case .project:
            return workspace.location == .remote ? "network" : "laptopcomputer"
        }
    }

    private var branchSubtitle: String? {
        guard let branch = workspace.gitBranch, branch != workspace.name else { return nil }
        let dirty = workspace.gitDirty ? " *" : ""
        return branch + dirty
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 0) {
                // Left indicator bar — project color, modulated by state
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(isActive ? indicatorColor : .clear)
                    .frame(width: 3)
                    .padding(.vertical, 2)

                HStack(spacing: 10) {
                    // Workspace type icon
                    Image(systemName: workspaceTypeIcon)
                        .font(.system(size: 14))
                        .foregroundStyle(isActive ? .primary : .secondary)
                        .frame(width: 16, height: 16)

                    VStack(alignment: .leading, spacing: 1) {
                        // Name
                        if isRenaming {
                            TextField("Name", text: $renameText)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .fontWeight(.semibold)
                                .focused($isRenameFieldFocused)
                                .onSubmit {
                                    let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                                    if !trimmed.isEmpty {
                                        onRename?(trimmed)
                                    }
                                    isRenaming = false
                                }
                                .onExitCommand {
                                    isRenaming = false
                                }
                        } else {
                            Text(workspace.name)
                                .font(.system(size: 13))
                                .fontWeight(isActive ? .semibold : .regular)
                                .foregroundStyle(isActive ? .primary : .secondary)
                                .lineLimit(1)
                        }

                        // Branch subtitle
                        if let subtitle = branchSubtitle {
                            Text(subtitle)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }

                        // Failure chip (replaces inline 10pt orange text)
                        if let failureMessage {
                            StatusChipView(failureMessage, icon: "exclamationmark.triangle.fill", style: .error)
                        }
                    }

                    Spacer()

                    // Trailing: close button, diff stats, or notification badge
                    if isHovering && !workspace.isPermanent {
                        CloseButton(action: onClose)
                    } else if let ins = workspace.diffInsertions, let dels = workspace.diffDeletions,
                              ins > 0 || dels > 0 {
                        DiffStatsChip(insertions: ins, deletions: dels)
                    } else if totalNotifications > 0 {
                        NotificationBadge(count: totalNotifications)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? projectColor.opacity(0.10) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onChange(of: isRenaming) {
            if isRenaming {
                isRenameFieldFocused = true
            }
        }
        .help(workspace.displayPath ?? workspace.name)
        .contextMenu {
            Button("Rename...") {
                renameText = workspace.name
                isRenaming = true
            }
            Button(workspace.isPinned ? "Unpin" : "Pin") {
                onPin?()
            }

            Menu("Tab Color") {
                Section("Warm") {
                    ForEach(WorkspaceColor.warm) { color in
                        colorMenuItem(color)
                    }
                }
                Section("Cool") {
                    ForEach(WorkspaceColor.cool) { color in
                        colorMenuItem(color)
                    }
                }
                Section("Neutral") {
                    ForEach(WorkspaceColor.neutral) { color in
                        colorMenuItem(color)
                    }
                }
                Divider()
                Button("Clear Color") {
                    onSetColor?(nil)
                }
            }

            if let path = workspace.displayPath {
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                }
                if workspace.location == .local {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
                    }
                    ShareLink("Share Project Path", item: URL(fileURLWithPath: path))
                }
            }
            Divider()
            if !workspace.isPermanent {
                Button("Close Workspace", role: .destructive) {
                    onClose()
                }
            }
        }
        .accessibilityLabel("Workspace: \(workspace.name)\(workspace.isPinned ? ", pinned" : "")")
    }

    private func colorMenuItem(_ color: WorkspaceColor) -> some View {
        Button {
            onSetColor?(color.hex)
        } label: {
            HStack {
                Circle()
                    .fill(color.swiftUIColor)
                    .frame(width: 10, height: 10)
                Text(color.name)
            }
        }
    }
}

// MARK: - WorkspaceColor

enum WorkspaceColor: String, CaseIterable, Identifiable {
    case red, crimson, orange, amber, olive, green, teal, aqua
    case blue, navy, indigo, purple, magenta, rose, brown, charcoal

    var id: String { rawValue }

    var name: String { rawValue.capitalized }

    var hex: String {
        switch self {
        case .red:      return "#FF3B30"
        case .crimson:  return "#DC3545"
        case .orange:   return "#FF9500"
        case .amber:    return "#FFCC00"
        case .olive:    return "#A8B820"
        case .green:    return "#34C759"
        case .teal:     return "#5AC8C8"
        case .aqua:     return "#32ADE6"
        case .blue:     return "#007AFF"
        case .navy:     return "#5856D6"
        case .indigo:   return "#7B61FF"
        case .purple:   return "#AF52DE"
        case .magenta:  return "#FF2D55"
        case .rose:     return "#FF6482"
        case .brown:    return "#A2845E"
        case .charcoal: return "#636366"
        }
    }

    var swiftUIColor: Color {
        Color(nsColor: NSColor(hexString: hex) ?? .labelColor)
    }

    static var warm: [WorkspaceColor] {
        [.red, .crimson, .orange, .amber, .rose, .magenta, .brown]
    }

    static var cool: [WorkspaceColor] {
        [.blue, .navy, .indigo, .purple, .teal, .aqua, .green]
    }

    static var neutral: [WorkspaceColor] {
        [.olive, .charcoal]
    }
}
