import { useEffect, useMemo, useState } from "react";
import { getTaskDiff } from "../../hooks/useTauri";
import type { Task, TaskDiff } from "../../lib/types";
import { StatusBadge, taskStatusVariant } from "../../components/ui/status-badge";

type Props = {
  tasks: Task[];
};

export function DiffPane({ tasks }: Props) {
  const reviewableTasks = useMemo(
    () => tasks.filter((task) => task.status === "Review" || task.status === "InProgress"),
    [tasks]
  );
  const [selectedTaskId, setSelectedTaskId] = useState<string | undefined>(reviewableTasks[0]?.id);
  const [viewMode, setViewMode] = useState<"inline" | "side-by-side">("inline");
  const [diff, setDiff] = useState<TaskDiff | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!reviewableTasks.some((task) => task.id === selectedTaskId)) {
      setSelectedTaskId(reviewableTasks[0]?.id);
    }
  }, [reviewableTasks, selectedTaskId]);

  useEffect(() => {
    if (!selectedTaskId) {
      setDiff(null);
      setError(null);
      return;
    }
    void getTaskDiff(selectedTaskId)
      .then((value) => {
        setDiff(value);
        setError(null);
      })
      .catch((err) => {
        const message = err instanceof Error ? err.message : String(err);
        setError(message);
      });
  }, [selectedTaskId]);

  return (
    <div className="grid h-full grid-cols-1 gap-3 overflow-auto xl:grid-cols-4">
      <section className="rounded-lg border border-white/10 bg-slate-900/60 p-3 xl:col-span-1">
        <header className="mb-2 text-xs font-semibold uppercase tracking-wide text-slate-300">
          Tasks
        </header>
        <div className="space-y-2">
          {reviewableTasks.length === 0 ? (
            <div className="rounded border border-dashed border-white/15 p-2 text-xs text-slate-400">
              No reviewable tasks.
            </div>
          ) : null}
          {reviewableTasks.map((task) => (
            <button
              key={task.id}
              onClick={() => setSelectedTaskId(task.id)}
              className={`w-full rounded border px-2 py-2 text-left ${
                task.id === selectedTaskId
                  ? "border-mint-400/70 bg-mint-400/10"
                  : "border-white/10 bg-slate-950/70"
              }`}
            >
              <div className="text-sm font-medium text-slate-100">{task.title}</div>
              <div className="mt-1">
                <StatusBadge variant={taskStatusVariant(task.status)}>{task.status}</StatusBadge>
              </div>
            </button>
          ))}
        </div>
      </section>

      <section className="rounded-lg border border-white/10 bg-slate-900/60 p-3 xl:col-span-3">
        <header className="mb-2 flex items-center justify-between gap-2">
          <h2 className="text-sm font-semibold text-slate-100">Diff</h2>
          <div className="flex gap-2">
            <button
              className={`rounded px-2 py-1 text-xs ${
                viewMode === "inline" ? "bg-mint-500 text-slate-950" : "bg-slate-700 text-slate-200"
              }`}
              onClick={() => setViewMode("inline")}
            >
              Inline
            </button>
            <button
              className={`rounded px-2 py-1 text-xs ${
                viewMode === "side-by-side"
                  ? "bg-mint-500 text-slate-950"
                  : "bg-slate-700 text-slate-200"
              }`}
              onClick={() => setViewMode("side-by-side")}
            >
              Side-by-side
            </button>
          </div>
        </header>

        {error ? <div className="text-sm text-amber-300">{error}</div> : null}
        {!selectedTaskId ? (
          <div className="text-sm text-slate-400">Select a task to inspect diff.</div>
        ) : null}
        {selectedTaskId && !diff ? (
          <div className="text-sm text-slate-400">No diff available yet for selected task.</div>
        ) : null}
        {diff ? (
          <div className="space-y-3">
            <div className="text-xs text-slate-500">{diff.diff_path}</div>
            {diff.files.map((file) => (
              <article key={file.path} className="rounded border border-white/10 bg-slate-950/70 p-2">
                <header className="mb-2 text-xs font-semibold text-slate-300">{file.path}</header>
                <div className="space-y-2">
                  {file.hunks.map((hunk, index) => (
                    <div key={`${file.path}-${hunk.header}-${index}`} className="rounded border border-white/10">
                      <div className="border-b border-white/10 px-2 py-1 text-[11px] text-slate-400">
                        {hunk.header}
                      </div>
                      {viewMode === "inline" ? (
                        <pre className="overflow-auto whitespace-pre-wrap px-2 py-2 text-[11px] text-slate-200">
                          {hunk.lines.join("\n")}
                        </pre>
                      ) : (
                        <div className="grid grid-cols-2 gap-2 p-2 text-[11px]">
                          <pre className="overflow-auto whitespace-pre-wrap text-rose-200">
                            {hunk.lines
                              .filter((line) => line.startsWith("-") || line.startsWith(" "))
                              .join("\n")}
                          </pre>
                          <pre className="overflow-auto whitespace-pre-wrap text-emerald-200">
                            {hunk.lines
                              .filter((line) => line.startsWith("+") || line.startsWith(" "))
                              .join("\n")}
                          </pre>
                        </div>
                      )}
                    </div>
                  ))}
                </div>
              </article>
            ))}
          </div>
        ) : null}
      </section>
    </div>
  );
}
