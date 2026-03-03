import type { UsageByModel } from "../../lib/types";

type Props = {
  models: UsageByModel[];
};

export function ModelComparison({ models }: Props) {
  const sorted = [...models].sort((a, b) => b.estimated_usd - a.estimated_usd);

  return (
    <div className="rounded-md border border-white/10 bg-slate-950/80 p-4">
      <h3 className="text-sm font-semibold text-slate-300">Model Comparison</h3>
      <table className="mt-2 w-full text-xs">
        <thead>
          <tr className="text-slate-500">
            <th className="text-left py-1">Model</th>
            <th className="text-right py-1">Tokens In</th>
            <th className="text-right py-1">Tokens Out</th>
            <th className="text-right py-1">Cost</th>
          </tr>
        </thead>
        <tbody>
          {sorted.map((m, i) => (
            <tr key={i} className="border-t border-white/5 text-slate-400">
              <td className="py-1">{m.model || m.provider}</td>
              <td className="text-right py-1">{m.tokens_in.toLocaleString()}</td>
              <td className="text-right py-1">{m.tokens_out.toLocaleString()}</td>
              <td className="text-right py-1 text-mint-400">${m.estimated_usd.toFixed(4)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
