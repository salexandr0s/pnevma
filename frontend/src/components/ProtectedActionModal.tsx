import { useEffect, useRef, useState } from "react";
import type { ActionRiskInfo } from "../lib/types";
import { StatusBadge } from "./ui/status-badge";

type Props = {
  risk: ActionRiskInfo | null;
  open: boolean;
  onConfirm: () => void;
  onCancel: () => void;
};

export function ProtectedActionModal({ risk, open, onConfirm, onCancel }: Props) {
  const [typed, setTyped] = useState("");
  const inputRef = useRef<HTMLInputElement>(null);
  const confirmedRef = useRef(false);

  useEffect(() => {
    if (open) {
      setTyped("");
    }
  }, [open, risk]);

  useEffect(() => {
    if (!open) {
      confirmedRef.current = false;
      return;
    }
    if (open && risk?.risk_level === "safe" && !confirmedRef.current) {
      confirmedRef.current = true;
      onConfirm();
    }
  }, [open, risk, onConfirm]);

  useEffect(() => {
    if (open && risk?.risk_level === "danger") {
      inputRef.current?.focus();
    }
  }, [open, risk]);

  useEffect(() => {
    if (!open) return;
    function handleKeyDown(e: KeyboardEvent) {
      if (e.key === "Escape") {
        onCancel();
      }
    }
    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [open, onCancel]);

  if (!open || !risk || risk.risk_level === "safe") return null;

  const phrase = risk.confirmation_phrase ?? "";
  const isDanger = risk.risk_level === "danger";
  const canConfirm = isDanger ? typed === phrase : true;

  function handleKeyDown(e: React.KeyboardEvent) {
    if (e.key === "Enter" && canConfirm) {
      onConfirm();
    }
  }

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center"
      role="dialog"
      aria-modal="true"
    >
      {/* Backdrop */}
      <div
        className="absolute inset-0 bg-slate-950/70 backdrop-blur-sm"
        onClick={onCancel}
      />

      {/* Panel */}
      <div className="relative z-10 w-full max-w-md rounded-xl border border-white/10 bg-slate-900 p-6 shadow-2xl">
        {/* Risk badge */}
        <div className="mb-4 flex items-center gap-3">
          <StatusBadge variant={isDanger ? "error" : "warning"} dot>
            {isDanger ? "Danger" : "Caution"}
          </StatusBadge>
        </div>

        <h2 className="text-base font-semibold text-slate-100">{risk.description}</h2>

        {risk.consequences.length > 0 && (
          <ul className="mt-3 space-y-1.5">
            {risk.consequences.map((c, i) => (
              <li key={i} className="flex items-start gap-2 text-sm text-slate-400">
                <span className="mt-1.5 h-1 w-1 shrink-0 rounded-full bg-slate-500" />
                {c}
              </li>
            ))}
          </ul>
        )}

        {isDanger && phrase ? (
          <div className="mt-5 space-y-2">
            <p className="text-xs text-slate-400">
              Type{" "}
              <span className="font-mono font-semibold text-slate-200">
                {phrase}
              </span>{" "}
              to confirm
            </p>
            <div className="relative">
              <input
                ref={inputRef}
                type="text"
                value={typed}
                onChange={(e) => setTyped(e.target.value)}
                onKeyDown={handleKeyDown}
                spellCheck={false}
                autoComplete="off"
                className="w-full rounded-lg border border-white/15 bg-slate-950 px-3 py-2 text-sm font-mono text-transparent caret-slate-300 outline-none focus:border-white/30"
              />
              {/* Character-by-character match overlay */}
              <div
                aria-hidden="true"
                className="pointer-events-none absolute inset-0 flex items-center px-3 py-2 font-mono text-sm"
              >
                {typed.split("").map((ch, i) => {
                  const expected = phrase[i];
                  const correct = ch === expected;
                  return (
                    <span
                      key={i}
                      className={correct ? "text-mint-400" : "text-red-400"}
                    >
                      {ch}
                    </span>
                  );
                })}
              </div>
            </div>
          </div>
        ) : (
          <p className="mt-4 text-sm text-slate-400">Are you sure you want to proceed?</p>
        )}

        <div className="mt-6 flex justify-end gap-2">
          <button
            onClick={onCancel}
            className="rounded-lg border border-white/10 bg-slate-800 px-4 py-2 text-sm text-slate-300 transition-colors duration-150 hover:bg-slate-700 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-white/20"
          >
            Cancel
          </button>
          <button
            onClick={onConfirm}
            disabled={!canConfirm}
            className={
              isDanger
                ? "rounded-lg px-4 py-2 text-sm font-semibold transition-colors duration-150 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-red-500/50 disabled:cursor-not-allowed disabled:opacity-40 bg-red-600 text-white hover:bg-red-500"
                : "rounded-lg px-4 py-2 text-sm font-semibold transition-colors duration-150 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-amber-400/50 bg-amber-500 text-slate-950 hover:bg-amber-400"
            }
          >
            Confirm
          </button>
        </div>
      </div>
    </div>
  );
}
