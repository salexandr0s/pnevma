import type { MergeQueueItem } from "../../lib/types";

type Props = {
  mergeQueue: MergeQueueItem[];
  onMove: (taskId: string, direction: "up" | "down") => Promise<void>;
  onExecuteMerge: (taskId: string) => Promise<void>;
};

export function MergeQueuePane({ mergeQueue, onMove, onExecuteMerge }: Props) {
  return (
    <div className="h-full overflow-auto rounded-lg border border-white/10 bg-slate-900/60 p-3">
      <header className="mb-3 text-xs font-semibold uppercase tracking-wide text-slate-300">
        Merge Queue ({mergeQueue.length})
      </header>
      {mergeQueue.length === 0 ? (
        <div className="rounded border border-dashed border-white/15 p-3 text-sm text-slate-400">
          No items in merge queue.
        </div>
      ) : null}
      <div className="space-y-2">
        {mergeQueue.map((item, index) => (
          <div key={item.id} className="rounded border border-white/10 bg-slate-950/70 p-2">
            <div className="flex items-center justify-between gap-2">
              <div>
                <div className="text-sm font-medium text-slate-100">
                  {index + 1}. {item.task_title}
                </div>
                <div className="text-xs text-slate-400">
                  {item.status}
                  {item.blocked_reason ? ` · ${item.blocked_reason}` : ""}
                </div>
              </div>
              <div className="flex items-center gap-2">
                <button
                  className="rounded bg-slate-700 px-2 py-1 text-xs text-slate-200 hover:bg-slate-600"
                  disabled={index === 0}
                  onClick={() => {
                    void onMove(item.task_id, "up");
                  }}
                >
                  Up
                </button>
                <button
                  className="rounded bg-slate-700 px-2 py-1 text-xs text-slate-200 hover:bg-slate-600"
                  disabled={index + 1 >= mergeQueue.length}
                  onClick={() => {
                    void onMove(item.task_id, "down");
                  }}
                >
                  Down
                </button>
                <button
                  className="rounded bg-amber-500 px-2 py-1 text-xs font-semibold text-slate-950"
                  disabled={item.status !== "Queued" && item.status !== "Blocked"}
                  onClick={() => {
                    void onExecuteMerge(item.task_id);
                  }}
                >
                  Merge
                </button>
              </div>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}
