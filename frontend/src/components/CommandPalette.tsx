import { useEffect, useMemo, useState } from "react";
import { matchesShortcut } from "../lib/keybinding";

type Command = {
  id: string;
  label: string;
  run: () => void | Promise<void>;
};

type Props = {
  commands: Command[];
  toggleShortcut?: string;
  nextShortcut?: string;
  prevShortcut?: string;
  executeShortcut?: string;
};

export function CommandPalette({
  commands,
  toggleShortcut = "Mod+K",
  nextShortcut = "ArrowDown",
  prevShortcut = "ArrowUp",
  executeShortcut = "Enter",
}: Props) {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const [selectedIndex, setSelectedIndex] = useState(0);

  const filtered = useMemo(() => {
    const q = query.toLowerCase().trim();
    if (!q) {
      return commands;
    }
    return commands.filter((cmd) => cmd.label.toLowerCase().includes(q));
  }, [commands, query]);

  useEffect(() => {
    if (selectedIndex >= filtered.length) {
      setSelectedIndex(0);
    }
  }, [filtered.length, selectedIndex]);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (matchesShortcut(event, toggleShortcut)) {
        event.preventDefault();
        setOpen((current) => {
          const next = !current;
          if (next) {
            setSelectedIndex(0);
          }
          return next;
        });
        return;
      }
      if (!open) {
        return;
      }
      if (event.key === "Escape") {
        event.preventDefault();
        setOpen(false);
        return;
      }
      if (matchesShortcut(event, nextShortcut)) {
        event.preventDefault();
        setSelectedIndex((index) => {
          const max = filtered.length - 1;
          if (max < 0) {
            return 0;
          }
          return index >= max ? 0 : index + 1;
        });
        return;
      }
      if (matchesShortcut(event, prevShortcut)) {
        event.preventDefault();
        setSelectedIndex((index) => {
          const max = filtered.length - 1;
          if (max < 0) {
            return 0;
          }
          return index <= 0 ? max : index - 1;
        });
        return;
      }
      if (matchesShortcut(event, executeShortcut)) {
        event.preventDefault();
        const cmd = filtered[selectedIndex] ?? filtered[0];
        if (!cmd) {
          return;
        }
        void cmd.run();
        setOpen(false);
        setQuery("");
        setSelectedIndex(0);
      }
    };

    const onOpenPalette = () => {
      setOpen(true);
      setSelectedIndex(0);
    };

    window.addEventListener("keydown", onKey);
    window.addEventListener("pnevma:open-command-palette", onOpenPalette as EventListener);
    return () => {
      window.removeEventListener("keydown", onKey);
      window.removeEventListener("pnevma:open-command-palette", onOpenPalette as EventListener);
    };
  }, [executeShortcut, filtered, nextShortcut, open, prevShortcut, selectedIndex, toggleShortcut]);

  if (!open) {
    return null;
  }

  return (
    <div className="fixed inset-0 z-50 bg-black/40 p-6">
      <div className="mx-auto max-w-xl rounded-xl border border-white/20 bg-ink-950 p-3 shadow-2xl">
        <input
          className="w-full rounded-md border border-white/20 bg-slate-900 px-3 py-2 text-sm outline-none focus:border-mint-400"
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          placeholder="Type a command..."
          autoFocus
        />
        <ul className="mt-3 max-h-72 overflow-y-auto">
          {filtered.map((cmd, index) => (
            <li key={cmd.id}>
              <button
                className={`w-full rounded-md px-3 py-2 text-left text-sm ${
                  index === selectedIndex ? "bg-white/15" : "hover:bg-white/10"
                }`}
                onClick={() => {
                  void cmd.run();
                  setOpen(false);
                  setQuery("");
                  setSelectedIndex(0);
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
