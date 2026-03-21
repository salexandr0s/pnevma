use crate::adapters::{claude::ClaudeCodeAdapter, codex::CodexAdapter};
use crate::model::AgentAdapter;
use std::collections::HashMap;
use std::sync::Arc;
use tracing::{debug, info, warn};

const DETECT_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(5);

#[derive(Default, Clone)]
pub struct AdapterRegistry {
    adapters: HashMap<String, Arc<dyn AgentAdapter>>,
}

impl AdapterRegistry {
    /// Detect available agent adapters asynchronously.
    ///
    /// Uses `tokio::process::Command` with a 5-second timeout for each binary
    /// check to avoid blocking the runtime on slow PATH lookups.
    ///
    /// PATH is augmented with common macOS binary locations so that detection
    /// works even when the process inherits a minimal GUI-app PATH.
    pub async fn detect() -> Self {
        let mut registry = Self::default();
        let augmented = build_augmented_path();
        debug!(path = %augmented, "agent adapter detection starting");

        // Persist the augmented PATH into the process environment so that
        // subsequent `Command::new("claude")` / `Command::new("codex")` in the
        // adapter spawn paths resolve correctly. Without this, detection
        // succeeds but spawning fails because the adapters call env_clear()
        // and re-read PATH from `std::env::var("PATH")`.
        //
        // safe in Rust 2021 edition; the call happens once before any agent
        // spawns, so there is no concurrent reader concern.
        std::env::set_var("PATH", &augmented);

        let claude_found = which_async_with_path("claude", &augmented).await;
        info!(
            binary = "claude",
            found = claude_found,
            "agent binary probe"
        );
        if claude_found {
            registry.adapters.insert(
                "claude-code".to_string(),
                Arc::new(ClaudeCodeAdapter::new()),
            );
        }

        let codex_found = which_async_with_path("codex", &augmented).await;
        info!(binary = "codex", found = codex_found, "agent binary probe");
        if codex_found {
            // Detect if codex supports app-server mode and register v2 adapter.
            let supports_v2 = tokio::time::timeout(
                DETECT_TIMEOUT,
                tokio::process::Command::new("codex")
                    .args(["app-server", "--help"])
                    .env("PATH", &augmented)
                    .env("TERM", "dumb")
                    .env("CI", "true")
                    .env_remove("TERM_PROGRAM")
                    .output(),
            )
            .await
            .ok()
            .and_then(|r| r.ok())
            .map(|o| o.status.success())
            .unwrap_or(false);

            if supports_v2 {
                let v2: Arc<dyn AgentAdapter> =
                    Arc::new(crate::adapters::codex_v2::CodexV2Adapter::new());
                // Register under both names so existing configs using `provider: "codex"` get
                // the v2 adapter transparently.
                registry
                    .adapters
                    .insert("codex".to_string(), Arc::clone(&v2));
                registry.adapters.insert("codex-v2".to_string(), v2);
            } else {
                // Legacy one-shot adapter only when v2 is unavailable.
                registry
                    .adapters
                    .insert("codex".to_string(), Arc::new(CodexAdapter::new()));
            }
        }

        info!(adapters = ?registry.available(), "agent adapter detection complete");
        if registry.adapters.is_empty() {
            warn!("no agent adapters detected — dispatch will fail. Ensure 'claude' or 'codex' is installed and on PATH.");
        }
        registry
    }

    /// Synchronous version of `detect()` for contexts where async is not available.
    pub fn detect_sync() -> Self {
        let mut registry = Self::default();
        let augmented = build_augmented_path();

        // See comment in detect() — same rationale for the sync path.
        std::env::set_var("PATH", &augmented);

        let claude_found = which_sync_with_path("claude", &augmented);
        info!(
            binary = "claude",
            found = claude_found,
            "agent binary probe (sync)"
        );
        if claude_found {
            registry.adapters.insert(
                "claude-code".to_string(),
                Arc::new(ClaudeCodeAdapter::new()),
            );
        }

        let codex_found = which_sync_with_path("codex", &augmented);
        info!(
            binary = "codex",
            found = codex_found,
            "agent binary probe (sync)"
        );
        if codex_found {
            let supports_v2 = std::process::Command::new("codex")
                .args(["app-server", "--help"])
                .env("PATH", &augmented)
                .env("TERM", "dumb")
                .env("CI", "true")
                .env_remove("TERM_PROGRAM")
                .output()
                .map(|o| o.status.success())
                .unwrap_or(false);

            if supports_v2 {
                let v2: Arc<dyn AgentAdapter> =
                    Arc::new(crate::adapters::codex_v2::CodexV2Adapter::new());
                registry
                    .adapters
                    .insert("codex".to_string(), Arc::clone(&v2));
                registry.adapters.insert("codex-v2".to_string(), v2);
            } else {
                registry
                    .adapters
                    .insert("codex".to_string(), Arc::new(CodexAdapter::new()));
            }
        }

        info!(adapters = ?registry.available(), "agent adapter detection complete (sync)");
        if registry.adapters.is_empty() {
            warn!("no agent adapters detected (sync) — dispatch will fail.");
        }
        registry
    }

