import { describe, it, expect, beforeEach, vi } from "vitest";

// We need to mock some globals before importing
describe("transport", () => {
  beforeEach(() => {
    // Reset module cache between tests to get fresh singleton
    vi.resetModules();
    // Ensure no __TAURI__ so we get HttpTransport
    if ("__TAURI__" in globalThis) {
      delete (globalThis as Record<string, unknown>).__TAURI__;
    }
    // Mock sessionStorage
    const store: Record<string, string> = {};
    vi.stubGlobal("sessionStorage", {
      getItem: (key: string) => store[key] ?? null,
      setItem: (key: string, val: string) => {
        store[key] = val;
      },
      removeItem: (key: string) => {
        delete store[key];
      },
    });
    // Mock WebSocket
    vi.stubGlobal(
      "WebSocket",
      class MockWebSocket {
        static OPEN = 1;
        readyState = 0;
        onopen: (() => void) | null = null;
        onmessage: ((ev: unknown) => void) | null = null;
        onclose: (() => void) | null = null;
        send = vi.fn();
        close = vi.fn();
      },
    );
    // Mock fetch for invoke
    vi.stubGlobal("fetch", vi.fn());
    // Mock window.location.origin
    vi.stubGlobal("location", { origin: "http://localhost:3000" });
  });

  it("getTransport returns singleton", async () => {
    const { getTransport } = await import("./transport");
    const t1 = getTransport();
    const t2 = getTransport();
    expect(t1).toBe(t2);
  });

  it("setHttpToken writes to sessionStorage", async () => {
    const { setHttpToken } = await import("./transport");
    setHttpToken("my-secret-token");
    expect(sessionStorage.getItem("pnevma_token")).toBe("my-secret-token");
  });

  it("getTransport returns Transport with expected methods", async () => {
    const { getTransport } = await import("./transport");
    const t = getTransport();
    expect(typeof t.invoke).toBe("function");
    expect(typeof t.subscribe).toBe("function");
    expect(typeof t.sendSessionInput).toBe("function");
    expect(typeof t.resizeSession).toBe("function");
  });
});
