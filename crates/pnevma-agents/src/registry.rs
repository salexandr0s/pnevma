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
            registry
                .adapters
                .insert("codex".to_string(), Arc::new(CodexAdapter::new()));
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
