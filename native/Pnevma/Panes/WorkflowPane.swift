import SwiftUI
import Cocoa

// MARK: - Data Models

struct WorkflowStep: Identifiable, Codable {
    let id: String
    let name: String
    let status: WorkflowStepStatus
    let dependsOn: [String]
    let startTime: String?
    let endTime: String?
    let agentName: String?
}

enum WorkflowStepStatus: String, Codable {
    case pending, running, completed, failed, skipped
    var color: Color {
        switch self {
        case .pending: return .secondary
        case .running: return .blue
        case .completed: return .green
        case .failed: return .red
        case .skipped: return .orange
        }
    }
}

// MARK: - WorkflowView

struct WorkflowView: View {
    @StateObject private var viewModel = WorkflowViewModel()
    @State private var viewMode: ViewMode = .dag

    enum ViewMode: String, CaseIterable {
        case dag = "DAG"
        case gantt = "Gantt"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Workflow")
                    .font(.headline)
                Spacer()
                Picker("View", selection: $viewMode) {
                    ForEach(ViewMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
            }
            .padding(12)

            Divider()

            switch viewMode {
            case .dag:
                DagView(steps: viewModel.steps)
            case .gantt:
                GanttView(steps: viewModel.steps)
            }
        }
        .onAppear { viewModel.load() }
    }
}

// MARK: - DAG View

struct DagView: View {
    let steps: [WorkflowStep]

    var body: some View {
        if steps.isEmpty {
            Spacer()
            Text("No workflow active")
                .foregroundStyle(.secondary)
            Spacer()
        } else {
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 16) {
                    // Group steps by dependency depth
                    ForEach(layers, id: \.0) { layer, layerSteps in
                        HStack(spacing: 16) {
                            ForEach(layerSteps) { step in
                                StepNodeView(step: step)
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private var layers: [(Int, [WorkflowStep])] {
        // Simple topological layering
        var depths: [String: Int] = [:]
        for step in steps where step.dependsOn.isEmpty {
            depths[step.id] = 0
        }
        var changed = true
        while changed {
            changed = false
            for step in steps where depths[step.id] == nil {
                let depDepths = step.dependsOn.compactMap { depths[$0] }
                if depDepths.count == step.dependsOn.count {
                    depths[step.id] = (depDepths.max() ?? 0) + 1
                    changed = true
                }
            }
        }
        // Fallback for cycles
        for step in steps where depths[step.id] == nil {
            depths[step.id] = 0
        }

        let grouped = Dictionary(grouping: steps) { depths[$0.id] ?? 0 }
        return grouped.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
}

// MARK: - Gantt View

struct GanttView: View {
    let steps: [WorkflowStep]

    var body: some View {
        if steps.isEmpty {
            Spacer()
            Text("No workflow active")
                .foregroundStyle(.secondary)
            Spacer()
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(steps) { step in
                        HStack(spacing: 8) {
                            Text(step.name)
                                .font(.caption)
                                .frame(width: 120, alignment: .trailing)

                            RoundedRectangle(cornerRadius: 4)
                                .fill(step.status.color)
                                .frame(width: barWidth(step), height: 20)

                            if let agent = step.agentName {
                                Text(agent)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private func barWidth(_ step: WorkflowStep) -> CGFloat {
        switch step.status {
        case .completed: return 120
        case .running: return 80
        case .failed: return 60
        default: return 40
        }
    }
}

// MARK: - StepNodeView

struct StepNodeView: View {
    let step: WorkflowStep

    var body: some View {
        VStack(spacing: 4) {
            Circle()
                .fill(step.status.color)
                .frame(width: 24, height: 24)
                .overlay {
                    statusIcon
                        .font(.caption2)
                        .foregroundStyle(.white)
                }

            Text(step.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)

            if let agent = step.agentName {
                Text(agent)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 80)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .stroke(step.status.color.opacity(0.3), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch step.status {
        case .completed: Image(systemName: "checkmark")
        case .running: Image(systemName: "play.fill")
        case .failed: Image(systemName: "xmark")
        case .skipped: Image(systemName: "forward.fill")
        case .pending: Image(systemName: "clock")
        }
    }
}

// MARK: - ViewModel

final class WorkflowViewModel: ObservableObject {
    @Published var steps: [WorkflowStep] = []

    func load() {
        // pnevma_call("workflow.list", "{}")
    }
}

// MARK: - NSView Wrapper

final class WorkflowPaneView: NSView, PaneContent {
    let paneID = PaneID()
    let paneType = "workflow"
    var title: String { "Workflow" }

    override init(frame: NSRect) {
        super.init(frame: frame)
        _ = addSwiftUISubview(WorkflowView())
    }

    required init?(coder: NSCoder) { fatalError() }
}
