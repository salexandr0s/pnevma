import type { RecoveryOption } from "../lib/types";

type Props = {
  options: RecoveryOption[];
  busy: boolean;
  onRun: (actionId: string) => Promise<void>;
};

export function RecoveryPanel({ options, busy, onRun }: Props) {
  return (
    <section className="rounded-lg border border-white/10 bg-slate-900/60 p-3">
      <header className="mb-2 text-xs font-semibold uppercase tracking-wide text-slate-300">
        Recovery
      </header>
      <div className="space-y-2">
        {options.length === 0 ? (
          <div className="rounded border border-dashed border-white/15 p-2 text-xs text-slate-400">
            No recovery actions available.
          </div>
        ) : null}
        {options.map((option) => (
          <button
            key={option.id}
            className="w-full rounded border border-white/10 bg-slate-950/70 px-2 py-2 text-left disabled:opacity-50"
            disabled={busy || !option.enabled}
            onClick={() => {
              void onRun(option.id);
            }}
          >
            <div className="text-sm font-medium text-slate-100">{option.label}</div>
            <div className="mt-1 text-xs text-slate-400">{option.description}</div>
          </button>
        ))}
      </div>
    </section>
  );
}
