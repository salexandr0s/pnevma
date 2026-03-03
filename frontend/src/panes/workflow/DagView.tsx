import { useMemo } from "react";
import { computeDagLayout, type StepInput } from "./layout";
import { STATUS_COLORS } from "./constants";

type Props = {
  steps: StepInput[];
  onNodeClick?: (stepIndex: number) => void;
};

export function DagView({ steps, onNodeClick }: Props) {
  const layout = useMemo(() => computeDagLayout(steps), [steps]);

  if (layout.nodes.length === 0) {
    return <div className="flex h-full items-center justify-center text-slate-500">No steps</div>;
  }

  return (
    <svg
      width={layout.width}
      height={layout.height}
      className="overflow-visible"
      role="img"
      aria-label="Workflow DAG"
    >
      {/* Edges */}
      {layout.edges.map((edge, i) => (
        <path
          key={i}
          d={edge.path}
          fill="none"
          stroke="#475569"
          strokeWidth={1.5}
          markerEnd="url(#arrow)"
        />
      ))}

      {/* Arrow marker */}
      <defs>
        <marker id="arrow" markerWidth="8" markerHeight="8" refX="8" refY="4" orient="auto">
          <path d="M 0 0 L 8 4 L 0 8" fill="none" stroke="#475569" strokeWidth="1" />
        </marker>
      </defs>

      {/* Nodes */}
      {layout.nodes.map((node) => {
        const color = STATUS_COLORS[node.status] ?? "#475569";
        const isActive = node.status === "InProgress";
        return (
          <g
            key={node.id}
            transform={`translate(${node.x}, ${node.y})`}
            onClick={() => onNodeClick?.(node.stepIndex)}
            className="cursor-pointer"
            tabIndex={0}
            role="button"
            aria-label={`${node.label} - ${node.status}`}
          >
            <rect
              width={node.width}
              height={node.height}
              rx={8}
              fill="#0f172a"
              stroke={color}
              strokeWidth={2}
              className={isActive ? "animate-pulse" : ""}
            />
            <text
              x={node.width / 2}
              y={22}
              textAnchor="middle"
              fill="#e2e8f0"
              fontSize={12}
              fontWeight={600}
            >
              {node.label.length > 20 ? node.label.slice(0, 18) + "…" : node.label}
            </text>
            <text
              x={node.width / 2}
              y={42}
              textAnchor="middle"
              fill={color}
              fontSize={10}
            >
              {node.status}
            </text>
          </g>
        );
      })}
    </svg>
  );
}
