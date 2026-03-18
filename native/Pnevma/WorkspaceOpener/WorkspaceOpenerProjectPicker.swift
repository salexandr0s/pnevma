import SwiftUI

struct WorkspaceOpenerProjectPicker: View {
    @Binding var selectedPath: String?
    let projects: [ProjectEntry]

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
            HStack(spacing: 8) {
                if let project = selectedProject {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(project.name)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text(project.path)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
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
            .frame(minWidth: 240, maxWidth: 320, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.borderlessButton)
    }
}
