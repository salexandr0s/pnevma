import { useCallback, useEffect, useRef, useState } from "react";

type DialogType = "alert" | "confirm" | "prompt";

interface DialogState {
  type: DialogType;
  title: string;
  message?: string;
  defaultValue?: string;
  resolve: (value: string | boolean | null) => void;
}

let showDialogFn: ((state: DialogState) => void) | null = null;

export function alert(message: string): Promise<void> {
  return new Promise((resolve) => {
    showDialogFn?.({
      type: "alert",
      title: message,
      resolve: () => resolve(),
    });
  });
}

export function confirm(message: string): Promise<boolean> {
  return new Promise((resolve) => {
    showDialogFn?.({
      type: "confirm",
      title: message,
      resolve: (v) => resolve(v === true),
    });
  });
}

export function prompt(label: string, defaultValue = ""): Promise<string | null> {
  return new Promise((resolve) => {
    showDialogFn?.({
      type: "prompt",
      title: label,
      defaultValue,
      resolve: (v) => resolve(typeof v === "string" ? v : null),
    });
  });
}

function getFocusableElements(container: HTMLElement): HTMLElement[] {
  const selectors =
    'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';
  return Array.from(container.querySelectorAll<HTMLElement>(selectors));
}

export function DialogProvider() {
  const [dialog, setDialog] = useState<DialogState | null>(null);
  const [inputValue, setInputValue] = useState("");
  const inputRef = useRef<HTMLInputElement>(null);
  const dialogRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    showDialogFn = (state) => {
      setInputValue(state.defaultValue ?? "");
      setDialog(state);
    };
    return () => {
      showDialogFn = null;
    };
  }, []);

  useEffect(() => {
    if (!dialog) return;
    if (dialog.type === "prompt" && inputRef.current) {
      inputRef.current.focus();
      inputRef.current.select();
    } else if (dialogRef.current) {
      dialogRef.current.focus();
    }
  }, [dialog]);

  const close = useCallback(
    (result: string | boolean | null) => {
      dialog?.resolve(result);
      setDialog(null);
    },
    [dialog]
  );

  if (!dialog) return null;

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm">
      <div
        ref={dialogRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby="dialog-title"
        tabIndex={-1}
        className="mx-4 w-full max-w-md rounded-lg border border-white/10 bg-slate-900 p-5 shadow-xl outline-none"
        onKeyDown={(e) => {
          if (e.key === "Escape") {
            close(dialog.type === "confirm" ? false : null);
          }
          if (e.key === "Tab" && dialogRef.current) {
            const focusable = getFocusableElements(dialogRef.current);
            if (focusable.length === 0) {
              e.preventDefault();
              return;
            }
            const first = focusable[0];
            const last = focusable[focusable.length - 1];
            if (e.shiftKey) {
              if (document.activeElement === first || document.activeElement === dialogRef.current) {
                e.preventDefault();
                last.focus();
              }
            } else {
              if (document.activeElement === last) {
                e.preventDefault();
                first.focus();
              }
            }
          }
        }}
      >
        <p id="dialog-title" className="mb-4 whitespace-pre-wrap text-sm text-slate-200">{dialog.title}</p>

        {dialog.type === "prompt" && (
          <input
            ref={inputRef}
            type="text"
            value={inputValue}
            onChange={(e) => setInputValue(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter") close(inputValue);
            }}
            className="mb-4 w-full rounded border border-white/20 bg-slate-800 px-3 py-2 text-sm text-slate-100 outline-none focus:border-mint-400/60"
          />
        )}

        <div className="flex justify-end gap-2">
          {dialog.type !== "alert" && (
            <button
              onClick={() => close(dialog.type === "confirm" ? false : null)}
              className="rounded px-3 py-1.5 text-sm text-slate-400 hover:bg-white/10"
            >
              Cancel
            </button>
          )}
          <button
            onClick={() => {
              if (dialog.type === "prompt") close(inputValue);
              else if (dialog.type === "confirm") close(true);
              else close(true);
            }}
            autoFocus={dialog.type !== "prompt"}
            className="rounded bg-mint-500/20 px-3 py-1.5 text-sm text-mint-300 hover:bg-mint-500/30"
          >
            OK
          </button>
        </div>
      </div>
    </div>
  );
}
