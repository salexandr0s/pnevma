import { useEffect, useState } from "react";
import {
  connectSsh,
  deleteSshProfile,
  discoverTailscale,
  generateSshKey,
  importSshConfig,
  listSshKeys,
  listSshProfiles,
  upsertSshProfile,
} from "../../hooks/useTauri";
import type { SshKeyInfo, SshProfile } from "../../lib/types";

type Tab = "profiles" | "keys";
type SourceFilter = "all" | "ssh_config" | "tailscale" | "manual";

type AddFormState = {
  name: string;
  host: string;
  port: string;
  user: string;
  identity_file: string;
  proxy_jump: string;
  tags: string;
};

const EMPTY_FORM: AddFormState = {
  name: "",
  host: "",
  port: "22",
  user: "",
  identity_file: "",
  proxy_jump: "",
  tags: "",
};

function sourceBadgeClass(source: string): string {
  if (source === "tailscale") return "bg-cyan-500/20 text-cyan-300 border-cyan-400/30";
  if (source === "ssh_config") return "bg-violet-500/20 text-violet-300 border-violet-400/30";
  return "bg-slate-500/20 text-slate-300 border-slate-400/30";
}

function sourceBadgeLabel(source: string): string {
  if (source === "ssh_config") return "ssh_config";
  if (source === "tailscale") return "tailscale";
  return "manual";
}

