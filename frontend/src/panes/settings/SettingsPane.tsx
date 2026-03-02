import { useEffect, useMemo, useState } from "react";
import {
  clearTelemetry,
  exportTelemetryBundle,
  getTelemetryStatus,
  listKeybindings,
  partnerMetricsReport,
  resetKeybindings,
  resetOnboarding,
  setKeybinding,
  setTelemetryOptIn,
  submitFeedback,
} from "../../hooks/useTauri";
import type { Keybinding, PartnerMetricsReport, TelemetryStatus } from "../../lib/types";

type StatusMessage = {
  level: "info" | "success" | "error";
  message: string;
};

function normalizeShortcut(value: string): string {
  return value.trim().toLowerCase().replace(/\s+/g, "");
}

function draftFromRows(rows: Keybinding[]): Record<string, string> {
  const draft: Record<string, string> = {};
  for (const row of rows) {
    draft[row.action] = row.shortcut;
  }
  return draft;
}

export function SettingsPane() {
  const [keybindings, setKeybindings] = useState<Keybinding[]>([]);
  const [draft, setDraft] = useState<Record<string, string>>({});
  const [telemetry, setTelemetry] = useState<TelemetryStatus | null>(null);
  const [report, setReport] = useState<PartnerMetricsReport | null>(null);
  const [feedbackCategory, setFeedbackCategory] = useState("ux");
  const [feedbackBody, setFeedbackBody] = useState("");
  const [feedbackContact, setFeedbackContact] = useState("");
  const [exportPath, setExportPath] = useState("");
  const [busy, setBusy] = useState(false);
  const [status, setStatus] = useState<StatusMessage | null>(null);

  const refresh = async () => {
    try {
      const [bindingRows, telemetryStatus] = await Promise.all([
        listKeybindings(),
        getTelemetryStatus(),
      ]);
      setKeybindings(bindingRows);
      setDraft(draftFromRows(bindingRows));
      setTelemetry(telemetryStatus);
    } catch (error) {
      setStatus({
        level: "error",
        message: error instanceof Error ? error.message : "failed to load settings",
      });
    }
  };

  useEffect(() => {
    void refresh();
  }, []);

  const conflictingShortcuts = useMemo(() => {
    const counts = new Map<string, number>();
    for (const value of Object.values(draft)) {
      const normalized = normalizeShortcut(value);
      if (!normalized) {
        continue;
      }
      counts.set(normalized, (counts.get(normalized) ?? 0) + 1);
    }
    const conflicts = new Set<string>();
    for (const [shortcut, count] of counts.entries()) {
      if (count > 1) {
        conflicts.add(shortcut);
      }
    }
    return conflicts;
  }, [draft]);

  const hasConflicts = conflictingShortcuts.size > 0;

  const statusClass =
    status?.level === "error"
      ? "border-rose-400/60 bg-rose-500/10 text-rose-200"
      : status?.level === "success"
      ? "border-mint-400/60 bg-mint-500/10 text-mint-100"
      : "border-slate-500/50 bg-slate-800/70 text-slate-200";

  const saveBinding = async (action: string) => {
    const shortcut = (draft[action] ?? "").trim();
    if (!shortcut) {
      setStatus({ level: "error", message: `shortcut required for ${action}` });
      return;
    }
    if (conflictingShortcuts.has(normalizeShortcut(shortcut))) {
      setStatus({
        level: "error",
        message: `resolve duplicate shortcuts before saving ${action}`,
      });
      return;
    }
    setBusy(true);
    try {
      const rows = await setKeybinding(action, shortcut);
      setKeybindings(rows);
      setDraft(draftFromRows(rows));
      setStatus({ level: "success", message: `saved ${action}` });
      window.dispatchEvent(new Event("pnevma:keybindings-updated"));
    } catch (error) {
      setStatus({
        level: "error",
        message: error instanceof Error ? error.message : `failed to save ${action}`,
      });
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="grid h-full grid-cols-1 gap-3 overflow-auto xl:grid-cols-2">
      {status ? (
        <section className={`rounded-lg border px-3 py-2 text-xs ${statusClass}`}>
          {status.message}
        </section>
      ) : null}

      <section className="rounded-lg border border-white/10 bg-slate-900/60 p-3">
        <header className="mb-2 text-sm font-semibold text-slate-100">Keybindings</header>
        {hasConflicts ? (
          <div className="mb-2 rounded border border-amber-400/60 bg-amber-500/10 px-2 py-1 text-xs text-amber-100">
            Duplicate shortcuts detected. Resolve conflicts before saving.
          </div>
        ) : null}
        <div className="space-y-2">
          {keybindings.map((binding) => {
            const value = draft[binding.action] ?? binding.shortcut;
            const normalized = normalizeShortcut(value);
            const isConflict = normalized.length > 0 && conflictingShortcuts.has(normalized);
            const isDirty = value.trim() !== binding.shortcut.trim();
            return (
              <div key={binding.action} className="rounded border border-white/10 bg-slate-950/70 p-2">
                <div className="text-xs text-slate-300">{binding.action}</div>
                <div className="mt-1 flex items-center gap-2">
                  <input
                    className={`w-full rounded border bg-slate-900 px-2 py-1 text-xs text-slate-100 outline-none ${
                      isConflict
                        ? "border-amber-400/70 focus:border-amber-300"
                        : "border-white/20 focus:border-mint-400"
                    }`}
                    value={value}
                    onChange={(event) =>
                      setDraft((current) => ({ ...current, [binding.action]: event.target.value }))
                    }
                  />
                  <button
                    className="rounded bg-slate-700 px-2 py-1 text-xs text-slate-200 disabled:opacity-50"
                    disabled={busy || !isDirty || isConflict}
                    onClick={() => {
                      void saveBinding(binding.action);
                    }}
                  >
                    Save
                  </button>
                </div>
                {isConflict ? (
                  <div className="mt-1 text-[11px] text-amber-200">Shortcut conflicts with another action.</div>
                ) : null}
              </div>
            );
          })}
        </div>
        <button
          className="mt-3 rounded bg-amber-500 px-2 py-1 text-xs font-semibold text-slate-950 disabled:opacity-50"
          disabled={busy}
          onClick={() => {
            setBusy(true);
            void resetKeybindings()
              .then((rows) => {
                setKeybindings(rows);
                setDraft(draftFromRows(rows));
                setStatus({ level: "success", message: "keybindings reset to defaults" });
                window.dispatchEvent(new Event("pnevma:keybindings-updated"));
              })
              .catch((error) => {
                setStatus({
                  level: "error",
                  message: error instanceof Error ? error.message : "failed to reset keybindings",
                });
              })
              .finally(() => setBusy(false));
          }}
        >
          Reset Keybindings
        </button>
      </section>

      <section className="rounded-lg border border-white/10 bg-slate-900/60 p-3">
        <header className="mb-2 text-sm font-semibold text-slate-100">Telemetry</header>
        <div className="text-xs text-slate-400">
          opted in: {telemetry?.opted_in ? "yes" : "no"} · queued: {telemetry?.queued_events ?? 0}
        </div>
        <div className="mt-2 flex flex-wrap gap-2">
          <button
            className="rounded bg-slate-700 px-2 py-1 text-xs text-slate-200 disabled:opacity-50"
            disabled={busy}
            onClick={() => {
              const next = !telemetry?.opted_in;
              setBusy(true);
              void setTelemetryOptIn(next)
                .then((nextStatus) => {
                  setTelemetry(nextStatus);
                  setStatus({
                    level: "success",
                    message: next ? "telemetry enabled" : "telemetry disabled",
                  });
                })
                .catch((error) => {
                  setStatus({
                    level: "error",
                    message:
                      error instanceof Error ? error.message : "failed to update telemetry setting",
                  });
                })
                .finally(() => setBusy(false));
            }}
          >
            {telemetry?.opted_in ? "Disable" : "Enable"} Telemetry
          </button>
          <button
            className="rounded bg-slate-700 px-2 py-1 text-xs text-slate-200 disabled:opacity-50"
            disabled={busy}
            onClick={() => {
              setBusy(true);
              void exportTelemetryBundle(exportPath.trim() || undefined)
                .then((path) => {
                  setStatus({ level: "success", message: `telemetry exported: ${path}` });
                })
                .catch((error) => {
                  setStatus({
                    level: "error",
                    message: error instanceof Error ? error.message : "failed to export telemetry",
                  });
                })
                .finally(() => setBusy(false));
            }}
          >
            Export Telemetry
          </button>
          <button
            className="rounded bg-amber-500 px-2 py-1 text-xs font-semibold text-slate-950 disabled:opacity-50"
            disabled={busy}
            onClick={() => {
              setBusy(true);
              void clearTelemetry()
                .then(() => refresh())
                .then(() => setStatus({ level: "success", message: "telemetry queue cleared" }))
                .catch((error) => {
                  setStatus({
                    level: "error",
                    message: error instanceof Error ? error.message : "failed to clear telemetry",
                  });
                })
                .finally(() => setBusy(false));
            }}
          >
            Clear Telemetry
          </button>
        </div>
        <label className="mt-2 block text-[11px] text-slate-400">
          Export Path (optional)
          <input
            className="mt-1 w-full rounded border border-white/20 bg-slate-900 px-2 py-1 text-xs text-slate-100 outline-none focus:border-mint-400"
            value={exportPath}
            onChange={(event) => setExportPath(event.target.value)}
            placeholder=".pnevma/data/telemetry/custom-export.json"
          />
        </label>
      </section>

      <section className="rounded-lg border border-white/10 bg-slate-900/60 p-3">
        <header className="mb-2 text-sm font-semibold text-slate-100">Onboarding</header>
        <button
          className="rounded bg-slate-700 px-2 py-1 text-xs text-slate-200 disabled:opacity-50"
          disabled={busy}
          onClick={() => {
            setBusy(true);
            void resetOnboarding()
              .then(() => {
                window.dispatchEvent(new Event("pnevma:onboarding-reset"));
                setStatus({ level: "success", message: "onboarding reset" });
              })
              .catch((error) => {
                setStatus({
                  level: "error",
                  message: error instanceof Error ? error.message : "failed to reset onboarding",
                });
              })
              .finally(() => setBusy(false));
          }}
        >
          Restart Onboarding
        </button>
      </section>

      <section className="rounded-lg border border-white/10 bg-slate-900/60 p-3">
        <header className="mb-2 text-sm font-semibold text-slate-100">Feedback & Metrics</header>
        <div className="space-y-2">
          <label className="block text-[11px] text-slate-400">
            Category
            <input
              className="mt-1 w-full rounded border border-white/20 bg-slate-900 px-2 py-1 text-xs text-slate-100 outline-none focus:border-mint-400"
              value={feedbackCategory}
              onChange={(event) => setFeedbackCategory(event.target.value)}
              placeholder="ux"
            />
          </label>
          <label className="block text-[11px] text-slate-400">
            Details
            <textarea
              className="mt-1 h-24 w-full rounded border border-white/20 bg-slate-900 px-2 py-1 text-xs text-slate-100 outline-none focus:border-mint-400"
              value={feedbackBody}
              onChange={(event) => setFeedbackBody(event.target.value)}
              placeholder="Describe issue or suggestion..."
            />
          </label>
          <label className="block text-[11px] text-slate-400">
            Contact (optional)
            <input
              className="mt-1 w-full rounded border border-white/20 bg-slate-900 px-2 py-1 text-xs text-slate-100 outline-none focus:border-mint-400"
              value={feedbackContact}
              onChange={(event) => setFeedbackContact(event.target.value)}
              placeholder="name@example.com"
            />
          </label>
        </div>
        <div className="mt-2 flex flex-wrap gap-2">
          <button
            className="rounded bg-slate-700 px-2 py-1 text-xs text-slate-200 disabled:opacity-50"
            disabled={busy || !feedbackCategory.trim() || !feedbackBody.trim()}
            onClick={() => {
              setBusy(true);
              void submitFeedback({
                category: feedbackCategory.trim(),
                body: feedbackBody.trim(),
                contact: feedbackContact.trim() || undefined,
              })
                .then(() => {
                  setFeedbackBody("");
                  setStatus({ level: "success", message: "feedback submitted" });
                })
                .catch((error) => {
                  setStatus({
                    level: "error",
                    message: error instanceof Error ? error.message : "failed to submit feedback",
                  });
                })
                .finally(() => setBusy(false));
            }}
          >
            Submit Feedback
          </button>
          <button
            className="rounded bg-mint-500 px-2 py-1 text-xs font-semibold text-slate-950 disabled:opacity-50"
            disabled={busy}
            onClick={() => {
              setBusy(true);
              void partnerMetricsReport(14)
                .then((next) => {
                  setReport(next);
                  setStatus({ level: "info", message: "partner metrics generated" });
                })
                .catch((error) => {
                  setStatus({
                    level: "error",
                    message: error instanceof Error ? error.message : "failed to generate metrics",
                  });
                })
                .finally(() => setBusy(false));
            }}
          >
            Generate Partner Metrics
          </button>
        </div>
        {report ? (
          <pre className="mt-2 max-h-[240px] overflow-auto whitespace-pre-wrap rounded border border-white/10 bg-slate-950/70 p-2 text-[11px] text-slate-200">
            {JSON.stringify(report, null, 2)}
          </pre>
        ) : null}
      </section>
    </div>
  );
}
