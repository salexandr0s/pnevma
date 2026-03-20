import SwiftUI

struct WorkspaceOpenerProjectPicker: View {
    @Binding var selectedPath: String?
    let projects: [ProjectEntry]

    private var selectedProject: ProjectEntry? {
        guard let selectedPath else { return nil }
        return projects.first { $0.path == selectedPath } ?? ProjectEntry(path: selectedPath)
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
            HStack(spacing: 8) {
                if let project = selectedProject {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Text(project.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Open Folder…")
                        .font(.system(size: 12, weight: .semibold))
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 140, maxWidth: 190, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.borderlessButton)
        .accessibilityIdentifier("workspaceOpener.projectPicker")
    }
}
