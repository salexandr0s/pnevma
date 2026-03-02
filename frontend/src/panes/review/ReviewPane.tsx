import { useEffect, useMemo, useState } from "react";
import { getReviewPack, getTaskCheckResults } from "../../hooks/useTauri";
import type { ReviewPack, Task, TaskCheckRun } from "../../lib/types";

type Props = {
  tasks: Task[];
  onApproveReview: (taskId: string, note?: string) => Promise<void>;
  onRejectReview: (taskId: string, note?: string) => Promise<void>;
  onExecuteMerge: (taskId: string) => Promise<void>;
};

export function ReviewPane({ tasks, onApproveReview, onRejectReview, onExecuteMerge }: Props) {
  const reviewTasks = useMemo(() => tasks.filter((task) => task.status === "Review"), [tasks]);
  const [selectedTaskId, setSelectedTaskId] = useState<string | undefined>(reviewTasks[0]?.id);
  const [reviewPack, setReviewPack] = useState<ReviewPack | null>(null);
  const [checkRun, setCheckRun] = useState<TaskCheckRun | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (!reviewTasks.some((task) => task.id === selectedTaskId)) {
      setSelectedTaskId(reviewTasks[0]?.id);
    }
  }, [reviewTasks, selectedTaskId]);

  useEffect(() => {
    if (!selectedTaskId) {
      setReviewPack(null);
      setCheckRun(null);
      return;
    }
    const load = async () => {
      const [pack, checks] = await Promise.all([
        getReviewPack(selectedTaskId),
        getTaskCheckResults(selectedTaskId),
      ]);
      setReviewPack(pack);
      setCheckRun(checks);
    };
    void load();
  }, [selectedTaskId]);

  return (
    <div className="grid h-full grid-cols-1 gap-3 overflow-auto xl:grid-cols-3">
      <section className="rounded-lg border border-white/10 bg-slate-900/60 p-3">
        <header className="mb-3 text-xs font-semibold uppercase tracking-wide text-slate-300">
          Review Queue ({reviewTasks.length})
        </header>
        <div className="space-y-2">
          {reviewTasks.length === 0 ? (
            <div className="rounded border border-dashed border-white/15 p-3 text-sm text-slate-400">
              No tasks in Review.
            </div>
          ) : null}
          {reviewTasks.map((task) => (
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
              <div className="mt-1 text-xs text-slate-400">{task.id.slice(0, 8)}</div>
            </button>
          ))}
        </div>
      </section>

      <section className="rounded-lg border border-white/10 bg-slate-900/60 p-3 xl:col-span-2">
        {!selectedTaskId ? (
          <div className="text-sm text-slate-400">Select a task to inspect review data.</div>
        ) : (
          <div className="space-y-3">
            <header className="flex flex-wrap items-center justify-between gap-2">
              <h2 className="text-sm font-semibold text-slate-100">Review Pack</h2>
              <div className="flex gap-2">
                <button
                  className="rounded bg-slate-700 px-2 py-1 text-xs text-slate-200 hover:bg-slate-600 disabled:opacity-50"
                  disabled={busy}
                  onClick={() => {
                    const note = prompt("Optional rejection note", "") ?? undefined;
                    setBusy(true);
                    void onRejectReview(selectedTaskId, note).finally(() => setBusy(false));
                  }}
                >
                  Reject
                </button>
                <button
                  className="rounded bg-mint-500 px-2 py-1 text-xs font-semibold text-slate-950 disabled:opacity-50"
                  disabled={busy}
                  onClick={() => {
                    const note = prompt("Optional approval note", "") ?? undefined;
                    setBusy(true);
                    void onApproveReview(selectedTaskId, note).finally(() => setBusy(false));
                  }}
                >
                  Approve
                </button>
                <button
                  className="rounded bg-amber-500 px-2 py-1 text-xs font-semibold text-slate-950 disabled:opacity-50"
                  disabled={busy}
                  onClick={() => {
                    setBusy(true);
                    void onExecuteMerge(selectedTaskId).finally(() => setBusy(false));
                  }}
                >
                  Merge
                </button>
              </div>
            </header>

            <article className="rounded border border-white/10 bg-slate-950/70 p-3">
              <div className="text-xs uppercase tracking-wide text-slate-500">Checks</div>
              {checkRun ? (
                <div className="mt-2 space-y-2">
                  <div className="text-sm text-slate-200">{checkRun.summary ?? checkRun.status}</div>
                  {checkRun.results.map((result) => (
                    <div key={result.id} className="rounded border border-white/10 p-2">
                      <div className="text-sm text-slate-100">
                        {result.passed ? "PASS" : "FAIL"} · {result.check_type}
                      </div>
                      <div className="text-xs text-slate-400">{result.description}</div>
                      {result.output ? (
                        <pre className="mt-1 overflow-auto whitespace-pre-wrap text-[11px] text-slate-500">
                          {result.output}
                        </pre>
                      ) : null}
                    </div>
                  ))}
                </div>
              ) : (
                <div className="mt-2 text-sm text-slate-400">No check run recorded yet.</div>
              )}
            </article>

            <article className="rounded border border-white/10 bg-slate-950/70 p-3">
              <div className="text-xs uppercase tracking-wide text-slate-500">Review Summary</div>
              {reviewPack ? (
                <pre className="mt-2 max-h-[260px] overflow-auto whitespace-pre-wrap text-[11px] text-slate-300">
                  {JSON.stringify(reviewPack.pack, null, 2)}
                </pre>
              ) : (
                <div className="mt-2 text-sm text-slate-400">No generated review pack found.</div>
              )}
            </article>
          </div>
        )}
      </section>
    </div>
  );
}
