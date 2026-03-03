import { useState } from "react";
import type { EnvironmentReadiness, RecentProject } from "../lib/types";

type Props = {
  path: string;
  readiness: EnvironmentReadiness | null;
  busy: boolean;
  notice?: string;
  recentProjects: RecentProject[];
  onPathChange: (path: string) => void;
  onRefresh: () => Promise<void>;
  onInitGlobalConfig: () => Promise<void>;
  onInitProject: () => Promise<void>;
  onOpenProject: () => Promise<void>;
  onBrowse: () => Promise<void>;
  onSelectRecent: (path: string) => Promise<void>;
};

function statusLabel(value: boolean): string {
  return value ? "ready" : "missing";
}

function FolderIcon() {
  return (
    <svg
      width="16"
      height="16"
      viewBox="0 0 16 16"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
      className="shrink-0"
    >
      <path
        d="M1.5 3A1.5 1.5 0 0 1 3 1.5h3.19a1.5 1.5 0 0 1 1.06.44L8.56 3.25a.5.5 0 0 0 .35.15H13a1.5 1.5 0 0 1 1.5 1.5v7.6a1.5 1.5 0 0 1-1.5 1.5H3A1.5 1.5 0 0 1 1.5 12.5V3Z"
        fill="currentColor"
        opacity="0.5"
      />
    </svg>
  );
}

