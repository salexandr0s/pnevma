import type { ErrorSignature } from "../../lib/types";

type Props = {
  signatures: ErrorSignature[];
};

export function ErrorHotspots({ signatures }: Props) {
  const top5 = signatures.slice(0, 5);

  return (
    <div className="rounded-md border border-white/10 bg-slate-950/80 p-4">
      <h3 className="text-sm font-semibold text-slate-300">Error Hotspots</h3>
      {top5.length === 0 ? (
        <p className="mt-2 text-xs text-slate-500">No errors recorded</p>
      ) : (
        <div className="mt-2 space-y-2">
          {top5.map((sig) => (
            <div key={sig.id} className="rounded border border-white/5 p-2">
              <div className="flex items-center justify-between">
                <span className="text-xs font-medium text-red-400">{sig.category}</span>
                <span className="text-xs text-slate-500">&times;{sig.total_count}</span>
              </div>
              <p className="mt-1 line-clamp-2 text-[11px] text-slate-400">{sig.canonical_message}</p>
              {sig.remediation_hint && (
                <p className="mt-1 text-[10px] text-slate-500">Hint: {sig.remediation_hint}</p>
              )}
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
