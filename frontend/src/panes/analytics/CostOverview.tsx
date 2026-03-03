import type { UsageDailyTrend } from "../../lib/types";
import { BarChart } from "./charts/BarChart";

type Props = {
  trend: UsageDailyTrend[];
};

export function CostOverview({ trend }: Props) {
  const total = trend.reduce((sum, d) => sum + d.estimated_usd, 0);
  const barData = trend.slice(-14).map((d) => ({
    label: d.date.slice(5),
    value: d.estimated_usd,
  }));

  return (
    <div className="rounded-md border border-white/10 bg-slate-950/80 p-4">
      <h3 className="text-sm font-semibold text-slate-300">Cost Overview</h3>
      <div className="mt-2 text-2xl font-bold text-mint-400">${total.toFixed(2)}</div>
      <div className="text-xs text-slate-500">Total spend ({trend.length}d)</div>
      <div className="mt-3">
        <BarChart data={barData} width={360} height={120} />
      </div>
    </div>
  );
}