function ChevronIcon({ open }: { open: boolean }) {
  return (
    <svg
      width="12"
      height="12"
      viewBox="0 0 12 12"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
      className={`transition-transform duration-150 ${open ? "rotate-90" : ""}`}
    >
      <path d="M4 2.5L7.5 6 4 9.5" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

export function FirstLaunchPanel({
  path,
  readiness,
  busy,
  notice,
  recentProjects,
  onPathChange,
  onRefresh,
  onInitGlobalConfig,
  onInitProject,
  onOpenProject,
  onBrowse,
  onSelectRecent,
}: Props) {
  const [statusOpen, setStatusOpen] = useState(false);
  const visibleRecents = recentProjects.slice(0, 5);

  return (
    <div className="max-w-xl w-full space-y-5">
      {/* Header */}
      <div>
        <h2 className="text-lg font-semibold tracking-tight text-slate-100">Pnevma</h2>
        <p className="mt-0.5 text-sm text-slate-400">Terminal-first execution workspace</p>
      </div>

      {/* Recent Projects */}
      {visibleRecents.length > 0 ? (
        <div className="space-y-1.5">
          <h3 className="text-xs font-medium uppercase tracking-wide text-slate-500">
            Recent Projects
          </h3>
          <div className="space-y-1">
            {visibleRecents.map((project) => (
              <button
                key={project.path}
                disabled={busy}
                onClick={() => { void onSelectRecent(project.path); }}
                className="group flex w-full items-center gap-3 rounded-lg border border-transparent px-3 py-2.5 text-left transition-colors duration-150 hover:border-white/10 hover:bg-white/[0.04] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-mint-400/60 disabled:opacity-50"
              >
                <span className="text-slate-500 transition-colors duration-150 group-hover:text-mint-400">
                  <FolderIcon />
                </span>
                <div className="min-w-0 flex-1">
                  <div className="truncate text-sm font-medium text-slate-200">
                    {project.name}
                  </div>
                  <div className="truncate text-xs text-slate-500">
                    {project.path}
                  </div>
                </div>
              </button>
            ))}
          </div>
        </div>
      ) : (
        <p className="text-sm text-slate-500">
          Browse for a project folder or type a path below
        </p>
      )}

      {/* Open Project */}
      <div className="space-y-3">
        <h3 className="text-xs font-medium uppercase tracking-wide text-slate-500">
          Open Project
        </h3>
        <div className="flex gap-0">
          <input
            className="min-w-0 flex-1 rounded-l-lg border border-white/15 border-r-0 bg-slate-900/80 px-3 py-2 text-sm text-slate-100 placeholder-slate-600 outline-none transition-colors duration-150 focus:border-mint-400/50"
            value={path}
            onChange={(e) => onPathChange(e.target.value)}
            placeholder="/path/to/project"
          />
          <button
            disabled={busy}
            onClick={() => { void onBrowse(); }}
            className="rounded-r-lg border border-white/15 bg-slate-800 px-3 py-2 text-sm text-slate-300 transition-colors duration-150 hover:bg-slate-700 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-mint-400/60 disabled:opacity-50"
          >
            Browse
          </button>
        </div>

        <div className="flex flex-wrap gap-2">
          <button
            disabled={busy}
            onClick={() => { void onInitGlobalConfig(); }}
            className="rounded-lg border border-white/10 bg-slate-800/80 px-3 py-1.5 text-xs text-slate-300 transition-colors duration-150 hover:bg-slate-700 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-mint-400/60 disabled:opacity-50"
          >
            Init Config
          </button>
          <button
            disabled={busy}
            onClick={() => { void onInitProject(); }}
            className="rounded-lg border border-white/10 bg-slate-800/80 px-3 py-1.5 text-xs text-slate-300 transition-colors duration-150 hover:bg-slate-700 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-mint-400/60 disabled:opacity-50"
          >
            Init Scaffold
          </button>
          <button
            disabled={busy}
            onClick={() => { void onOpenProject(); }}
            className="rounded-lg bg-mint-500 px-4 py-1.5 text-xs font-semibold text-slate-950 transition-colors duration-150 hover:bg-mint-400 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-mint-400/60 disabled:opacity-60"
          >
            Open
          </button>
        </div>

        {notice ? (
          <p className="text-xs text-slate-400">{notice}</p>
        ) : null}
      </div>

      {/* Environment Status (collapsible) */}
      <div>
        <button
          onClick={() => setStatusOpen((prev) => !prev)}
          className="flex w-full items-center gap-2 py-1 text-left text-xs text-slate-500 transition-colors duration-150 hover:text-slate-400 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-mint-400/60 rounded"
        >
          <ChevronIcon open={statusOpen} />
          <span>Environment Status</span>
          <button
            onClick={(e) => {
              e.stopPropagation();
              void onRefresh();
            }}
            disabled={busy}
            className="ml-auto text-[10px] text-slate-600 transition-colors duration-150 hover:text-slate-400 disabled:opacity-50"
          >
            Refresh
          </button>
        </button>

        {statusOpen ? (
          <div className="mt-2 rounded-lg border border-white/10 bg-slate-900/60 p-3 space-y-1.5">
            <ul className="space-y-1 text-xs text-slate-400">
              <li className="flex justify-between">
                <span>git</span>
                <span className={readiness?.git_available ? "text-mint-400" : "text-amber-400"}>
                  {statusLabel(readiness?.git_available ?? false)}
                </span>
              </li>
              <li className="flex justify-between">
                <span>global config</span>
                <span className={readiness?.global_config_exists ? "text-mint-400" : "text-amber-400"}>
                  {statusLabel(readiness?.global_config_exists ?? false)}
                </span>
              </li>
              <li className="flex justify-between">
                <span>project scaffold</span>
                <span className={readiness?.project_initialized ? "text-mint-400" : "text-amber-400"}>
                  {statusLabel(readiness?.project_initialized ?? false)}
                </span>
              </li>
              <li className="flex justify-between">
                <span>adapters</span>
                <span className="text-slate-300">
                  {readiness && readiness.detected_adapters.length > 0
                    ? readiness.detected_adapters.join(", ")
                    : "none detected"}
                </span>
              </li>
            </ul>
            {readiness?.missing_steps && readiness.missing_steps.length > 0 ? (
              <div className="rounded border border-amber-300/20 bg-amber-400/5 px-2.5 py-1.5 text-[11px] text-amber-200/80">
                pending: {readiness.missing_steps.join(", ")}
              </div>
            ) : (
              <div className="rounded border border-mint-400/20 bg-mint-500/5 px-2.5 py-1.5 text-[11px] text-mint-300/80">
                environment looks ready
              </div>
            )}
          </div>
        ) : null}
      </div>
    </div>
  );
}
