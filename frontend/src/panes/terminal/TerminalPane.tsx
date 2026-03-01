import { useEffect, useRef } from "react";
import { listen } from "@tauri-apps/api/event";
import { Terminal } from "xterm";
import { FitAddon } from "xterm-addon-fit";
import "xterm/css/xterm.css";
import { getScrollback, sendSessionInput } from "../../hooks/useTauri";

type Props = {
  title: string;
  sessionId?: string | null;
  sessionStatus?: string;
};

type SessionOutputPayload = {
  session_id: string;
  chunk: string;
};

export function TerminalPane({ title, sessionId, sessionStatus }: Props) {
  const ref = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    if (!ref.current) {
      return;
    }

    const term = new Terminal({
      fontSize: 12,
      theme: {
        background: "#020617",
        foreground: "#e2e8f0",
      },
      convertEol: true,
      cursorBlink: true,
    });

    const fit = new FitAddon();
    term.loadAddon(fit);
    term.open(ref.current);
    fit.fit();
    term.writeln(`${title} ready`);
    if (!sessionId) {
      term.writeln("No session is bound to this pane yet.");
    } else if (sessionStatus === "waiting") {
      term.writeln("Session is waiting. Try reattach first, then restart if backend is gone.");
    } else if (sessionStatus === "complete") {
      term.writeln("Session is complete. Use restart command to open a new shell.");
    }

    let unavailableNoticeShown = false;
    const onDataDispose = term.onData((data) => {
      if (!sessionId) {
        return;
      }
      void sendSessionInput(sessionId, data).catch(() => {
        if (!unavailableNoticeShown) {
          unavailableNoticeShown = true;
          term.writeln("\r\n[session unavailable] try reattach, then restart from command palette.");
        }
      });
    });

    if (sessionId) {
      void getScrollback(sessionId, 0, 128 * 1024).then((slice) => {
        if (slice?.data) {
          term.write(slice.data);
        }
      });
    }

    let stop = false;
    let unlisten: (() => void) | null = null;
    const listenPromise = listen<SessionOutputPayload>("session_output", (event) => {
      if (stop) {
        return;
      }
      if (event.payload.session_id === sessionId) {
        term.write(event.payload.chunk);
      }
    }).then((fn) => {
      unlisten = fn;
    });

    const resize = () => fit.fit();
    window.addEventListener("resize", resize);

    return () => {
      stop = true;
      window.removeEventListener("resize", resize);
      onDataDispose.dispose();
      void listenPromise.then(() => {
        if (unlisten) {
          unlisten();
        }
      });
      term.dispose();
    };
  }, [sessionId, sessionStatus, title]);

  return <div ref={ref} className="h-full w-full" />;
}
