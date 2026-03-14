use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use tracing::debug;

use crate::state::AppState;

// ── Types ───────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HarnessConfigEntry {
    pub key: String,
    pub display_name: String,
    pub path: String,
    pub format: String,
    pub exists: bool,
    pub category: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HarnessConfigContent {
    pub key: String,
    pub content: String,
    pub format: String,
    pub path: String,
}

// ── Allowlist ───────────────────────────────────────────────────────────────

struct AllowlistEntry {
    key: &'static str,
    rel_path: &'static str,
    display_name: &'static str,
    format: &'static str,
    category: &'static str,
}

const ALLOWLIST: &[AllowlistEntry] = &[
    AllowlistEntry {
        key: "claude.settings",
        rel_path: ".claude/settings.json",
        display_name: "Claude Settings",
        format: "json",
        category: "settings",
    },
    AllowlistEntry {
        key: "claude.settings_local",
        rel_path: ".claude/settings.local.json",
        display_name: "Claude Settings (Local)",
        format: "json",
        category: "settings",
    },
    AllowlistEntry {
        key: "claude.mcp",
        rel_path: ".claude/.mcp.json",
        display_name: "MCP Servers",
        format: "json",
        category: "mcp",
    },
    AllowlistEntry {
        key: "claude.hooks",
        rel_path: ".claude/hooks.json",
        display_name: "Claude Hooks",
        format: "json",
        category: "hooks",
    },
    AllowlistEntry {
        key: "codex.config",
        rel_path: ".codex/config.toml",
        display_name: "Codex Config",
        format: "toml",
        category: "settings",
    },
];

// ── Dynamic discovery patterns ──────────────────────────────────────────────

struct DynamicPattern {
    dir: &'static str,
    glob: &'static str,
    category: &'static str,
    format: &'static str,
    key_prefix: &'static str,
}

const DYNAMIC_PATTERNS: &[DynamicPattern] = &[
    DynamicPattern {
        dir: ".claude/agents",
        glob: "*.md",
        category: "agents",
        format: "markdown",
        key_prefix: "claude.agent.",
    },
    DynamicPattern {
        dir: ".claude/skills",
        glob: "*/SKILL.md",
        category: "skills",
        format: "markdown",
        key_prefix: "claude.skill.",
    },
    DynamicPattern {
        dir: ".claude/uiux-contract",
        glob: "*",
        category: "design",
        format: "yaml",
        key_prefix: "claude.design.",
    },
    DynamicPattern {
        dir: ".codex/memories",
        glob: "*.md",
        category: "memory",
        format: "markdown",
        key_prefix: "codex.memory.",
    },
    DynamicPattern {
        dir: ".codex/rules",
        glob: "*.md",
        category: "rules",
        format: "markdown",
        key_prefix: "codex.rule.",
    },
];

// ── Helpers ─────────────────────────────────────────────────────────────────

fn home_dir() -> Result<PathBuf, String> {
    std::env::var("HOME")
        .map(PathBuf::from)
        .map_err(|_| "HOME environment variable not set".to_string())
}

fn resolve_key_to_path(key: &str) -> Result<PathBuf, String> {
    let home = home_dir()?;

    // Check static allowlist
    for entry in ALLOWLIST {
        if entry.key == key {
            return Ok(home.join(entry.rel_path));
        }
    }

    // Check dynamic entries — key must start with a known prefix and resolve
    // to a path under ~/.claude/ or ~/.codex/
    for pattern in DYNAMIC_PATTERNS {
        if let Some(suffix) = key.strip_prefix(pattern.key_prefix) {
            // Prevent path traversal in the suffix
            if suffix.contains("..") || suffix.contains('/') || suffix.contains('\\') {
                return Err("invalid key: path traversal detected".to_string());
            }
            let dir = home.join(pattern.dir);
            // For skills pattern (*/SKILL.md), suffix is the skill dir name
            if pattern.glob == "*/SKILL.md" {
                return Ok(dir.join(suffix).join("SKILL.md"));
            }
            return Ok(dir.join(suffix));
        }
    }

    // Check memory entries — special handling for project memories
    if let Some(suffix) = key.strip_prefix("claude.memory.") {
        if suffix.contains("..") || suffix.contains('/') || suffix.contains('\\') {
            return Err("invalid key: path traversal detected".to_string());
        }
        let path = home
            .join(".claude/projects")
            .join(suffix)
            .join("memory/MEMORY.md");
        return Ok(path);
    }

    Err(format!("unknown harness config key: {key}"))
}

fn format_for_path(path: &Path) -> &'static str {
    match path.extension().and_then(|e| e.to_str()) {
        Some("json") => "json",
        Some("toml") => "toml",
        Some("yaml") | Some("yml") => "yaml",
        Some("md") => "markdown",
        _ => "text",
    }
}

fn category_for_key(key: &str) -> &'static str {
    for entry in ALLOWLIST {
        if entry.key == key {
            return entry.category;
        }
    }
    for pattern in DYNAMIC_PATTERNS {
        if key.starts_with(pattern.key_prefix) {
            return pattern.category;
        }
    }
    if key.starts_with("claude.memory.") {
        return "memory";
    }
    "unknown"
}