    pub fn register(&mut self, provider: impl Into<String>, adapter: Arc<dyn AgentAdapter>) {
        self.adapters.insert(provider.into(), adapter);
    }

    pub fn get(&self, provider: &str) -> Option<Arc<dyn AgentAdapter>> {
        self.adapters.get(provider).cloned()
    }

    pub fn available(&self) -> Vec<String> {
        let mut keys: Vec<_> = self.adapters.keys().cloned().collect();
        keys.sort();
        keys
    }

    pub fn is_empty(&self) -> bool {
        self.adapters.is_empty()
    }
}

/// Build a PATH string augmented with common macOS binary installation directories.
///
/// macOS GUI apps launched from Dock/Spotlight inherit a minimal PATH
/// (`/usr/bin:/bin:/usr/sbin:/sbin`), so tools like `claude` in `~/.local/bin`
/// or `codex` in `/opt/homebrew/bin` are not found. This function prepends
/// well-known directories to the current PATH.
fn build_augmented_path() -> String {
    let home = std::env::var("HOME").unwrap_or_default();
    let current_path = std::env::var("PATH").unwrap_or_default();

    let extra_dirs = [
        format!("{home}/.local/bin"),
        "/opt/homebrew/bin".to_string(),
        "/usr/local/bin".to_string(),
        format!("{home}/.cargo/bin"),
    ];

    let mut parts: Vec<String> = extra_dirs
        .into_iter()
        .filter(|d| !d.is_empty() && !d.starts_with("/."))
        .collect();

    if !current_path.is_empty() {
        parts.push(current_path);
    }

    parts.join(":")
}

async fn which_async_with_path(binary: &str, path: &str) -> bool {
    tokio::time::timeout(
        DETECT_TIMEOUT,
        tokio::process::Command::new("which")
            .arg(binary)
            .env("PATH", path)
            .output(),
    )
    .await
    .ok()
    .and_then(|r| r.ok())
    .map(|o| o.status.success())
    .unwrap_or(false)
}

fn which_sync_with_path(binary: &str, path: &str) -> bool {
    std::process::Command::new("which")
        .arg(binary)
        .env("PATH", path)
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn build_augmented_path_includes_common_dirs() {
        let path = build_augmented_path();
        assert!(
            path.contains("/opt/homebrew/bin"),
            "missing /opt/homebrew/bin"
        );
        assert!(path.contains("/usr/local/bin"), "missing /usr/local/bin");
        assert!(path.contains("/.local/bin"), "missing ~/.local/bin");
        assert!(path.contains("/.cargo/bin"), "missing ~/.cargo/bin");
    }

    #[test]
    fn build_augmented_path_preserves_existing_path() {
        // Current PATH should be appended at the end
        let path = build_augmented_path();
        let current = std::env::var("PATH").unwrap_or_default();
        if !current.is_empty() {
            assert!(
                path.ends_with(&current),
                "existing PATH should be at the end"
            );
        }
    }

    #[test]
    fn register_and_get_adapter() {
        use crate::adapters::claude::ClaudeCodeAdapter;

        let mut registry = AdapterRegistry::default();
        assert!(registry.is_empty());
        assert!(registry.get("claude-code").is_none());

        registry.register("claude-code", Arc::new(ClaudeCodeAdapter::new()));
        assert!(!registry.is_empty());
        assert!(registry.get("claude-code").is_some());
        assert!(registry.get("nonexistent").is_none());
    }

    #[test]
    fn available_returns_sorted_keys() {
        use crate::adapters::claude::ClaudeCodeAdapter;

        let mut registry = AdapterRegistry::default();
        registry.register("codex", Arc::new(ClaudeCodeAdapter::new()));
        registry.register("claude-code", Arc::new(ClaudeCodeAdapter::new()));
        registry.register("alpha", Arc::new(ClaudeCodeAdapter::new()));

        let keys = registry.available();
        assert_eq!(keys, vec!["alpha", "claude-code", "codex"]);
    }
}
