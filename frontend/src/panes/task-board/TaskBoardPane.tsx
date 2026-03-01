import type { Task } from "../../lib/types";

type Props = {
  tasks: Task[];
  onDispatch: (taskId: string) => Promise<void>;
};

const COLUMNS = ["Planned", "Ready", "InProgress", "Review", "Done", "Failed", "Blocked"];

export function TaskBoardPane({ tasks, onDispatch }: Props) {
  return (
    <div className="grid h-full grid-cols-2 gap-3 overflow-auto xl:grid-cols-4 2xl:grid-cols-7">
      {COLUMNS.map((status) => {
        const items = tasks.filter((task) => task.status === status);
        return (
          <section key={status} className="rounded-lg border border-white/10 bg-slate-900/70 p-3">
            <header className="mb-3 text-xs font-semibold uppercase tracking-wide text-slate-300">
              {status} ({items.length})
            </header>
            <div className="space-y-2">
              {items.map((task) => (
                <article
                  key={task.id}
                  tabIndex={0}
                  onKeyDown={(event) => {
                    if ((event.key === "d" || event.key === "Enter") && status === "Ready") {
                      event.preventDefault();
                      void onDispatch(task.id);
                    }
                  }}
                  className="rounded-md border border-white/10 bg-slate-950/80 p-2 outline-none focus:border-mint-400/70"
                >
                  <div className="text-sm font-medium">{task.title}</div>
                  <div className="mt-1 line-clamp-3 text-xs text-slate-400">{task.goal}</div>
                  <div className="mt-2 flex items-center justify-between text-xs text-slate-500">
                    <span>{task.priority}</span>
                    {status === "Ready" ? (
                      <button
                        className="rounded bg-mint-500 px-2 py-1 text-[11px] font-semibold text-slate-950"
                        onClick={() => onDispatch(task.id)}
                      >
                        Dispatch
                      </button>
                    ) : null}
                  </div>
                  <div className="mt-2 flex items-center justify-between text-[11px] text-slate-500">
                    <span>
                      Deps: {task.dependencies.length}
                      {task.queued_position ? ` · Queue #${task.queued_position}` : ""}
                    </span>
                    <span>{typeof task.cost_usd === "number" ? `$${task.cost_usd.toFixed(2)}` : "No cost"}</span>
                  </div>
                </article>
              ))}
            </div>
          </section>
        );
      })}
    </div>
  );
}
