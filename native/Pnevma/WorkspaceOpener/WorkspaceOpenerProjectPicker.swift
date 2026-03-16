import SwiftUI

struct WorkspaceOpenerProjectPicker: View {
    @Binding var selectedPath: String?
    let projects: [ProjectEntry]

    @Environment(GhosttyThemeProvider.self) private var theme

    private var selectedProject: ProjectEntry? {
        projects.first { $0.path == selectedPath }
    }

    var body: some View {
        Menu {
            ForEach(projects) { project in
                Button {
                    selectedPath = project.path
                } label: {
                    HStack {
                        Text(project.name)
                        if project.path == selectedPath {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }

            Divider()

            Button("Open Folder\u{2026}") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url {
                    selectedPath = url.path
                }
            }
        } label: {
            HStack(spacing: 6) {
                if let project = selectedProject {
                    projectInitial(project.name)
                    Text(project.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                } else {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                    Text("Select project")
                        .font(.system(size: 12, weight: .medium))
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(DesignTokens.Opacity.subtle))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func projectInitial(_ name: String) -> some View {
        let initial = name.prefix(1).uppercased()
        return ZStack {
            Circle()
                .fill(Color(nsColor: theme.foregroundColor).opacity(0.12))
                .frame(width: 20, height: 20)
            Text(initial)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }
}
