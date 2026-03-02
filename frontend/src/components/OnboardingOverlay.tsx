import type { OnboardingState } from "../lib/types";

const ORDER = ["open_project", "create_task", "dispatch_task", "review_task", "merge_task"] as const;

const COPY: Record<string, { title: string; body: string }> = {
  open_project: {
    title: "Open a project",
    body: "Use the command palette to open a Pnevma project directory.",
  },
  create_task: {
    title: "Create your first task",
    body: "Draft a task from text or create one manually in the task board.",
  },
  dispatch_task: {
    title: "Dispatch a ready task",
    body: "Move one task to Ready and dispatch it to start an agent run.",
  },
  review_task: {
    title: "Review output",
    body: "Open Review pane, inspect checks and diff, then approve or reject.",
  },
  merge_task: {
    title: "Merge and capture",
    body: "Execute merge queue and capture ADR/changelog/convention updates.",
  },
};

function nextStep(step: string): string {
  const index = ORDER.indexOf(step as (typeof ORDER)[number]);
  if (index < 0 || index + 1 >= ORDER.length) {
    return step;
  }
  return ORDER[index + 1];
}

type Props = {
  state: OnboardingState | null;
  onAdvance: (step: string, completed?: boolean, dismissed?: boolean) => Promise<void>;
};

export function OnboardingOverlay({ state, onAdvance }: Props) {
  if (!state || state.dismissed || state.completed) {
    return null;
  }
  const copy = COPY[state.step] ?? COPY.open_project;
  const index = ORDER.indexOf(state.step as (typeof ORDER)[number]);
  const total = ORDER.length;
  const displayIndex = index >= 0 ? index + 1 : 1;

  return (
    <aside className="fixed bottom-4 right-4 z-40 w-[340px] rounded-xl border border-mint-400/30 bg-slate-950/95 p-4 shadow-2xl">
      <div className="text-[11px] uppercase tracking-wide text-mint-300">
        Onboarding {displayIndex}/{total}
      </div>
      <h2 className="mt-1 text-sm font-semibold text-slate-100">{copy.title}</h2>
      <p className="mt-1 text-xs text-slate-400">{copy.body}</p>
      <div className="mt-3 flex flex-wrap gap-2">
        <button
          className="rounded bg-mint-500 px-2 py-1 text-xs font-semibold text-slate-950"
          onClick={() => {
            window.dispatchEvent(new Event("pnevma:open-command-palette"));
          }}
        >
          Open Palette
        </button>
        <button
          className="rounded bg-slate-700 px-2 py-1 text-xs text-slate-100"
          onClick={() => {
            const next = nextStep(state.step);
            const completed = next === state.step;
            void onAdvance(next, completed, false);
          }}
        >
          {state.step === "merge_task" ? "Finish" : "Next"}
        </button>
        <button
          className="rounded bg-slate-800 px-2 py-1 text-xs text-slate-300"
          onClick={() => {
            void onAdvance(state.step, false, true);
          }}
        >
          Dismiss
        </button>
      </div>
    </aside>
  );
}
