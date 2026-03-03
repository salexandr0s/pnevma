import { useEffect, useState } from "react";
import { listWorkflowDefs, listWorkflowInstances } from "../../hooks/useTauri";
import type { WorkflowDef, WorkflowInstance } from "../../lib/types";
import { DagView } from "./DagView";
import { GanttView } from "./GanttView";
import type { StepInput } from "./layout";

type Tab = "dag" | "gantt";

export function WorkflowPane() {
  const [defs, setDefs] = useState<WorkflowDef[]>([]);
  const [instances, setInstances] = useState<WorkflowInstance[]>([]);
  const [selectedDef, setSelectedDef] = useState<string | null>(null);
  const [selectedInstance, setSelectedInstance] = useState<string | null>(null);
  const [tab, setTab] = useState<Tab>("dag");

  useEffect(() => {
    void listWorkflowDefs().then(setDefs);
    void listWorkflowInstances().then(setInstances);
  }, []);

  const activeDef = defs.find((d) => d.name === selectedDef);

  const steps: StepInput[] = activeDef
    ? activeDef.steps.map((s, i) => ({
        id: `step-${i}`,
        title: s.title,
        status: "Planned",
        dependsOn: s.depends_on,
      }))
    : [];

  return (
    <div className="flex h-full flex-col">
      {/* Header */}
      <div className="flex items-center gap-2 border-b border-white/10 px-3 py-2">
        <h2 className="text-sm font-semibold">Workflows</h2>
        <div className="ml-auto flex gap-1">
          <button
            className={`rounded px-2 py-1 text-xs ${tab === "dag" ? "bg-mint-500/20 text-mint-400" : "text-slate-500"}`}
            onClick={() => setTab("dag")}
          >
            DAG
          </button>
          <button
            className={`rounded px-2 py-1 text-xs ${tab === "gantt" ? "bg-mint-500/20 text-mint-400" : "text-slate-500"}`}
            onClick={() => setTab("gantt")}
          >
            Timeline
          </button>
        </div>
      </div>

      {/* Workflow selector */}
      <div className="flex gap-2 border-b border-white/10 px-3 py-2">
        <select
          className="rounded bg-slate-900 px-2 py-1 text-xs text-slate-300 outline-none"
          value={selectedDef ?? ""}
          onChange={(e) => {
            setSelectedDef(e.target.value || null);
            setSelectedInstance(null);
          }}
        >
          <option value="">Select workflow…</option>
          {defs.map((d) => (
            <option key={d.name} value={d.name}>
              {d.name}
            </option>
          ))}
        </select>
        {instances.length > 0 && (
          <select
            className="rounded bg-slate-900 px-2 py-1 text-xs text-slate-300 outline-none"
            value={selectedInstance ?? ""}
            onChange={(e) => setSelectedInstance(e.target.value || null)}
          >
            <option value="">Instances…</option>
            {instances
              .filter((i) => !selectedDef || i.workflow_name === selectedDef)
              .map((i) => (
                <option key={i.id} value={i.id}>
                  {i.workflow_name} ({i.status})
                </option>
              ))}
          </select>
        )}
      </div>

      {/* Content */}
      <div className="flex-1 overflow-auto p-4">
        {steps.length === 0 ? (
          <div className="flex h-full items-center justify-center text-slate-500">
            Select a workflow to visualize
          </div>
        ) : tab === "dag" ? (
          <DagView steps={steps} />
        ) : (
          <GanttView
            steps={activeDef?.steps.map((s) => ({
              title: s.title,
              status: "Planned",
            })) ?? []}
          />
        )}
      </div>
    </div>
  );
}
