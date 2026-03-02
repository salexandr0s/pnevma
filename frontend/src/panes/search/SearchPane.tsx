import { useEffect, useMemo, useState } from "react";
import { searchProject } from "../../hooks/useTauri";
import type { SearchResult } from "../../lib/types";

export function SearchPane() {
  const [query, setQuery] = useState("");
  const [loading, setLoading] = useState(false);
  const [results, setResults] = useState<SearchResult[]>([]);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const q = query.trim();
    if (!q) {
      setResults([]);
      setError(null);
      return;
    }
    const timer = setTimeout(() => {
      setLoading(true);
      setError(null);
      void searchProject(q, 150)
        .then((rows) => setResults(rows))
        .catch((err) => {
          const message = err instanceof Error ? err.message : String(err);
          setError(message);
        })
        .finally(() => setLoading(false));
    }, 180);
    return () => clearTimeout(timer);
  }, [query]);

  const grouped = useMemo(() => {
    const bySource = new Map<string, SearchResult[]>();
    for (const result of results) {
      const current = bySource.get(result.source) ?? [];
      current.push(result);
      bySource.set(result.source, current);
    }
    return Array.from(bySource.entries()).sort((a, b) => a[0].localeCompare(b[0]));
  }, [results]);

  return (
    <div className="flex h-full flex-col rounded-lg border border-white/10 bg-slate-900/60 p-3">
      <header className="mb-2 flex items-center justify-between gap-2">
        <h2 className="text-sm font-semibold text-slate-100">Search</h2>
        <span className="text-xs text-slate-500">{results.length} results</span>
      </header>
      <input
        className="w-full rounded border border-white/15 bg-slate-950/70 px-3 py-2 text-sm text-slate-200 outline-none focus:border-mint-400/70"
        placeholder="Search tasks, events, commits, artifacts, scrollback..."
        value={query}
        onChange={(event) => setQuery(event.target.value)}
      />
      <div className="mt-3 flex-1 space-y-3 overflow-auto">
        {loading ? <div className="text-sm text-slate-400">Searching...</div> : null}
        {error ? <div className="text-sm text-amber-300">{error}</div> : null}
        {!loading && !error && query.trim() && results.length === 0 ? (
          <div className="text-sm text-slate-400">No matches.</div>
        ) : null}
        {!query.trim() ? (
          <div className="text-sm text-slate-500">
            Start typing to search across project activity.
          </div>
        ) : null}
        {grouped.map(([source, items]) => (
          <section key={source} className="rounded border border-white/10 bg-slate-950/70 p-2">
            <header className="mb-2 text-xs font-semibold uppercase tracking-wide text-slate-400">
              {source} ({items.length})
            </header>
            <div className="space-y-2">
              {items.map((result) => (
                <article key={result.id} className="rounded border border-white/10 p-2">
                  <div className="text-sm font-medium text-slate-100">{result.title}</div>
                  <div className="mt-1 text-xs text-slate-400">{result.snippet}</div>
                  <div className="mt-2 flex flex-wrap gap-2 text-[11px] text-slate-500">
                    {result.task_id ? <span>task: {result.task_id.slice(0, 8)}</span> : null}
                    {result.session_id ? (
                      <span>session: {result.session_id.slice(0, 8)}</span>
                    ) : null}
                    {result.path ? <span>path: {result.path}</span> : null}
                    {result.timestamp ? (
                      <span>{new Date(result.timestamp).toLocaleString()}</span>
                    ) : null}
                  </div>
                </article>
              ))}
            </div>
          </section>
        ))}
      </div>
    </div>
  );
}
