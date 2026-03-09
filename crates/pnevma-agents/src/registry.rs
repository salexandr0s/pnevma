use crate::adapters::{claude::ClaudeCodeAdapter, codex::CodexAdapter};
use crate::model::AgentAdapter;
use std::collections::HashMap;
use std::sync::Arc;

#[derive(Default, Clone)]
pub struct AdapterRegistry {
    adapters: HashMap<String, Arc<dyn AgentAdapter>>,
}

impl AdapterRegistry {
    pub fn detect() -> Self {
        let mut registry = Self::default();

        if which("claude") {
            registry.adapters.insert(
                "claude-code".to_string(),
                Arc::new(ClaudeCodeAdapter::new()),
            );
        }
        if which("codex") {
            // Detect if codex supports app-server mode and register v2 adapter.
            let supports_v2 = std::process::Command::new("codex")
                .args(["app-server", "--help"])
                .output()
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
}

fn which(binary: &str) -> bool {
    std::process::Command::new("which")
        .arg(binary)
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}
