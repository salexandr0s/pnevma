import { useEffect, useMemo, useState } from "react";

export type KnowledgeCaptureRequest = {
  taskId?: string;
  kinds: string[];
};

type Props = {
  request: KnowledgeCaptureRequest | null;
  busy: boolean;
  onCapture: (kind: string, title: string, content: string) => Promise<void>;
  onClose: () => void;
};

export function KnowledgeCaptureDialog({ request, busy, onCapture, onClose }: Props) {
  const [selectedKind, setSelectedKind] = useState("adr");
  const [title, setTitle] = useState("");
  const [content, setContent] = useState("");

  const kinds = useMemo(() => {
    if (!request || request.kinds.length === 0) {
      return ["adr", "changelog", "convention-update"];
    }
    return request.kinds;
  }, [request]);

  useEffect(() => {
    setSelectedKind(kinds[0] ?? "adr");
    setTitle("");
    setContent("");
  }, [kinds]);

  if (!request) {
    return null;
  }

  return (
    <div className="fixed inset-0 z-50 bg-black/60 p-6">
      <div className="mx-auto mt-12 max-w-2xl rounded-xl border border-white/20 bg-slate-950 p-4 shadow-2xl">
        <header className="flex items-center justify-between gap-2">
          <div>
            <h2 className="text-sm font-semibold text-slate-100">Knowledge Capture</h2>
            <p className="mt-1 text-xs text-slate-400">
              Merge completed. Capture reusable findings for future context packs.
            </p>
          </div>
          <button
            className="rounded bg-slate-700 px-2 py-1 text-xs text-slate-100"
            onClick={onClose}
          >
            Close
          </button>
        </header>
        <div className="mt-3 grid gap-3 md:grid-cols-[200px_1fr]">
          <div className="space-y-2">
            {kinds.map((kind) => (
              <button
                key={kind}
                className={`w-full rounded border px-2 py-2 text-left text-xs ${
                  selectedKind === kind
                    ? "border-mint-400/70 bg-mint-400/10 text-mint-200"
                    : "border-white/15 bg-slate-900/70 text-slate-300"
                }`}
                onClick={() => setSelectedKind(kind)}
              >
                {kind}
              </button>
            ))}
          </div>
          <div className="space-y-2">
            <input
              className="w-full rounded border border-white/20 bg-slate-900 px-2 py-2 text-sm text-slate-100 outline-none focus:border-mint-400"
              value={title}
              onChange={(event) => setTitle(event.target.value)}
              placeholder={`Title for ${selectedKind}`}
            />
            <textarea
              className="h-44 w-full rounded border border-white/20 bg-slate-900 px-2 py-2 text-sm text-slate-100 outline-none focus:border-mint-400"
              value={content}
              onChange={(event) => setContent(event.target.value)}
              placeholder="What should future tasks know?"
            />
            <div className="flex items-center justify-between">
              <div className="text-[11px] text-slate-500">
                Task: {request.taskId ?? "general"} · Kind: {selectedKind}
              </div>
              <button
                className="rounded bg-mint-500 px-2 py-1 text-xs font-semibold text-slate-950 disabled:opacity-60"
                disabled={busy || !content.trim()}
                onClick={() => {
                  void onCapture(selectedKind, title, content);
                }}
              >
                Save Capture
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
