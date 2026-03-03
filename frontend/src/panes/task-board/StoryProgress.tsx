import type { StoryProgress as StoryProgressType } from "../../lib/types";

type Props = {
  progress: StoryProgressType;
};

export function StoryProgress({ progress }: Props) {
  if (progress.total === 0) return null;
  const pct = Math.round((progress.completed / progress.total) * 100);
  return (
    <div className="mt-1">
      <div className="flex items-center justify-between text-[10px] text-slate-500">
        <span>{progress.completed}/{progress.total} steps</span>
        <span>{pct}%</span>
      </div>
      <div className="mt-0.5 h-1 w-full overflow-hidden rounded-full bg-slate-800">
        <div
          className="h-full rounded-full bg-mint-500 transition-all duration-300"
          style={{ width: `${pct}%` }}
        />
      </div>
    </div>
  );
}
