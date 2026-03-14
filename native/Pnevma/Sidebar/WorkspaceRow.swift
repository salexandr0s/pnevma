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

    private var themeAccentColor: Color {
        Color(nsColor: GhosttyThemeProvider.shared.foregroundColor)
    }

    private var totalNotifications: Int {
        workspace.unreadNotifications + workspace.terminalNotificationCount
    }

    private var indicatorColor: Color {
        if let hex = workspace.customColor, let nsColor = NSColor(hexString: hex) {
            return Color(nsColor: nsColor)
        }
        return isActive ? themeAccentColor : Color.secondary.opacity(0.3)
    }

    private var shortenedPath: String? {
        guard let path = workspace.displayPath else { return nil }
        let components = path.split(separator: "/")
        if components.count <= 2 { return path }
        return "~/" + components.suffix(2).joined(separator: "/")
    }

    private var modeLabel: String {
        switch workspace.location {
        case .local:
            return workspace.kind == .terminal ? "Terminal" : "Local"
        case .remote:
            return "Remote"
        }
    }

    private var terminalModeLabel: String {
        workspace.terminalMode == .persistent ? "Persistent" : "Local Shell"
    }

    private var failureMessage: String? {
        guard isActive else { return nil }
        return workspace.activationFailureMessage
    }

    var body: some View {
        HStack(spacing: 8) {
            // Pin icon or active indicator dot
            if workspace.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(indicatorColor)
                    .frame(width: 8, height: 8)
            } else {
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 8, height: 8)
            }

            VStack(alignment: .leading, spacing: 2) {
                if isRenaming {
                    TextField("Name", text: $renameText)
                        .textFieldStyle(.plain)
                        .font(.body)
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
                        .font(.body)
                        .fontWeight(isActive ? .semibold : .regular)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    if workspace.showsProjectToolsInUI && workspace.gitBranch == nil && isActive {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.7)
                    }

                    if let branch = workspace.gitBranch {
                        HStack(spacing: 2) {
                            Label(branch, systemImage: "arrow.triangle.branch")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if workspace.gitDirty {
                                Text("*")
                                    .font(.caption2)
                                    .bold()
                                    .foregroundStyle(.orange)
                            }
                        }
                        .lineLimit(1)
                    }

                    if workspace.activeTasks > 0 {
                        Label("\(workspace.activeTasks)", systemImage: "checklist")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Text(modeLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                        .fixedSize()

                    Text(terminalModeLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                        .fixedSize()

                    if failureMessage != nil {
                        Label("Activation Failed", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .fixedSize()
                    }
                }
                .lineLimit(1)
                .clipped()

                if let shortPath = shortenedPath {
                    Text(shortPath)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                if let failureMessage {
                    Text(failureMessage)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }

            Spacer()

            // Notification badge (backend + terminal notifications combined)
            if totalNotifications > 0 {
                NotificationBadge(count: totalNotifications)
                    .opacity(isHovering && !workspace.isPermanent ? 0 : 1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? indicatorColor.opacity(0.12) : Color.clear)
        )
        .overlay(alignment: .trailing) {
            if isHovering && !workspace.isPermanent {
                CloseButton(action: onClose)
                    .padding(.trailing, 4)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .accessibilityAddTraits(.isButton)
        .onHover { isHovering = $0 }
        .onChange(of: isRenaming) {
            if isRenaming {
                isRenameFieldFocused = true
            }
        }
        .contextMenu {
            Button("Rename...") {
                renameText = workspace.name
                isRenaming = true
            }
            Button(workspace.isPinned ? "Unpin" : "Pin") {
                onPin?()
            }

            Menu("Tab Color") {
                ForEach(WorkspaceColor.allCases) { color in
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
}
