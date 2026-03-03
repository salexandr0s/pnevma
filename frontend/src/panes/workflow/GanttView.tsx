type GanttStep = {
  title: string;
  status: string;
  startedAt?: string | null;
  completedAt?: string | null;
};

type Props = {
  steps: GanttStep[];
};

export function GanttView({ steps }: Props) {
  const now = Date.now();
  const times = steps
    .filter((s) => s.startedAt)
    .map((s) => new Date(s.startedAt!).getTime());
  const minTime = times.length > 0 ? Math.min(...times) : now;
  const maxTime = Math.max(now, ...times.map((_, i) => {
    const s = steps.find((step) => step.startedAt && new Date(step.startedAt).getTime() === times[i]);
    return s?.completedAt ? new Date(s.completedAt).getTime() : now;
  }));
  const range = maxTime - minTime || 1;

  const STEP_STATUS_COLORS: Record<string, string> = {
    InProgress: "bg-blue-500",
    Done: "bg-green-500",
    Failed: "bg-red-500",
    Review: "bg-purple-500",
    default: "bg-slate-600",
  };

  return (
    <div className="space-y-1 p-4">
      {steps.map((step, i) => {
        if (!step.startedAt) {
          return (
            <div key={i} className="flex items-center gap-2 text-xs text-slate-500">
              <span className="w-32 truncate">{step.title}</span>
              <span className="italic">not started</span>
            </div>
          );
        }
        const start = new Date(step.startedAt).getTime();
        const end = step.completedAt ? new Date(step.completedAt).getTime() : now;
        const left = ((start - minTime) / range) * 100;
        const width = Math.max(((end - start) / range) * 100, 2);
        const colorClass = STEP_STATUS_COLORS[step.status] ?? STEP_STATUS_COLORS.default;

        return (
          <div key={i} className="flex items-center gap-2 text-xs">
            <span className="w-32 truncate text-slate-400">{step.title}</span>
            <div className="relative h-4 flex-1 rounded bg-slate-900">
              <div
                className={`absolute h-full rounded ${colorClass}`}
                style={{ left: `${left}%`, width: `${width}%` }}
              />
            </div>
          </div>
        );
      })}
    </div>
  );
}
