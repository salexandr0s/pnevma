use pnevma_core::workflow_contract::{WorkflowDocument, WorkflowMdConfig, WorkflowParseError};
use std::path::PathBuf;
use std::time::SystemTime;
use tokio::sync::RwLock;
use tracing::{debug, warn};

pub struct WorkflowStore {
    path: PathBuf,
    current: RwLock<Option<WorkflowDocument>>,
    last_hash: RwLock<Option<String>>,
    last_mtime: RwLock<Option<SystemTime>>,
}

impl WorkflowStore {
    pub fn new(project_path: &std::path::Path) -> Self {
        Self {
            path: project_path.join("WORKFLOW.md"),
            current: RwLock::new(None),
            last_hash: RwLock::new(None),
            last_mtime: RwLock::new(None),
        }
    }

    /// Initial load. Returns true if successfully loaded.
    pub async fn load(&self) -> bool {
        match WorkflowDocument::from_file(&self.path) {
            Ok(doc) => {
                match doc.validate() {
                    Ok(()) => {}
                    Err(e) => {
                        warn!(path = %self.path.display(), error = %e, "WORKFLOW.md validation failed on initial load");
                        return false;
                    }
                }
                let hash = doc.source_hash.clone();
                let mtime = std::fs::metadata(&self.path)
                    .ok()
                    .and_then(|m| m.modified().ok());

                *self.current.write().await = Some(doc);
                *self.last_hash.write().await = Some(hash);
                *self.last_mtime.write().await = mtime;

                debug!(path = %self.path.display(), "WORKFLOW.md loaded successfully");
                true
            }
            Err(WorkflowParseError::Io(e)) if e.kind() == std::io::ErrorKind::NotFound => {
                debug!(path = %self.path.display(), "WORKFLOW.md not found, using defaults");
                false
            }
            Err(e) => {
                warn!(path = %self.path.display(), error = %e, "Failed to load WORKFLOW.md");
                false
            }
        }
    }

    /// Check if file changed since last load. Reloads if needed. Returns true if reloaded.
    pub async fn check_reload(&self) -> bool {
        // 1. Check if file exists
        let metadata = match std::fs::metadata(&self.path) {
            Ok(m) => m,
            Err(_) => {
                // File disappeared — retain last known good, don't signal reload
                return false;
            }
        };

        // 2. Get mtime, compare with last_mtime (cheap check)
        let current_mtime = metadata.modified().ok();
        let last_mtime = *self.last_mtime.read().await;

        if current_mtime == last_mtime && last_mtime.is_some() {
            // 3. mtime unchanged
            return false;
        }

        // 4. Read file, compute hash
        let content = match std::fs::read_to_string(&self.path) {
            Ok(c) => c,
            Err(e) => {
                warn!(path = %self.path.display(), error = %e, "Failed to read WORKFLOW.md during reload check");
                return false;
            }
        };

        use sha2::{Digest, Sha256};
        let mut hasher = Sha256::new();
        hasher.update(content.as_bytes());
        let new_hash = format!("{:x}", hasher.finalize());

        let last_hash = self.last_hash.read().await.clone();

        // 5. If hash matches last_hash, update mtime only, return false
        if Some(&new_hash) == last_hash.as_ref() {
            *self.last_mtime.write().await = current_mtime;
            return false;
        }

        // 6. Parse new content
        let doc = match WorkflowDocument::parse(&content) {
            Ok(d) => d,
            Err(e) => {
                // 7. On parse failure: log warning, retain last-known-good, return false
                warn!(path = %self.path.display(), error = %e, "Failed to parse WORKFLOW.md during reload, retaining last-known-good");
                return false;
            }
        };

        // Validate before accepting
        if let Err(e) = doc.validate() {
            warn!(path = %self.path.display(), error = %e, "WORKFLOW.md validation failed during reload, retaining last-known-good");
            return false;
        }

        // 8. On success: store new document, update hash/mtime, return true
        debug!(path = %self.path.display(), hash = %new_hash, "WORKFLOW.md reloaded");
        *self.current.write().await = Some(doc);
        *self.last_hash.write().await = Some(new_hash);
        *self.last_mtime.write().await = current_mtime;

        true
    }

    /// Get current WorkflowDocument if loaded.
    pub async fn current(&self) -> Option<WorkflowDocument> {
        self.current.read().await.clone()
    }

    /// Get effective config (from WORKFLOW.md or defaults).
    pub async fn effective_config(&self) -> WorkflowMdConfig {
        if let Some(doc) = self.current.read().await.as_ref() {
            doc.config.clone()
        } else {
            WorkflowMdConfig::default()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const VALID_WORKFLOW: &str =
        "---\nenabled: true\npoll_interval_seconds: 15\nmax_concurrent: 3\n---\n# Workflow\n";

    #[tokio::test]
    async fn load_succeeds_for_valid_file() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("WORKFLOW.md"), VALID_WORKFLOW).unwrap();
        let store = WorkflowStore::new(dir.path());
        assert!(store.load().await);
        let doc = store.current().await;
        assert!(doc.is_some());
        assert!(doc.unwrap().config.enabled);
    }

    #[tokio::test]
    async fn load_returns_false_when_file_missing() {
        let dir = tempfile::tempdir().unwrap();
        let store = WorkflowStore::new(dir.path());
        assert!(!store.load().await);
        assert!(store.current().await.is_none());
    }

    #[tokio::test]
    async fn check_reload_detects_content_change() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("WORKFLOW.md");
        std::fs::write(&path, VALID_WORKFLOW).unwrap();
        let store = WorkflowStore::new(dir.path());
        assert!(store.load().await);

        // Modify content
        let modified =
            "---\nenabled: false\npoll_interval_seconds: 60\nmax_concurrent: 5\n---\n# Updated\n";
        // Need a different mtime — sleep briefly or just write + touch
        std::thread::sleep(std::time::Duration::from_millis(50));
        std::fs::write(&path, modified).unwrap();

        assert!(store.check_reload().await);
        let doc = store.current().await.unwrap();
        assert!(!doc.config.enabled);
        assert_eq!(doc.config.poll_interval_seconds, 60);
    }

    #[tokio::test]
    async fn check_reload_preserves_last_good_on_parse_error() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("WORKFLOW.md");
        std::fs::write(&path, VALID_WORKFLOW).unwrap();
        let store = WorkflowStore::new(dir.path());
        assert!(store.load().await);

        // Overwrite with garbage
        std::thread::sleep(std::time::Duration::from_millis(50));
        std::fs::write(&path, "this is not valid WORKFLOW.md at all").unwrap();

        // Reload should return false (parse failed), but original doc preserved
        assert!(!store.check_reload().await);
        let doc = store.current().await.unwrap();
        assert!(doc.config.enabled); // Original config still there
    }

    #[tokio::test]
    async fn effective_config_returns_defaults_when_no_file() {
        let dir = tempfile::tempdir().unwrap();
        let store = WorkflowStore::new(dir.path());
        // No load, no file
        let config = store.effective_config().await;
        let defaults = WorkflowMdConfig::default();
        assert_eq!(config.enabled, defaults.enabled);
        assert_eq!(config.poll_interval_seconds, defaults.poll_interval_seconds);
        assert_eq!(config.max_concurrent, defaults.max_concurrent);
    }
}
