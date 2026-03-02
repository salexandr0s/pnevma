import type { EnvironmentReadiness } from "../lib/types";

type Props = {
  path: string;
  readiness: EnvironmentReadiness | null;
  busy: boolean;
  notice?: string;
  onPathChange: (path: string) => void;
  onRefresh: () => Promise<void>;
  onInitGlobalConfig: () => Promise<void>;
  onInitProject: () => Promise<void>;
  onOpenProject: () => Promise<void>;
};

function statusLabel(value: boolean): string {
  return value ? "ready" : "missing";
}

export function FirstLaunchPanel({
  path,
  readiness,
  busy,
  notice,
  onPathChange,
  onRefresh,
  onInitGlobalConfig,
  onInitProject,
  onOpenProject,
}: Props) {
  return (
    <section className="m-3 rounded-xl border border-white/15 bg-slate-950/80 p-4">
      <header className="flex items-start justify-between gap-3">
        <div>
          <h2 className="text-sm font-semibold text-slate-100">First Launch Setup</h2>
          <p className="mt-1 text-xs text-slate-400">
            Validate prerequisites, initialize config/scaffold, then open a project.
          </p>
        </div>
        <button
          className="rounded bg-slate-700 px-2 py-1 text-xs text-slate-100 disabled:opacity-60"
          disabled={busy}
          onClick={() => {
            void onRefresh();
          }}
        >
          Refresh
        </button>
      </header>

      <div className="mt-3 grid gap-3 lg:grid-cols-[1.2fr_1fr]">
        <div>
          <label className="text-xs text-slate-400">Project Path</label>
          <input
            className="mt-1 w-full rounded border border-white/20 bg-slate-900 px-2 py-2 text-sm text-slate-100 outline-none focus:border-mint-400"
            value={path}
            onChange={(event) => onPathChange(event.target.value)}
            placeholder="/path/to/project"
          />
          <div className="mt-2 flex flex-wrap gap-2">
            <button
              className="rounded bg-slate-700 px-2 py-1 text-xs text-slate-100 disabled:opacity-60"
              disabled={busy}
              onClick={() => {
                void onInitGlobalConfig();
              }}
            >
              Initialize Global Config
            </button>
            <button
              className="rounded bg-slate-700 px-2 py-1 text-xs text-slate-100 disabled:opacity-60"
              disabled={busy}
              onClick={() => {
                void onInitProject();
              }}
            >
              Initialize Project Scaffold
            </button>
            <button
              className="rounded bg-mint-500 px-2 py-1 text-xs font-semibold text-slate-950 disabled:opacity-60"
              disabled={busy}
              onClick={() => {
                void onOpenProject();
              }}
            >
              Open Project
            </button>
          </div>
          {notice ? <p className="mt-2 text-xs text-slate-300">{notice}</p> : null}
        </div>

        <div className="rounded border border-white/10 bg-slate-900/70 p-3">
          <div className="text-xs font-semibold text-slate-200">Readiness</div>
          <ul className="mt-2 space-y-1 text-xs text-slate-300">
            <li>git: {statusLabel(readiness?.git_available ?? false)}</li>
            <li>global config: {statusLabel(readiness?.global_config_exists ?? false)}</li>
            <li>project scaffold: {statusLabel(readiness?.project_initialized ?? false)}</li>
            <li>
              adapters:{" "}
              {readiness && readiness.detected_adapters.length > 0
                ? readiness.detected_adapters.join(", ")
                : "none detected"}
            </li>
          </ul>
          {readiness?.missing_steps && readiness.missing_steps.length > 0 ? (
            <div className="mt-2 rounded border border-amber-300/30 bg-amber-400/10 p-2 text-[11px] text-amber-100">
              pending: {readiness.missing_steps.join(", ")}
            </div>
          ) : (
            <div className="mt-2 rounded border border-mint-400/30 bg-mint-500/10 p-2 text-[11px] text-mint-200">
              environment looks ready
            </div>
          )}
        </div>
      </div>
    </section>
  );
}
