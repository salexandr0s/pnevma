import { useEffect, useMemo, useState } from "react";

type Command = {
  id: string;
  label: string;
  run: () => void | Promise<void>;
};

type Props = {
  commands: Command[];
};

export function CommandPalette({ commands }: Props) {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
        e.preventDefault();
        setOpen((v) => !v);
      }
      if (e.key === "Escape") {
        setOpen(false);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  const filtered = useMemo(() => {
    const q = query.toLowerCase().trim();
    if (!q) {
      return commands;
    }
    return commands.filter((cmd) => cmd.label.toLowerCase().includes(q));
  }, [commands, query]);

  if (!open) {
    return null;
  }

  return (
    <div className="fixed inset-0 z-50 bg-black/40 p-6">
      <div className="mx-auto max-w-xl rounded-xl border border-white/20 bg-ink-950 p-3 shadow-2xl">
        <input
          className="w-full rounded-md border border-white/20 bg-slate-900 px-3 py-2 text-sm outline-none focus:border-mint-400"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder="Type a command..."
          autoFocus
        />
        <ul className="mt-3 max-h-72 overflow-y-auto">
          {filtered.map((cmd) => (
            <li key={cmd.id}>
              <button
                className="w-full rounded-md px-3 py-2 text-left text-sm hover:bg-white/10"
                onClick={() => {
                  void cmd.run();
                  setOpen(false);
                  setQuery("");
                }}
              >
                {cmd.label}
              </button>
            </li>
          ))}
        </ul>
      </div>
    </div>
  );
}
