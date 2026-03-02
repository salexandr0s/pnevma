import type { DailyBrief } from "../../lib/types";

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
            <div className="rounded border border-white/10 bg-slate-950/70 p-2 text-slate-300">
              Total Tasks: <span className="text-slate-100">{brief.total_tasks}</span>
            </div>
            <div className="rounded border border-white/10 bg-slate-950/70 p-2 text-slate-300">
              Ready: <span className="text-slate-100">{brief.ready_tasks}</span>
            </div>
            <div className="rounded border border-white/10 bg-slate-950/70 p-2 text-slate-300">
              Review: <span className="text-slate-100">{brief.review_tasks}</span>
            </div>
            <div className="rounded border border-white/10 bg-slate-950/70 p-2 text-slate-300">
              Blocked: <span className="text-slate-100">{brief.blocked_tasks}</span>
            </div>
            <div className="rounded border border-white/10 bg-slate-950/70 p-2 text-slate-300">
              Failed: <span className="text-slate-100">{brief.failed_tasks}</span>
            </div>
            <div className="rounded border border-white/10 bg-slate-950/70 p-2 text-slate-300">
              Cost: <span className="text-slate-100">${brief.total_cost_usd.toFixed(2)}</span>
            </div>
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
                  <summary className="cursor-pointer list-none text-sm text-slate-100">
                    {event.kind} · {new Date(event.timestamp).toLocaleString()}
                  </summary>
                  <div className="mt-1 text-xs text-slate-400">{event.summary}</div>
                </details>
              ))}
            </div>
          </section>
        </div>
      )}
    </div>
  );
}