export function SshManagerPane() {
  const [profiles, setProfiles] = useState<SshProfile[]>([]);
  const [keys, setKeys] = useState<SshKeyInfo[]>([]);
  const [loadingProfiles, setLoadingProfiles] = useState(false);
  const [loadingKeys, setLoadingKeys] = useState(false);
  const [actionBusy, setActionBusy] = useState(false);
  const [activeTab, setActiveTab] = useState<Tab>("profiles");
  const [filter, setFilter] = useState<SourceFilter>("all");
  const [showAddForm, setShowAddForm] = useState(false);
  const [form, setForm] = useState<AddFormState>(EMPTY_FORM);
  const [newKeyName, setNewKeyName] = useState("");
  const [statusMsg, setStatusMsg] = useState<string | null>(null);

  const refreshProfiles = async () => {
    setLoadingProfiles(true);
    try {
      setProfiles(await listSshProfiles());
    } catch {
      // noop
    } finally {
      setLoadingProfiles(false);
    }
  };

  const refreshKeys = async () => {
    setLoadingKeys(true);
    try {
      setKeys(await listSshKeys());
    } catch {
      // noop
    } finally {
      setLoadingKeys(false);
    }
  };

  useEffect(() => {
    void refreshProfiles();
    void refreshKeys();
  }, []);

  const handleImport = async () => {
    setActionBusy(true);
    try {
      await importSshConfig();
      await refreshProfiles();
      setStatusMsg("SSH config imported.");
    } catch (error) {
      setStatusMsg(error instanceof Error ? error.message : "import failed");
    } finally {
      setActionBusy(false);
    }
  };

  const handleDiscover = async () => {
    setActionBusy(true);
    try {
      await discoverTailscale();
      await refreshProfiles();
      setStatusMsg("Tailscale hosts discovered.");
    } catch (error) {
      setStatusMsg(error instanceof Error ? error.message : "discovery failed");
    } finally {
      setActionBusy(false);
    }
  };

  const handleConnect = async (profileId: string) => {
    setActionBusy(true);
    try {
      const sessionId = await connectSsh(profileId);
      setStatusMsg(`Connected — session ${sessionId}`);
    } catch (error) {
      setStatusMsg(error instanceof Error ? error.message : "connection failed");
    } finally {
      setActionBusy(false);
    }
  };

  const handleDelete = async (id: string) => {
    setActionBusy(true);
    try {
      await deleteSshProfile(id);
      await refreshProfiles();
    } catch (error) {
      setStatusMsg(error instanceof Error ? error.message : "delete failed");
    } finally {
      setActionBusy(false);
    }
  };

  const handleAddProfile = async () => {
    const portNum = parseInt(form.port, 10);
    setActionBusy(true);
    try {
      await upsertSshProfile({
        name: form.name.trim(),
        host: form.host.trim(),
        port: Number.isNaN(portNum) ? 22 : portNum,
        user: form.user.trim() || undefined,
        identity_file: form.identity_file.trim() || undefined,
        proxy_jump: form.proxy_jump.trim() || undefined,
        tags: form.tags
          .split(",")
          .map((t) => t.trim())
          .filter(Boolean),
        source: "manual",
      });
      setForm(EMPTY_FORM);
      setShowAddForm(false);
      await refreshProfiles();
    } catch (error) {
      setStatusMsg(error instanceof Error ? error.message : "add failed");
    } finally {
      setActionBusy(false);
    }
  };

  const handleGenerateKey = async () => {
    if (!newKeyName.trim()) return;
    setActionBusy(true);
    try {
      await generateSshKey({ name: newKeyName.trim() });
      setNewKeyName("");
      await refreshKeys();
      setStatusMsg("Key generated.");
    } catch (error) {
      setStatusMsg(error instanceof Error ? error.message : "key generation failed");
    } finally {
      setActionBusy(false);
    }
  };

  const filteredProfiles =
    filter === "all" ? profiles : profiles.filter((p) => p.source === filter);

  const filterOptions: { label: string; value: SourceFilter }[] = [
    { label: "All", value: "all" },
    { label: "SSH Config", value: "ssh_config" },
    { label: "Tailscale", value: "tailscale" },
    { label: "Manual", value: "manual" },
  ];

  return (
    <div className="flex h-full flex-col gap-3 overflow-auto">
      {statusMsg ? (
        <div className="rounded border border-mint-400/40 bg-mint-500/10 px-3 py-2 text-xs text-mint-200">
          {statusMsg}
          <button
            className="ml-2 text-slate-400 hover:text-slate-200"
            onClick={() => setStatusMsg(null)}
          >
            ×
          </button>
        </div>
      ) : null}

      {/* Tabs */}
      <div className="flex gap-1 border-b border-white/10 pb-2">
        <button
          onClick={() => setActiveTab("profiles")}
          className={`rounded-t px-3 py-1 text-xs font-medium ${
            activeTab === "profiles"
              ? "bg-mint-500/20 text-mint-300"
              : "text-slate-400 hover:text-slate-200"
          }`}
        >
          Profiles
        </button>
        <button
          onClick={() => setActiveTab("keys")}
          className={`rounded-t px-3 py-1 text-xs font-medium ${
            activeTab === "keys"
              ? "bg-mint-500/20 text-mint-300"
              : "text-slate-400 hover:text-slate-200"
          }`}
        >
          SSH Keys
        </button>
      </div>

      {activeTab === "profiles" && (
        <div className="flex flex-1 flex-col gap-3">
          {/* Toolbar */}
          <div className="flex flex-wrap items-center gap-2">
            {filterOptions.map((opt) => (
              <button
                key={opt.value}
                onClick={() => setFilter(opt.value)}
                className={`rounded-full border px-2 py-0.5 text-[11px] ${
                  filter === opt.value
                    ? "border-mint-400/60 bg-mint-500/20 text-mint-300"
                    : "border-white/10 text-slate-400 hover:border-white/30 hover:text-slate-200"
                }`}
              >
                {opt.label}
              </button>
            ))}
            <div className="ml-auto flex gap-2">
              <button
                disabled={actionBusy}
                onClick={() => void handleImport()}
                className="rounded bg-slate-700 px-2 py-1 text-xs text-slate-200 disabled:opacity-50 hover:bg-slate-600"
              >
                Import SSH Config
              </button>
              <button
                disabled={actionBusy}
                onClick={() => void handleDiscover()}
                className="rounded bg-slate-700 px-2 py-1 text-xs text-slate-200 disabled:opacity-50 hover:bg-slate-600"
              >
                Discover Tailscale
              </button>
              <button
                onClick={() => setShowAddForm((v) => !v)}
                className="rounded bg-mint-500 px-2 py-1 text-xs font-semibold text-slate-950 hover:bg-mint-400"
              >
                {showAddForm ? "Cancel" : "Add Profile"}
              </button>
            </div>
          </div>

          {/* Add Profile Form */}
          {showAddForm && (
            <div className="rounded-lg border border-white/10 bg-slate-900/60 p-3">
              <div className="mb-2 text-xs font-semibold text-slate-200">New SSH Profile</div>
              <div className="grid grid-cols-2 gap-2">
                {[
                  { key: "name", label: "Name", placeholder: "my-server" },
                  { key: "host", label: "Host", placeholder: "192.168.1.1" },
                  { key: "port", label: "Port", placeholder: "22" },
                  { key: "user", label: "User", placeholder: "ubuntu" },
                  {
                    key: "identity_file",
                    label: "Identity File",
                    placeholder: "~/.ssh/id_rsa",
                  },
                  {
                    key: "proxy_jump",
                    label: "Proxy Jump",
                    placeholder: "bastion.example.com",
                  },
                  {
                    key: "tags",
                    label: "Tags (comma-separated)",
                    placeholder: "prod, web",
                  },
                ].map(({ key, label, placeholder }) => (
                  <label key={key} className="block text-[11px] text-slate-400">
                    {label}
                    <input
                      className="mt-1 w-full rounded border border-white/20 bg-slate-900 px-2 py-1 text-xs text-slate-100 outline-none focus:border-mint-400"
                      placeholder={placeholder}
                      value={form[key as keyof AddFormState]}
                      onChange={(e) =>
                        setForm((prev) => ({ ...prev, [key]: e.target.value }))
                      }
                    />
                  </label>
                ))}
              </div>
              <button
                disabled={actionBusy || !form.name.trim() || !form.host.trim()}
                onClick={() => void handleAddProfile()}
                className="mt-3 rounded bg-mint-500 px-3 py-1 text-xs font-semibold text-slate-950 disabled:opacity-50 hover:bg-mint-400"
              >
                Save Profile
              </button>
            </div>
          )}

          {/* Profile list */}
          {loadingProfiles ? (
            <div className="text-xs text-slate-400">Loading profiles...</div>
          ) : filteredProfiles.length === 0 ? (
            <div className="text-xs text-slate-500">No profiles found.</div>
          ) : (
            <div className="space-y-2">
              {filteredProfiles.map((profile) => (
                <div
                  key={profile.id}
                  className="flex items-start justify-between gap-3 rounded-lg border border-white/10 bg-slate-950/70 px-3 py-2"
                >
                  <div className="min-w-0 flex-1">
                    <div className="flex items-center gap-2">
                      <span className="text-sm font-medium text-slate-100">{profile.name}</span>
                      <span
                        className={`rounded border px-1.5 py-0.5 text-[10px] ${sourceBadgeClass(
                          profile.source
                        )}`}
                      >
                        {sourceBadgeLabel(profile.source)}
                      </span>
                    </div>
                    <div className="mt-0.5 text-xs text-slate-400">
                      {profile.user ? `${profile.user}@` : ""}
                      {profile.host}
                      {profile.port !== 22 ? `:${profile.port}` : ""}
                    </div>
                    {profile.tags.length > 0 && (
                      <div className="mt-1 flex flex-wrap gap-1">
                        {profile.tags.map((tag) => (
                          <span
                            key={tag}
                            className="rounded border border-white/10 bg-slate-800/60 px-1.5 py-0.5 text-[10px] text-slate-300"
                          >
                            {tag}
                          </span>
                        ))}
                      </div>
                    )}
                  </div>
                  <div className="flex shrink-0 gap-1">
                    <button
                      disabled={actionBusy}
                      onClick={() => void handleConnect(profile.id)}
                      className="rounded bg-mint-500 px-2 py-1 text-xs font-semibold text-slate-950 disabled:opacity-50 hover:bg-mint-400"
                    >
                      Connect
                    </button>
                    <button
                      disabled={actionBusy}
                      onClick={() => void handleDelete(profile.id)}
                      className="rounded bg-rose-500/20 px-2 py-1 text-xs text-rose-300 border border-rose-400/30 disabled:opacity-50 hover:bg-rose-500/30"
                    >
                      Delete
                    </button>
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>
      )}

      {activeTab === "keys" && (
        <div className="flex flex-1 flex-col gap-3">
          {/* Generate key */}
          <div className="flex items-center gap-2">
            <input
              className="rounded border border-white/20 bg-slate-900 px-2 py-1 text-xs text-slate-100 outline-none focus:border-mint-400"
              placeholder="Key name (e.g. id_ed25519)"
              value={newKeyName}
              onChange={(e) => setNewKeyName(e.target.value)}
            />
            <button
              disabled={actionBusy || !newKeyName.trim()}
              onClick={() => void handleGenerateKey()}
              className="rounded bg-mint-500 px-2 py-1 text-xs font-semibold text-slate-950 disabled:opacity-50 hover:bg-mint-400"
            >
              Generate New Key
            </button>
          </div>

          {loadingKeys ? (
            <div className="text-xs text-slate-400">Loading keys...</div>
          ) : keys.length === 0 ? (
            <div className="text-xs text-slate-500">No SSH keys found.</div>
          ) : (
            <div className="space-y-2">
              {keys.map((key) => (
                <div
                  key={key.path}
                  className="rounded-lg border border-white/10 bg-slate-950/70 px-3 py-2"
                >
                  <div className="flex items-center gap-2">
                    <span className="text-sm font-medium text-slate-100">{key.name}</span>
                    <span className="rounded border border-violet-400/30 bg-violet-500/20 px-1.5 py-0.5 text-[10px] text-violet-300">
                      {key.key_type}
                    </span>
                  </div>
                  <div className="mt-0.5 text-[11px] text-slate-400">{key.path}</div>
                  <div className="mt-0.5 font-mono text-[10px] text-slate-500">{key.fingerprint}</div>
                </div>
              ))}
            </div>
          )}
        </div>
      )}
    </div>
  );
}
