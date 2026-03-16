import SwiftUI

// MARK: - Instance Detail View (DAG)

struct InstanceDetailView: View {
    let detail: WorkflowInstanceDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(detail.workflowName).font(.headline)
                StatusBadge(status: detail.status)
                Spacer()
                Text("\(detail.steps.count) steps")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider().opacity(0.3)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(layers.enumerated()), id: \.offset) { layerIdx, layer in
                        let (_, layerSteps) = layer
                        VStack(spacing: 10) {
                            ForEach(layerSteps) { step in
                                InstanceStepNode(step: step)
                            }
                        }
                        if layerIdx < layers.count - 1 {
                            // Single connector between layers — intentional
                            // simplification; per-node edges would need Canvas.
                            VStack {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary.opacity(0.4))
                            }
                            .frame(width: 28)
                        }
                    }
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var layers: [(Int, [WorkflowInstanceStepItem])] {
        var depths: [String: Int] = [:]
        for step in detail.steps where step.dependsOn.isEmpty {
            depths[step.taskId] = 0
        }
        var changed = true
        var iterations = 0
        while changed && iterations < detail.steps.count {
            changed = false
            iterations += 1
            for step in detail.steps where depths[step.taskId] == nil {
                let depDepths = step.dependsOn.compactMap { depths[$0] }
                if depDepths.count == step.dependsOn.count {
                    depths[step.taskId] = (depDepths.max() ?? 0) + 1
                    changed = true
                }
            }
        }
        for step in detail.steps where depths[step.taskId] == nil {
            depths[step.taskId] = 0
        }
        let grouped = Dictionary(grouping: detail.steps) { depths[$0.taskId] ?? 0 }
        return grouped.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
}

struct InstanceStepNode: View {
    let step: WorkflowInstanceStepItem

    var body: some View {
        HStack(spacing: 10) {
            // Status indicator
            ZStack {
                Circle()
                    .fill(step.statusColor.opacity(0.15))
                    .frame(width: 32, height: 32)
                Circle()
                    .fill(step.statusColor)
                    .frame(width: 20, height: 20)
                    .overlay {
                        statusIcon
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                    }
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(step.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    if step.iteration > 0 {
                        Text("iter \(step.iteration)")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.purple.opacity(0.15))
                            .clipShape(.rect(cornerRadius: 3))
                            .foregroundStyle(.purple)
                    }
                }

                HStack(spacing: 6) {
                    if let profile = step.agentProfile {
                        Text(profile)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.purple.opacity(0.8))
                    }
                    HStack(spacing: 2) {
                        Image(systemName: step.executionMode == "main" ? "house.fill" : "arrow.triangle.branch")
                            .font(.caption2)
                        Text(step.executionMode)
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minWidth: 160, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(step.statusColor.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(step.statusColor.opacity(0.2), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(step.title), \(step.status), \(step.executionMode)")
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch step.status.lowercased() {
        case "completed", "done": Image(systemName: "checkmark")
        case "inprogress", "in_progress", "running": Image(systemName: "play.fill")
        case "failed": Image(systemName: "xmark")
        case "blocked": Image(systemName: "lock.fill")
        case "ready": Image(systemName: "bolt.fill")
        case "looped": Image(systemName: "arrow.trianglehead.2.clockwise")
        default: Image(systemName: "clock")
        }
    }
}
