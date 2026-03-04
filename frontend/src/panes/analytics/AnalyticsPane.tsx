import { useEffect, useState, useCallback } from "react";
import {
  getUsageBreakdown,
  getUsageByModel,
  getUsageDailyTrend,
  listErrorSignatures,
} from "../../hooks/useTauri";
import type { UsageBreakdown, UsageByModel, UsageDailyTrend, ErrorSignature } from "../../lib/types";
import { CostOverview } from "./CostOverview";
import { ModelComparison } from "./ModelComparison";
import { ErrorHotspots } from "./ErrorHotspots";

type TimeRange = 1 | 7 | 30 | 365;

export function AnalyticsPane() {
  const [range, setRange] = useState<TimeRange>(30);
  const [breakdown, setBreakdown] = useState<UsageBreakdown[]>([]);
  const [models, setModels] = useState<UsageByModel[]>([]);
  const [trend, setTrend] = useState<UsageDailyTrend[]>([]);
  const [errors, setErrors] = useState<ErrorSignature[]>([]);

  const refresh = useCallback(() => {
    void getUsageBreakdown(range).then(setBreakdown);
    void getUsageByModel().then(setModels);
    void getUsageDailyTrend(range).then(setTrend);
    void listErrorSignatures(50).then(setErrors);
  }, [range]);

  useEffect(() => {
    refresh();
    const timer = setInterval(refresh, 30_000);
    return () => clearInterval(timer);
  }, [refresh]);

  const ranges: { label: string; value: TimeRange }[] = [
    { label: "Today", value: 1 },
    { label: "7d", value: 7 },
    { label: "30d", value: 30 },
    { label: "All", value: 365 },
  ];

  const totalCost = breakdown.reduce((s, b) => s + b.estimated_usd, 0);
  const totalTokensIn = breakdown.reduce((s, b) => s + b.tokens_in, 0);
  const totalTokensOut = breakdown.reduce((s, b) => s + b.tokens_out, 0);

  return (
    <div className="flex h-full flex-col">
      {/* Header */}
      <div className="flex items-center justify-between border-b border-white/10 px-3 py-2">
        <h2 className="text-sm font-semibold">Analytics</h2>
        <div className="flex gap-1">
          {ranges.map((r) => (
            <button
              key={r.value}
              className={`rounded px-2 py-1 text-xs ${
                range === r.value ? "bg-mint-500/20 text-mint-400" : "text-slate-500 hover:text-slate-300"
              }`}
              onClick={() => setRange(r.value)}
            >
              {r.label}
            </button>
          ))}
        </div>
      </div>

      {/* Content */}
      <div className="flex-1 overflow-auto p-4 space-y-4">
        {/* Stat cards */}
        <div className="grid grid-cols-3 gap-3">
          {([
            { label: "Total Cost", value: `$${totalCost.toFixed(2)}`, accent: true },
            { label: "Tokens In", value: totalTokensIn.toLocaleString(), accent: false },
            { label: "Tokens Out", value: totalTokensOut.toLocaleString(), accent: false },
          ] as const).map(({ label, value, accent }) => (
            <div key={label} className="rounded-md border border-white/10 bg-slate-950/80 p-3">
              <div className="text-xs text-slate-500">{label}</div>
              <div className={`mt-1 text-lg font-bold ${accent ? "text-mint-400" : "text-slate-200"}`}>{value}</div>
            </div>
          ))}
        </div>

        <CostOverview trend={trend} />
        <ModelComparison models={models} />
        <ErrorHotspots signatures={errors} />
      </div>
    </div>
  );
}