fn discover_dynamic_entries(home: &Path) -> Vec<HarnessConfigEntry> {
    let mut entries = Vec::new();

    for pattern in DYNAMIC_PATTERNS {
        let dir = home.join(pattern.dir);
        if !dir.is_dir() {
            continue;
        }
        let read_dir = match std::fs::read_dir(&dir) {
            Ok(rd) => rd,
            Err(_) => continue,
        };
        for entry in read_dir.flatten() {
            let path = entry.path();

            // Handle the skill pattern (subdir/SKILL.md)
            if pattern.glob == "*/SKILL.md" {
                if path.is_dir() {
                    let skill_file = path.join("SKILL.md");
                    if skill_file.is_file() {
                        let name = path.file_name().unwrap_or_default().to_string_lossy();
                        entries.push(HarnessConfigEntry {
                            key: format!("{}{}", pattern.key_prefix, name),
                            display_name: format!("Skill: {name}"),
                            path: skill_file.to_string_lossy().to_string(),
                            format: pattern.format.to_string(),
                            exists: true,
                            category: pattern.category.to_string(),
                        });
                    }
                }
                continue;
            }

            // Handle simple glob (*.md, *)
            if !path.is_file() {
                continue;
            }
            let name = path.file_name().unwrap_or_default().to_string_lossy();

            // Match the glob pattern
            if pattern.glob == "*" || name.ends_with(&pattern.glob[1..]) {
                let fmt = if pattern.category == "design" {
                    format_for_path(&path)
                } else {
                    pattern.format
                };
                entries.push(HarnessConfigEntry {
                    key: format!("{}{}", pattern.key_prefix, name),
                    display_name: name.to_string(),
                    path: path.to_string_lossy().to_string(),
                    format: fmt.to_string(),
                    exists: true,
                    category: pattern.category.to_string(),
                });
            }
        }
    }

    // Discover project memory files
    let projects_dir = home.join(".claude/projects");
    if projects_dir.is_dir() {
        if let Ok(read_dir) = std::fs::read_dir(&projects_dir) {
            for entry in read_dir.flatten() {
                let path = entry.path();
                if !path.is_dir() {
                    continue;
                }
                let memory_file = path.join("memory/MEMORY.md");
                if memory_file.is_file() {
                    let project_name = path.file_name().unwrap_or_default().to_string_lossy();
                    entries.push(HarnessConfigEntry {
                        key: format!("claude.memory.{project_name}"),
                        display_name: format!("Memory: {project_name}"),
                        path: memory_file.to_string_lossy().to_string(),
                        format: "markdown".to_string(),
                        exists: true,
                        category: "memory".to_string(),
                    });
                }
            }
        }
    }

    entries
}

fn validate_content(content: &str, format: &str) -> Result<(), String> {
    match format {
        "json" => {
            serde_json::from_str::<Value>(content).map_err(|e| format!("invalid JSON: {e}"))?;
        }
        "toml" => {
            content
                .parse::<toml::Table>()
                .map_err(|e| format!("invalid TOML: {e}"))?;
        }
        // YAML and markdown don't need strict validation
        _ => {}
    }
    Ok(())
}

fn create_backup(path: &Path) -> Result<(), String> {
    if !path.is_file() {
        return Ok(());
    }
    let home = home_dir()?;
    let backup_dir = if path.starts_with(home.join(".codex")) {
        home.join(".codex/backups")
    } else {
        home.join(".claude/backups")
    };
    std::fs::create_dir_all(&backup_dir)
        .map_err(|e| format!("failed to create backup dir: {e}"))?;

    let filename = path.file_name().unwrap_or_default().to_string_lossy();
    let timestamp = chrono::Utc::now().format("%Y%m%d_%H%M%S");
    let backup_name = format!("{filename}.{timestamp}.bak");
    let backup_path = backup_dir.join(backup_name);

    std::fs::copy(path, &backup_path).map_err(|e| format!("failed to create backup: {e}"))?;
    debug!(backup = %backup_path.display(), "created harness config backup");
    Ok(())
}

// ── RPC handlers ────────────────────────────────────────────────────────────

pub async fn list_harness_configs(_state: &AppState) -> Result<Vec<HarnessConfigEntry>, String> {
    let home = home_dir()?;
    let mut entries = Vec::new();

    // Static allowlist entries
    for item in ALLOWLIST {
        let path = home.join(item.rel_path);
        entries.push(HarnessConfigEntry {
            key: item.key.to_string(),
            display_name: item.display_name.to_string(),
            path: path.to_string_lossy().to_string(),
            format: item.format.to_string(),
            exists: path.is_file(),
            category: item.category.to_string(),
        });
    }

    // Dynamic entries discovered from directories
    entries.extend(discover_dynamic_entries(&home));

    Ok(entries)
}

#[derive(Debug, Deserialize)]
pub struct ReadHarnessConfigInput {
    pub key: String,
}

