export interface Transport {
  invoke<T>(method: string, args?: Record<string, unknown>): Promise<T>;
  subscribe(event: string, cb: (payload: unknown) => void): Promise<() => void>;
  sendSessionInput(sessionId: string, data: string): Promise<void>;
  resizeSession(sessionId: string, cols: number, rows: number): Promise<void>;
}

class TauriTransport implements Transport {
  async invoke<T>(method: string, args?: Record<string, unknown>): Promise<T> {
    const { invoke } = await import("@tauri-apps/api/core");
    return invoke<T>(method, args);
  }

  async subscribe(
    event: string,
    cb: (payload: unknown) => void,
  ): Promise<() => void> {
    const { listen } = await import("@tauri-apps/api/event");
    const unlisten = await listen(event, (e: { payload: unknown }) =>
      cb(e.payload),
    );
    return unlisten;
  }

  async sendSessionInput(sessionId: string, data: string): Promise<void> {
    return this.invoke("send_session_input", { sessionId, data });
  }

  async resizeSession(
    sessionId: string,
    cols: number,
    rows: number,
  ): Promise<void> {
    return this.invoke("resize_session", { sessionId, cols, rows });
  }
}

class HttpTransport implements Transport {
  private ws: WebSocket | null = null;
  private listeners = new Map<string, Set<(payload: unknown) => void>>();
  private sendQueue: string[] = [];
  private activeChannels = new Set<string>();

  constructor(private baseUrl: string) {}

  // Token stored in sessionStorage: tab-scoped, cleared on close.
  // Acceptable for a desktop app with optional remote access over HTTPS.
  // XSS is mitigated by a strict CSP; revisit if the threat model changes.
  private get token(): string {
    return sessionStorage.getItem("pnevma_token") ?? "";
  }

  async invoke<T>(method: string, args?: Record<string, unknown>): Promise<T> {
    const res = await fetch(`${this.baseUrl}/api/rpc`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${this.token}`,
      },
      body: JSON.stringify({ method, params: args ?? {} }),
    });
    if (!res.ok) {
      const body = (await res.text()).slice(0, 200);
      if (res.status === 401) {
        throw new Error("Authentication expired. Please reconnect.");
      }
      throw new Error(`RPC failed (${res.status}): ${body}`);
    }
    const json = (await res.json()) as {
      ok: boolean;
      result?: T;
      error?: { message?: string };
    };
    if (!json.ok) throw new Error(json.error?.message ?? "RPC error");
    return json.result as T;
  }

  private wsSend(data: string) {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(data);
    } else {
      this.sendQueue.push(data);
    }
  }

  private ensureWs() {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) return;
    const wsUrl = this.baseUrl.replace(/^http/, "ws") + "/api/ws";
    this.ws = new WebSocket(wsUrl);
    this.ws.onopen = () => {
      // Auth is handled by the auth_token middleware on the HTTP upgrade request;
      // no need to send a separate auth message over the WebSocket.
      // Replay subscriptions after reconnect
      for (const channel of this.activeChannels) {
        this.ws!.send(JSON.stringify({ type: "subscribe", channel }));
      }
      // Flush queued messages
      while (this.sendQueue.length > 0) {
        const msg = this.sendQueue.shift()!;
        this.ws!.send(msg);
      }
    };
    this.ws.onmessage = (ev) => {
      try {
        const msg = JSON.parse(ev.data as string) as {
          channel?: string;
          type?: string;
          payload: unknown;
        };
        const channel = msg.channel ?? msg.type;
        if (channel)
          this.listeners.get(channel)?.forEach((cb) => cb(msg.payload));
      } catch {
        // ignore parse errors
      }
    };
    this.ws.onclose = () => {
      this.ws = null;
    };
  }

  async subscribe(
    event: string,
    cb: (payload: unknown) => void,
  ): Promise<() => void> {
    this.ensureWs();
    if (!this.listeners.has(event)) this.listeners.set(event, new Set());
    this.listeners.get(event)!.add(cb);
    this.activeChannels.add(event);
    this.wsSend(JSON.stringify({ type: "subscribe", channel: event }));
    return () => {
      this.listeners.get(event)?.delete(cb);
      if (!this.listeners.get(event)?.size) {
        this.activeChannels.delete(event);
      }
    };
  }

  async sendSessionInput(sessionId: string, data: string): Promise<void> {
    this.ensureWs();
    this.wsSend(
      JSON.stringify({ type: "session_input", session_id: sessionId, data }),
    );
  }

  async resizeSession(
    sessionId: string,
    cols: number,
    rows: number,
  ): Promise<void> {
    this.ensureWs();
    this.wsSend(
      JSON.stringify({
        type: "session_resize",
        session_id: sessionId,
        cols,
        rows,
      }),
    );
  }

  /** Close the current WebSocket so the next operation triggers a reconnect. */
  resetConnection(): void {
    this.ws?.close();
    this.ws = null;
  }
}

function isTauri(): boolean {
  return typeof window !== "undefined" && "__TAURI__" in window;
}

let _transport: Transport | null = null;

export function getTransport(): Transport {
  if (!_transport) {
    if (isTauri()) {
      _transport = new TauriTransport();
    } else {
      _transport = new HttpTransport(window.location.origin);
    }
  }
  return _transport;
}

export function setHttpToken(token: string): void {
  sessionStorage.setItem("pnevma_token", token);
  // Force WS reconnect with new token on next use
  if (_transport instanceof HttpTransport) {
    _transport.resetConnection();
  }
}
