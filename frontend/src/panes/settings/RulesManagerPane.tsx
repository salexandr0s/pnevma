import { useEffect, useState } from "react";
import {
  deleteConvention,
  deleteRule,
  listConventions,
  listRules,
  listRuleUsage,
  toggleConvention,
  toggleRule,
  upsertConvention,
  upsertRule,
} from "../../hooks/useTauri";
import type { RuleEntry, RuleUsage } from "../../lib/types";

type Scope = "rule" | "convention";

type StatusMessage = {
  level: "info" | "success" | "error";
  message: string;
};

export function RulesManagerPane() {
  const [scope, setScope] = useState<Scope>("rule");
  const [rules, setRules] = useState<RuleEntry[]>([]);
  const [conventions, setConventions] = useState<RuleEntry[]>([]);
  const [selectedId, setSelectedId] = useState<string | undefined>();
  const [usage, setUsage] = useState<RuleUsage[]>([]);
  const [editorName, setEditorName] = useState("");
  const [editorContent, setEditorContent] = useState("");
  const [creating, setCreating] = useState(false);
  const [deleteArmed, setDeleteArmed] = useState(false);
  const [busy, setBusy] = useState(false);
  const [status, setStatus] = useState<StatusMessage | null>(null);

  const selected =
    (scope === "rule" ? rules : conventions).find((entry) => entry.id === selectedId) ?? null;

  const refresh = async () => {
    setBusy(true);
    try {
      const [ruleRows, conventionRows] = await Promise.all([listRules(), listConventions()]);
      setRules(ruleRows);
      setConventions(conventionRows);
      const activeList = scope === "rule" ? ruleRows : conventionRows;
      if (!activeList.some((row) => row.id === selectedId)) {
        setSelectedId(activeList[0]?.id);
      }
    } catch (error) {
      setStatus({
        level: "error",
        message: error instanceof Error ? error.message : "failed to refresh rules",
      });
    } finally {
      setBusy(false);
    }
  };

  useEffect(() => {
    void refresh();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    const current = (scope === "rule" ? rules : conventions).find((entry) => entry.id === selectedId);
    if (!current) {
      setUsage([]);
      if (!creating) {
        setEditorName("");
        setEditorContent("");
      }
      return;
    }
    if (!creating) {
      setEditorName(current.name);
      setEditorContent(current.content);
    }
    void listRuleUsage(current.id, 50).then(setUsage).catch(() => setUsage([]));
  }, [scope, rules, conventions, selectedId, creating]);

  const resetCreateDraft = () => {
    setCreating(true);
    setDeleteArmed(false);
    setEditorName("");
    setEditorContent(`# ${scope === "rule" ? "Rule" : "Convention"}\n\n`);
    setStatus({ level: "info", message: `creating new ${scope}` });
  };

  const saveCreate = async () => {
    const name = editorName.trim();
    if (!name) {
      setStatus({ level: "error", message: `${scope} name is required` });
      return;
    }
    setBusy(true);
    try {
      if (scope === "rule") {
        await upsertRule({ name, content: editorContent, active: true });
      } else {
        await upsertConvention({ name, content: editorContent, active: true });
      }
      setCreating(false);
      await refresh();
      setStatus({ level: "success", message: `${scope} created` });
    } catch (error) {
      setStatus({
        level: "error",
        message: error instanceof Error ? error.message : `failed to create ${scope}`,
      });
    } finally {
      setBusy(false);
    }
  };

  const saveSelected = async () => {
    if (!selected) {
      setStatus({ level: "error", message: "select an entry first" });
      return;
    }
    const name = editorName.trim();
    if (!name) {
      setStatus({ level: "error", message: `${scope} name is required` });
      return;
    }
    setBusy(true);
    try {
      if (scope === "rule") {
        await upsertRule({
          id: selected.id,
          name,
          content: editorContent,
          active: selected.active,
        });
      } else {
        await upsertConvention({
          id: selected.id,
          name,
          content: editorContent,
          active: selected.active,
        });
      }
      await refresh();
      setStatus({ level: "success", message: `${scope} saved` });
    } catch (error) {
      setStatus({
        level: "error",
        message: error instanceof Error ? error.message : `failed to save ${scope}`,
      });
    } finally {
      setBusy(false);
    }
  };

  const toggleSelected = async () => {
    if (!selected) {
      return;
    }
    setBusy(true);
    try {
      if (scope === "rule") {
        await toggleRule(selected.id, !selected.active);
      } else {
        await toggleConvention(selected.id, !selected.active);
      }
      await refresh();
      setStatus({
        level: "success",
        message: `${scope} ${selected.active ? "disabled" : "enabled"}`,
      });
    } catch (error) {
      setStatus({
        level: "error",
        message: error instanceof Error ? error.message : `failed to toggle ${scope}`,
      });
    } finally {
      setBusy(false);
    }
  };

  const removeSelected = async () => {
    if (!selected) {
      return;
    }
    if (!deleteArmed) {
      setDeleteArmed(true);
      setStatus({
        level: "info",
        message: `press Delete again to confirm removal of ${selected.name}`,
      });
      return;
    }
    setBusy(true);
    try {
      if (scope === "rule") {
        await deleteRule(selected.id);
      } else {
        await deleteConvention(selected.id);
      }
      setDeleteArmed(false);
      await refresh();
      setStatus({ level: "success", message: `${scope} deleted` });
    } catch (error) {
      setStatus({
        level: "error",
        message: error instanceof Error ? error.message : `failed to delete ${scope}`,
      });
    } finally {
      setBusy(false);
    }
  };

  const list = scope === "rule" ? rules : conventions;

  const statusClass =
    status?.level === "error"
      ? "border-rose-400/60 bg-rose-500/10 text-rose-200"
      : status?.level === "success"
      ? "border-mint-400/60 bg-mint-500/10 text-mint-100"
      : "border-slate-500/50 bg-slate-800/70 text-slate-200";

  return (
    <div className="grid h-full grid-cols-1 gap-3 overflow-auto xl:grid-cols-4">
      <section className="rounded-lg border border-white/10 bg-slate-900/60 p-3 xl:col-span-1">
        <header className="mb-2 flex items-center justify-between gap-2">
          <div className="text-xs font-semibold uppercase tracking-wide text-slate-300">
            {scope === "rule" ? "Rules" : "Conventions"}
          </div>
          <button
            className="rounded bg-mint-500 px-2 py-1 text-xs font-semibold text-slate-950 disabled:opacity-50"
            disabled={busy}
            onClick={resetCreateDraft}
          >
            New
          </button>
        </header>
        <div className="mb-2 flex gap-2">
          <button
            className={`rounded px-2 py-1 text-xs ${
              scope === "rule" ? "bg-mint-500 text-slate-950" : "bg-slate-700 text-slate-200"
            }`}
            onClick={() => {
              setScope("rule");
              setCreating(false);
              setDeleteArmed(false);
            }}
          >
            Rules
          </button>
          <button
            className={`rounded px-2 py-1 text-xs ${
              scope === "convention"
                ? "bg-mint-500 text-slate-950"
                : "bg-slate-700 text-slate-200"
            }`}
            onClick={() => {
              setScope("convention");
              setCreating(false);
              setDeleteArmed(false);
            }}
          >
            Conventions
          </button>
        </div>
        <div className="space-y-2">
          {busy ? <div className="text-xs text-slate-400">Loading...</div> : null}
          {list.map((entry) => (
            <button
              key={entry.id}
              className={`w-full rounded border px-2 py-2 text-left ${
                entry.id === selectedId && !creating
                  ? "border-mint-400/70 bg-mint-400/10"
                  : "border-white/10 bg-slate-950/70"
              }`}
              onClick={() => {
                setCreating(false);
                setDeleteArmed(false);
                setSelectedId(entry.id);
              }}
            >
              <div className="text-sm text-slate-100">{entry.name}</div>
              <div className="mt-1 text-[11px] text-slate-400">{entry.path}</div>
              <div className="mt-1 text-[11px] text-slate-500">
                {entry.active ? "active" : "disabled"}
              </div>
            </button>
          ))}
        </div>
      </section>

      <section className="rounded-lg border border-white/10 bg-slate-900/60 p-3 xl:col-span-3">
        {status ? <div className={`mb-3 rounded border px-2 py-1 text-xs ${statusClass}`}>{status.message}</div> : null}

        {creating ? (
          <div className="space-y-3">
            <header className="text-sm font-semibold text-slate-100">
              New {scope === "rule" ? "Rule" : "Convention"}
            </header>
            <label className="block text-xs text-slate-300">
              Name
              <input
                className="mt-1 w-full rounded border border-white/20 bg-slate-900 px-2 py-1 text-sm text-slate-100 outline-none focus:border-mint-400"
                value={editorName}
                onChange={(event) => setEditorName(event.target.value)}
              />
            </label>
            <label className="block text-xs text-slate-300">
              Content
              <textarea
                className="mt-1 h-52 w-full rounded border border-white/20 bg-slate-900 px-2 py-1 text-xs text-slate-100 outline-none focus:border-mint-400"
                value={editorContent}
                onChange={(event) => setEditorContent(event.target.value)}
              />
            </label>
            <div className="flex gap-2">
              <button
                className="rounded bg-mint-500 px-2 py-1 text-xs font-semibold text-slate-950 disabled:opacity-50"
                disabled={busy}
                onClick={() => {
                  void saveCreate();
                }}
              >
                Create
              </button>
              <button
                className="rounded bg-slate-700 px-2 py-1 text-xs text-slate-200"
                onClick={() => {
                  setCreating(false);
                  setStatus({ level: "info", message: "create cancelled" });
                }}
              >
                Cancel
              </button>
            </div>
          </div>
        ) : !selected ? (
          <div className="text-sm text-slate-400">Select an entry to edit.</div>
        ) : (
          <div className="space-y-3">
            <header className="flex flex-wrap items-center justify-between gap-2">
              <h2 className="text-sm font-semibold text-slate-100">{selected.name}</h2>
              <div className="flex gap-2">
                <button
                  className="rounded bg-slate-700 px-2 py-1 text-xs text-slate-200 disabled:opacity-50"
                  disabled={busy}
                  onClick={() => {
                    void toggleSelected();
                  }}
                >
                  {selected.active ? "Disable" : "Enable"}
                </button>
                <button
                  className="rounded bg-mint-500 px-2 py-1 text-xs font-semibold text-slate-950 disabled:opacity-50"
                  disabled={busy}
                  onClick={() => {
                    void saveSelected();
                  }}
                >
                  Save
                </button>
                <button
                  className={`rounded px-2 py-1 text-xs font-semibold text-slate-950 disabled:opacity-50 ${
                    deleteArmed ? "bg-rose-500" : "bg-amber-500"
                  }`}
                  disabled={busy}
                  onClick={() => {
                    void removeSelected();
                  }}
                >
                  {deleteArmed ? "Confirm Delete" : "Delete"}
                </button>
              </div>
            </header>
            <label className="block text-xs text-slate-300">
              Name
              <input
                className="mt-1 w-full rounded border border-white/20 bg-slate-900 px-2 py-1 text-sm text-slate-100 outline-none focus:border-mint-400"
                value={editorName}
                onChange={(event) => setEditorName(event.target.value)}
              />
            </label>
            <label className="block text-xs text-slate-300">
              Content
              <textarea
                className="mt-1 h-52 w-full rounded border border-white/20 bg-slate-900 px-2 py-1 text-xs text-slate-100 outline-none focus:border-mint-400"
                value={editorContent}
                onChange={(event) => setEditorContent(event.target.value)}
              />
            </label>
            <article className="rounded border border-white/10 bg-slate-950/70 p-3">
              <div className="text-xs uppercase tracking-wide text-slate-500">Usage</div>
              <div className="mt-2 space-y-2">
                {usage.length === 0 ? (
                  <div className="text-sm text-slate-400">No context usage records yet.</div>
                ) : (
                  usage.map((item, index) => (
                    <div key={`${item.run_id}-${index}`} className="rounded border border-white/10 p-2">
                      <div className="text-xs text-slate-300">
                        {item.included ? "Included" : "Omitted"} · {item.reason}
                      </div>
                      <div className="text-[11px] text-slate-500">
                        run {item.run_id} · {new Date(item.created_at).toLocaleString()}
                      </div>
                    </div>
                  ))
                )}
              </div>
            </article>
          </div>
        )}
      </section>
    </div>
  );
}