pub async fn read_harness_config(
    input: ReadHarnessConfigInput,
    _state: &AppState,
) -> Result<HarnessConfigContent, String> {
    let path = resolve_key_to_path(&input.key)?;

    if !path.is_file() {
        return Err(format!("file does not exist: {}", path.display()));
    }

    let content = tokio::fs::read_to_string(&path)
        .await
        .map_err(|e| format!("failed to read {}: {e}", path.display()))?;

    Ok(HarnessConfigContent {
        key: input.key.clone(),
        content,
        format: format_for_path(&path).to_string(),
        path: path.to_string_lossy().to_string(),
    })
}

#[derive(Debug, Deserialize)]
pub struct WriteHarnessConfigInput {
    pub key: String,
    pub content: String,
}

pub async fn write_harness_config(
    input: WriteHarnessConfigInput,
    _state: &AppState,
) -> Result<Value, String> {
    let path = resolve_key_to_path(&input.key)?;
    let category = category_for_key(&input.key);
    let format = format_for_path(&path);

    // Only memory category files can be created new
    if !path.is_file() && category != "memory" {
        return Err(format!(
            "file does not exist and category '{}' does not allow creation: {}",
            category,
            path.display()
        ));
    }

    // Validate content syntax before writing
    validate_content(&input.content, format)?;

    // Create backup of existing file
    create_backup(&path)?;

    // Ensure parent directory exists (for memory files that may not exist yet)
    if let Some(parent) = path.parent() {
        tokio::fs::create_dir_all(parent)
            .await
            .map_err(|e| format!("failed to create directory: {e}"))?;
    }

    // Atomic write via temp file + rename
    let parent = path.parent().ok_or("invalid path")?;
    let temp_path = parent.join(format!(
        ".tmp_{}",
        path.file_name().unwrap_or_default().to_string_lossy()
    ));

    tokio::fs::write(&temp_path, &input.content)
        .await
        .map_err(|e| format!("failed to write temp file: {e}"))?;

    tokio::fs::rename(&temp_path, &path).await.map_err(|e| {
        // Clean up temp file on rename failure
        let _ = std::fs::remove_file(&temp_path);
        format!("failed to rename temp file: {e}")
    })?;

    debug!(key = %input.key, path = %path.display(), "wrote harness config");

    Ok(json!({
        "ok": true,
        "path": path.to_string_lossy(),
    }))
}

// ── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_resolve_allowlist_keys() {
        // These should not error (path resolution is independent of file existence)
        assert!(resolve_key_to_path("claude.settings").is_ok());
        assert!(resolve_key_to_path("claude.mcp").is_ok());
        assert!(resolve_key_to_path("codex.config").is_ok());
    }

    #[test]
    fn test_resolve_unknown_key_errors() {
        assert!(resolve_key_to_path("unknown.key").is_err());
    }

    #[test]
    fn test_resolve_dynamic_key() {
        let result = resolve_key_to_path("claude.agent.my-agent.md");
        assert!(result.is_ok());
        let path = result.unwrap();
        assert!(path
            .to_string_lossy()
            .contains(".claude/agents/my-agent.md"));
    }

    #[test]
    fn test_resolve_memory_key() {
        let result = resolve_key_to_path("claude.memory.my-project");
        assert!(result.is_ok());
        let path = result.unwrap();
        assert!(path.to_string_lossy().contains("memory/MEMORY.md"));
    }

    #[test]
    fn test_path_traversal_rejected() {
        assert!(resolve_key_to_path("claude.agent.../../etc/passwd").is_err());
        assert!(resolve_key_to_path("claude.memory.../secret").is_err());
    }

    #[test]
    fn test_validate_json() {
        assert!(validate_content(r#"{"key": "value"}"#, "json").is_ok());
        assert!(validate_content("not json", "json").is_err());
    }

    #[test]
    fn test_validate_toml() {
        assert!(validate_content("[section]\nkey = \"value\"", "toml").is_ok());
        assert!(validate_content("[invalid", "toml").is_err());
    }

    #[test]
    fn test_validate_markdown_always_passes() {
        assert!(validate_content("# anything goes", "markdown").is_ok());
    }

    #[test]
    fn test_format_for_path() {
        assert_eq!(format_for_path(Path::new("test.json")), "json");
        assert_eq!(format_for_path(Path::new("test.toml")), "toml");
        assert_eq!(format_for_path(Path::new("test.yaml")), "yaml");
        assert_eq!(format_for_path(Path::new("test.md")), "markdown");
        assert_eq!(format_for_path(Path::new("test.txt")), "text");
    }

    #[test]
    fn test_category_for_key() {
        assert_eq!(category_for_key("claude.settings"), "settings");
        assert_eq!(category_for_key("claude.mcp"), "mcp");
        assert_eq!(category_for_key("claude.hooks"), "hooks");
        assert_eq!(category_for_key("claude.agent.foo"), "agents");
        assert_eq!(category_for_key("claude.memory.proj"), "memory");
        assert_eq!(category_for_key("codex.rule.bar"), "rules");
    }
}
