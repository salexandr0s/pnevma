import React, { useState } from "react";
import { setHttpToken } from "../lib/transport";

export function LoginPage({ onLogin }: { onLogin: () => void }) {
  const [password, setPassword] = useState("");
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setLoading(true);
    setError("");
    try {
      const res = await fetch("/api/auth/token", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ password }),
      });
      if (!res.ok) {
        setError(res.status === 429 ? "Too many attempts. Try again later." : "Invalid password.");
        return;
      }
      const data = (await res.json()) as { token: string };
      sessionStorage.setItem("pnevma_token", data.token);
      setHttpToken(data.token);
      onLogin();
    } catch {
      setError("Connection failed.");
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="flex min-h-screen items-center justify-center bg-slate-950">
      <form onSubmit={handleSubmit} className="w-full max-w-sm space-y-4 rounded-xl border border-white/10 bg-slate-900 p-8">
        <h1 className="text-xl font-semibold text-white">Pnevma Remote</h1>
        <p className="text-sm text-slate-400">Enter your password to connect.</p>
        <input
          type="password"
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          placeholder="Password"
          className="w-full rounded-lg border border-white/10 bg-slate-800 px-4 py-2 text-white placeholder:text-slate-500 focus:border-blue-500 focus:outline-none"
          autoFocus
        />
        {error && <p className="text-sm text-red-400">{error}</p>}
        <button
          type="submit"
          disabled={loading || !password}
          className="w-full rounded-lg bg-blue-600 px-4 py-2 text-white font-medium hover:bg-blue-500 disabled:opacity-50"
        >
          {loading ? "Connecting..." : "Connect"}
        </button>
      </form>
    </div>
  );
}
