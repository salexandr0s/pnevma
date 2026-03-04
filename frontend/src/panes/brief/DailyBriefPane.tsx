import type { DailyBrief, TaskCostEntry } from "../../lib/types";
import { Avatar } from "../../components/ui/avatar";

type Props = {
  brief?: DailyBrief;
  onRefresh: () => Promise<void>;
};

export function DailyBriefPane({ brief, onRefresh }: Props) {
  return (
    <div className="h-full overflow-auto rounded-lg border border-white/10 bg-slate-900/60 p-3">
      <header className="mb-3 flex items-center justify-between">
        <div className="text-xs font-semibold uppercase tracking-wide text-slate-300">
          Daily Brief
        </div>
        <button
          className="rounded bg-slate-700 px-2 py-1 text-xs text-slate-200 hover:bg-slate-600"
          onClick={() => {
            void onRefresh();
          }}
        >
          Refresh
        </button>
      </header>

      {!brief ? (
        <div className="rounded border border-dashed border-white/15 p-3 text-sm text-slate-400">
          No brief available yet.
        </div>
      ) : (
        <div className="space-y-3">
          <section className="grid grid-cols-2 gap-2 text-xs">
            {([
              ["Total Tasks", brief.total_tasks],
              ["Ready", brief.ready_tasks],
              ["Review", brief.review_tasks],
              ["Blocked", brief.blocked_tasks],
              ["Failed", brief.failed_tasks],
              ["Cost", `$${brief.total_cost_usd.toFixed(2)}`],
            ] as [string, string | number][]).map(([label, val]) => (
              <div key={label} className="rounded border border-white/10 bg-slate-950/70 p-2 text-slate-300">
                {label}: <span className="text-slate-100">{val}</span>
              </div>
            ))}
          </section>

          <section>
            <div className="mb-2 text-xs uppercase tracking-wide text-slate-500">
              Recommended Actions
            </div>
            <div className="space-y-1">
              {brief.recommended_actions.map((action, index) => (
                <div key={`${action}-${index}`} className="rounded border border-white/10 bg-slate-950/70 p-2 text-sm text-slate-200">
                  {action}
                </div>
              ))}
            </div>
          </section>

          <section>
            <div className="mb-2 text-xs uppercase tracking-wide text-slate-500">Recent Events</div>
            <div className="space-y-1">
              {brief.recent_events.map((event, index) => (
                <details key={`${event.timestamp}-${index}`} className="rounded border border-white/10 bg-slate-950/70 p-2">
                  <summary className="flex cursor-pointer list-none items-center gap-2 text-sm text-slate-100">
                    <Avatar name={event.kind} size="sm" />
                    <span>{event.kind} · {new Date(event.timestamp).toLocaleString()}</span>
                  </summary>
                  <div className="mt-1 text-xs text-slate-400">{event.summary}</div>
                </details>
              ))}
            </div>
          </section>

          <section>
            <div className="mb-2 text-xs uppercase tracking-wide text-slate-500">Since Last Visit</div>
            <div className="grid grid-cols-2 gap-2 text-xs">
              {([
                ["Completed", brief.tasks_completed_last_24h ?? 0],
                ["Failed", brief.tasks_failed_last_24h ?? 0],
                ["Cost (24h)", `$${(brief.cost_last_24h_usd ?? 0).toFixed(2)}`],
                ["Active Sessions", brief.active_sessions ?? 0],
              ] as [string, string | number][]).map(([label, val]) => (
                <div key={label} className="rounded border border-white/10 bg-slate-950/70 p-2 text-slate-300">
                  {label}: <span className="text-slate-100">{val}</span>
                </div>
              ))}
            </div>
          </section>

          {((brief.stale_ready_count ?? 0) > 0 || brief.longest_running_task) && (
            <section>
              <div className="mb-2 text-xs uppercase tracking-wide text-slate-500">Attention Needed</div>
              <div className="space-y-1">
                {(brief.stale_ready_count ?? 0) > 0 && (
                  <div className="rounded border border-amber-500/30 bg-amber-500/10 p-2 text-xs text-amber-300">
                    {brief.stale_ready_count ?? 0} task{(brief.stale_ready_count ?? 0) !== 1 ? "s" : ""} ready but stale
                  </div>
                )}
                {brief.longest_running_task && (
                  <div className="rounded border border-amber-500/30 bg-amber-500/10 p-2 text-xs text-amber-300">
                    Longest running: <span className="font-medium">{brief.longest_running_task}</span>
                  </div>
                )}
              </div>
            </section>
          )}

          {(brief.top_cost_tasks ?? []).length > 0 && (
            <section>
              <div className="mb-2 text-xs uppercase tracking-wide text-slate-500">Top Cost Tasks</div>
              <div className="space-y-1">
                {(brief.top_cost_tasks ?? []).slice(0, 3).map((entry: TaskCostEntry) => (
                  <div key={entry.task_id} className="flex items-center justify-between rounded border border-white/10 bg-slate-950/70 p-2 text-xs">
                    <span className="truncate text-slate-200">{entry.title}</span>
                    <span className="ml-2 shrink-0 text-slate-400">${entry.cost_usd.toFixed(2)}</span>
                  </div>
                ))}
              </div>
            </section>
          )}
        </div>
      )}
    </div>
  );
}
