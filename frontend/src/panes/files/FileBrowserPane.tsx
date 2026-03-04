import { useEffect, useMemo, useRef, useState } from "react";
import { listProjectFiles, openFileTarget } from "../../hooks/useTauri";
import type { FileOpenResult, ProjectFile } from "../../lib/types";
import { StatusBadge } from "../../components/ui/status-badge";
import { SkeletonText } from "../../components/ui/skeleton";

function statusLabel(file: ProjectFile): string {
  if (file.conflicted) {
    return "conflicted";
  }
  if (file.untracked) {
    return "untracked";
  }
  if (file.staged && file.modified) {
    return "staged+modified";
  }
  if (file.staged) {
    return "staged";
  }
  if (file.modified) {
    return "modified";
  }
  return "clean";
}

export function FileBrowserPane() {
  const [query, setQuery] = useState("");
  const [files, setFiles] = useState<ProjectFile[]>([]);
  const [selectedPath, setSelectedPath] = useState<string | undefined>();
  const [preview, setPreview] = useState<FileOpenResult | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const selectedPathRef = useRef(selectedPath);
  selectedPathRef.current = selectedPath;

  useEffect(() => {
    const timer = setTimeout(() => {
      setBusy(true);
      void listProjectFiles(query, 1500)
        .then((rows) => {
          setFiles(rows);
          if (!rows.some((row) => row.path === selectedPathRef.current)) {
            setSelectedPath(rows[0]?.path);
          }
          setError(null);
        })
        .catch((err) => {
          const message = err instanceof Error ? err.message : String(err);
          setError(message);
        })
        .finally(() => setBusy(false));
    }, 140);
    return () => clearTimeout(timer);
  }, [query]);

  useEffect(() => {
    if (!selectedPath) {
      setPreview(null);
      return;
    }
    setBusy(true);
    void openFileTarget(selectedPath, "preview")
      .then((result) => {
        setPreview(result);
        setError(null);
      })
      .catch((err) => {
        const message = err instanceof Error ? err.message : String(err);
        setError(message);
      })
      .finally(() => setBusy(false));
  }, [selectedPath]);

  const summary = useMemo(() => {
    const conflicted = files.filter((file) => file.conflicted).length;
    const modified = files.filter((file) => file.modified).length;
    const staged = files.filter((file) => file.staged).length;
    return { conflicted, modified, staged };
  }, [files]);

  return (
    <div className="grid h-full grid-cols-1 gap-3 overflow-auto xl:grid-cols-4">
      <section className="rounded-lg border border-white/10 bg-slate-900/60 p-3 xl:col-span-1">
        <header className="mb-2 text-xs font-semibold uppercase tracking-wide text-slate-300">
          Files
        </header>
        <input
          className="mb-2 w-full rounded border border-white/15 bg-slate-950/70 px-2 py-1 text-xs text-slate-200"
          placeholder="Filter files..."
          value={query}
          onChange={(event) => setQuery(event.target.value)}
        />
        <div className="mb-2 text-[11px] text-slate-500">
          {files.length} files · {summary.staged} staged · {summary.modified} modified ·{" "}
          {summary.conflicted} conflicted
        </div>
        <div className="space-y-1 overflow-auto">
          {files.map((file) => (
            <button
              key={file.path}
              onClick={() => setSelectedPath(file.path)}
              className={`w-full rounded border px-2 py-1 text-left ${
                file.path === selectedPath
                  ? "border-mint-400/70 bg-mint-400/10"
                  : "border-white/10 bg-slate-950/70"
              }`}
            >
              <div className="truncate text-xs text-slate-100">{file.path}</div>
              <StatusBadge
                variant={
                  file.conflicted
                    ? "error"
                    : file.staged
                      ? "success"
                      : file.modified
                        ? "warning"
                        : "neutral"
                }
              >
                {statusLabel(file)}
              </StatusBadge>
            </button>
          ))}
        </div>
      </section>

      <section className="rounded-lg border border-white/10 bg-slate-900/60 p-3 xl:col-span-3">
        <header className="mb-2 flex items-center justify-between gap-2">
          <h2 className="text-sm font-semibold text-slate-100">
            {selectedPath ?? "Select a file"}
          </h2>
          {selectedPath ? (
            <button
              className="rounded bg-slate-700 px-2 py-1 text-xs text-slate-200 hover:bg-slate-600"
              onClick={() => {
                void openFileTarget(selectedPath, "editor");
              }}
            >
              Open in $EDITOR
            </button>
          ) : null}
        </header>
        {busy ? <SkeletonText lines={8} /> : null}
        {error ? <div className="text-sm text-amber-300">{error}</div> : null}
        {!selectedPath ? (
          <div className="text-sm text-slate-400">Select a file to preview.</div>
        ) : null}
        {preview ? (
          <pre className="max-h-[460px] overflow-auto whitespace-pre-wrap rounded border border-white/10 bg-slate-950/80 p-3 text-[11px] text-slate-200">
            {preview.content}
            {preview.truncated ? "\n\n...truncated..." : ""}
          </pre>
        ) : null}
      </section>
    </div>
  );
}
