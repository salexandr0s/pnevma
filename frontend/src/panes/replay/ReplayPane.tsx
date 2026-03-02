import { useEffect, useMemo, useState } from "react";
import {
  getSessionRecoveryOptions,
  getSessionTimeline,
  recoverSession,
} from "../../hooks/useTauri";
import type { RecoveryOption, Session, TimelineEvent } from "../../lib/types";
import { RecoveryPanel } from "../../components/RecoveryPanel";

type Props = {
  sessions: Session[];
};

export function ReplayPane({ sessions }: Props) {
  const [selectedSessionId, setSelectedSessionId] = useState<string | undefined>(sessions[0]?.id);
  const [timeline, setTimeline] = useState<TimelineEvent[]>([]);
  const [recoveryOptions, setRecoveryOptions] = useState<RecoveryOption[]>([]);
  const [filter, setFilter] = useState("");
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (!sessions.some((session) => session.id === selectedSessionId)) {
      setSelectedSessionId(sessions[0]?.id);
    }
  }, [sessions, selectedSessionId]);

  useEffect(() => {
    if (!selectedSessionId) {
      setTimeline([]);
      setRecoveryOptions([]);
      return;
    }
    const load = async () => {
      const [timelineRows, recoveryRows] = await Promise.all([
        getSessionTimeline(selectedSessionId, 500),
        getSessionRecoveryOptions(selectedSessionId),
      ]);
      setTimeline(timelineRows);
      setRecoveryOptions(recoveryRows);
    };
    void load();
  }, [selectedSessionId]);

  const filteredTimeline = useMemo(() => {
    const q = filter.trim().toLowerCase();
    if (!q) {
      return timeline;
    }
    return timeline.filter((item) => {
      return (
        item.kind.toLowerCase().includes(q) ||
        item.summary.toLowerCase().includes(q) ||
        JSON.stringify(item.payload).toLowerCase().includes(q)
      );
    });
  }, [filter, timeline]);

  const runRecovery = async (actionId: string) => {
    if (!selectedSessionId) {
      return;
    }
    setBusy(true);
    try {
      await recoverSession(selectedSessionId, actionId);
      const [timelineRows, recoveryRows] = await Promise.all([
        getSessionTimeline(selectedSessionId, 500),
        getSessionRecoveryOptions(selectedSessionId),
      ]);
      setTimeline(timelineRows);
      setRecoveryOptions(recoveryRows);
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="grid h-full grid-cols-1 gap-3 overflow-auto xl:grid-cols-4">
      <section className="rounded-lg border border-white/10 bg-slate-900/60 p-3 xl:col-span-1">
        <header className="mb-2 text-xs font-semibold uppercase tracking-wide text-slate-300">
          Sessions
        </header>
        <div className="space-y-2">
          {sessions.length === 0 ? (
            <div className="rounded border border-dashed border-white/15 p-2 text-xs text-slate-400">
              No sessions.
            </div>
          ) : null}
          {sessions.map((session) => (
            <button
              key={session.id}
              className={`w-full rounded border px-2 py-2 text-left ${
                session.id === selectedSessionId
                  ? "border-mint-400/70 bg-mint-400/10"
                  : "border-white/10 bg-slate-950/70"
              }`}
              onClick={() => setSelectedSessionId(session.id)}
            >
              <div className="text-sm font-medium text-slate-100">{session.name}</div>
              <div className="mt-1 text-xs text-slate-400">{session.status}</div>
            </button>
          ))}
        </div>
      </section>

      <section className="rounded-lg border border-white/10 bg-slate-900/60 p-3 xl:col-span-2">
        <header className="mb-2 flex items-center justify-between gap-2">
          <div className="text-xs font-semibold uppercase tracking-wide text-slate-300">
            Timeline
          </div>
          <input
            className="w-44 rounded border border-white/15 bg-slate-950/70 px-2 py-1 text-xs text-slate-200"
            placeholder="Filter"
            value={filter}
            onChange={(event) => setFilter(event.target.value)}
          />
        </header>
        <div className="space-y-2">
          {filteredTimeline.length === 0 ? (
            <div className="rounded border border-dashed border-white/15 p-2 text-xs text-slate-400">
              No timeline events.
            </div>
          ) : null}
          {filteredTimeline.map((item, index) => (
            <details key={`${item.timestamp}-${index}`} className="rounded border border-white/10 p-2">
              <summary className="cursor-pointer list-none text-sm text-slate-100">
                <span className="font-medium">{item.kind}</span>
                <span className="ml-2 text-xs text-slate-400">
                  {new Date(item.timestamp).toLocaleString()}
                </span>
                <div className="mt-1 text-xs text-slate-400">{item.summary}</div>
              </summary>
              <pre className="mt-2 overflow-auto whitespace-pre-wrap text-[11px] text-slate-300">
                {JSON.stringify(item.payload, null, 2)}
              </pre>
            </details>
          ))}
        </div>
      </section>

      <div className="xl:col-span-1">
        <RecoveryPanel options={recoveryOptions} busy={busy} onRun={runRecovery} />
      </div>
    </div>
  );
}
