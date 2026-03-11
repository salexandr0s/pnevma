use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiscoveredAgent {
    pub name: String,
    pub provider: String,
    pub model: String,
    pub role: String,
    pub system_prompt: Option<String>,
    pub source: String,
    pub source_path: String,
    pub tools: Vec<String>,
}

// ─── Claude Code parser ─────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
struct ClaudeCodeFrontmatter {
    name: Option<String>,
    model: Option<String>,
    tools: Option<Vec<String>>,
}

fn map_claude_model(short: &str) -> String {
    match short {
        "sonnet" => "claude-sonnet-4-6".to_string(),
        "opus" => "claude-opus-4-6".to_string(),
        "haiku" => "claude-haiku-4-5".to_string(),
        other => other.to_string(),
    }
}

/// Infer agent role from declared tool list.
///
/// - Empty tools list: "build" (no tools declared = full capability assumed)
/// - Only read-oriented tools (Read/Glob/Grep/Bash/WebFetch/WebSearch): "research"
/// - Any write tool (Write/Edit/NotebookEdit/etc.) present: "build"
///
/// Note: Bash is classified as read-only here because Claude Code agents with
/// only Bash+Read are typically research/review agents, not implementation agents.
fn infer_role_from_tools(tools: &[String]) -> String {
    if tools.is_empty() {
        return "build".to_string();
    }
    let read_only = ["Read", "Glob", "Grep", "Bash", "WebFetch", "WebSearch"];
    let has_write = tools.iter().any(|t| !read_only.iter().any(|ro| t == ro));
    if has_write {
        "build".to_string()
    } else {
        "research".to_string()
    }
}

pub fn discover_claude_code_agents(dir: &Path) -> Vec<DiscoveredAgent> {
    let mut agents = Vec::new();
    let entries = match std::fs::read_dir(dir) {
        Ok(e) => e,
        Err(_) => return agents,
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("md") {
            continue;
        }
        match parse_claude_code_agent(&path) {
            Ok(agent) => agents.push(agent),
            Err(e) => {
                tracing::warn!(path = %path.display(), error = %e, "skipping Claude Code agent file");
            }
        }
    }
    agents
}

fn parse_claude_code_agent(path: &Path) -> Result<DiscoveredAgent, String> {
    let raw = std::fs::read_to_string(path).map_err(|e| e.to_string())?;
    // Normalize CRLF to LF for Windows-authored files
    let content = raw.replace("\r\n", "\n");

    // Extract YAML frontmatter between first two "---" lines
    let trimmed = content.trim_start();
    if !trimmed.starts_with("---") {
        return Err("no YAML frontmatter found".to_string());
    }
    let after_first = &trimmed[3..];
    let end_idx = after_first
        .find("\n---")
        .ok_or_else(|| "no closing --- for frontmatter".to_string())?;
    let yaml_str = &after_first[..end_idx];
    let body_start = end_idx + 4; // skip "\n---"
    let body = after_first[body_start..].trim().to_string();

    let fm: ClaudeCodeFrontmatter =
        serde_yaml::from_str(yaml_str).map_err(|e| format!("YAML parse error: {e}"))?;

    let file_stem = path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("unknown")
        .to_string();
    let name = fm.name.unwrap_or(file_stem);
    let tools = fm.tools.unwrap_or_default();
    let role = infer_role_from_tools(&tools);
    let model_raw = fm.model.unwrap_or_else(|| "sonnet".to_string());
    let model = map_claude_model(&model_raw);

    let source_path = path
        .canonicalize()
        .unwrap_or_else(|_| path.to_path_buf())
        .to_string_lossy()
        .to_string();

    Ok(DiscoveredAgent {
        name,
        provider: "anthropic".to_string(),
        model,
        role,
        system_prompt: if body.is_empty() { None } else { Some(body) },
        source: "claude-code".to_string(),
        source_path,
        tools,
    })
}

// ─── Codex parser ───────────────────────────────────────────────────────────

pub fn discover_codex_agents(config_path: &Path) -> Vec<DiscoveredAgent> {
    let mut agents = Vec::new();
    let content = match std::fs::read_to_string(config_path) {
        Ok(c) => c,
        Err(_) => return agents,
    };
    let table: toml::Table = match content.parse() {
        Ok(t) => t,
        Err(e) => {
            tracing::warn!(path = %config_path.display(), error = %e, "failed to parse Codex config");
            return agents;
        }
    };

    let agents_table = match table.get("agents").and_then(|v| v.as_table()) {
        Some(t) => t,
        None => return agents,
    };

    let config_dir = config_path.parent().unwrap_or(Path::new("."));
    let source_path = config_path
        .canonicalize()
        .unwrap_or_else(|_| config_path.to_path_buf())
        .to_string_lossy()
        .to_string();

    for (name, value) in agents_table {
        let agent_table = match value.as_table() {
            Some(t) => t,
            None => continue,
        };

        let has_description = agent_table.get("description").is_some();

        // Try to load referenced config file
        let mut model = String::new();
        let mut system_prompt = None;

        if let Some(config_file) = agent_table.get("config_file").and_then(|v| v.as_str()) {
            let config_file_path = config_dir.join(config_file);
            if !config_file_path.exists() {
                tracing::debug!(
                    config_file,
                    "codex agent config_file not found, skipping file load"
                );
            } else {
                // Prevent path traversal — config_file must resolve inside config_dir
                let ok = config_file_path
                    .canonicalize()
                    .ok()
                    .and_then(|resolved| {
                        config_dir
                            .canonicalize()
                            .ok()
                            .map(|base| resolved.starts_with(&base))
                    })
                    .unwrap_or(false);
                if !ok {
                    tracing::warn!(
                        config_file,
                        "codex agent config_file escapes config directory, skipping agent"
                    );
                    continue;
                }
            }
            if let Ok(agent_content) = std::fs::read_to_string(&config_file_path) {
                if let Ok(agent_table) = agent_content.parse::<toml::Table>() {
                    if let Some(m) = agent_table.get("model").and_then(|v| v.as_str()) {
                        model = m.to_string();
                    }
                    if let Some(di) = agent_table
                        .get("developer_instructions")
                        .and_then(|v| v.as_str())
                    {
                        system_prompt = Some(di.to_string());
                    }
                }
            }
        }

        // Fallback model from agent table or parent config
        if model.is_empty() {
            if let Some(m) = agent_table.get("model").and_then(|v| v.as_str()) {
                model = m.to_string();
            } else if let Some(m) = table.get("model").and_then(|v| v.as_str()) {
                model = m.to_string();
            } else {
                model = "gpt-4o".to_string();
            }
        }

        let provider = if model.contains("claude") {
            "anthropic"
        } else {
            "openai"
        };

        let role = match name.as_str() {
            "explorer" | "researcher" => "research",
            "monitor" => "ops",
            "reviewer" => "review",
            "planner" => "plan",
            _ => "build",
        };

        // Skip built-in roles with no config_file and no description
        if (name == "default" || name == "worker")
            && agent_table.get("config_file").is_none()
            && !has_description
        {
            continue;
        }

        agents.push(DiscoveredAgent {
            name: name.clone(),
            provider: provider.to_string(),
            model,
            role: role.to_string(),
            system_prompt,
            source: "codex".to_string(),
            source_path: format!("{}#{}", source_path, name),
            tools: Vec::new(),
        });
    }

    agents
}

// ─── Convenience functions ──────────────────────────────────────────────────

pub fn discover_global_agents() -> Vec<DiscoveredAgent> {
    let home = std::env::var("HOME").ok().map(PathBuf::from);
    let mut agents = Vec::new();
    if let Some(home) = &home {
        agents.extend(discover_claude_code_agents(&home.join(".claude/agents")));
        agents.extend(discover_codex_agents(&home.join(".codex/config.toml")));
    }
    agents
}

pub fn discover_project_agents(project_path: &Path) -> Vec<DiscoveredAgent> {
    let mut agents = Vec::new();
    agents.extend(discover_claude_code_agents(
        &project_path.join(".claude/agents"),
    ));
    agents.extend(discover_codex_agents(
        &project_path.join(".codex/config.toml"),
    ));
    agents
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn test_map_claude_model() {
        assert_eq!(map_claude_model("sonnet"), "claude-sonnet-4-6");
        assert_eq!(map_claude_model("opus"), "claude-opus-4-6");
        assert_eq!(map_claude_model("haiku"), "claude-haiku-4-5");
        assert_eq!(map_claude_model("claude-sonnet-4-6"), "claude-sonnet-4-6");
    }

    #[test]
    fn test_infer_role_empty_tools() {
        assert_eq!(infer_role_from_tools(&[]), "build");
    }

    #[test]
    fn test_infer_role_read_only_tools() {
        let tools = vec!["Read".into(), "Glob".into(), "Grep".into(), "Bash".into()];
        assert_eq!(infer_role_from_tools(&tools), "research");
    }

    #[test]
    fn test_infer_role_write_tools() {
        let tools = vec!["Read".into(), "Edit".into(), "Bash".into()];
        assert_eq!(infer_role_from_tools(&tools), "build");
    }

    #[test]
    fn test_parse_claude_code_agent_basic() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("test-agent.md");
        fs::write(
            &path,
            "---\nname: coder\nmodel: opus\n---\n\n# Instructions\nWrite code.\n",
        )
        .unwrap();

        let agent = parse_claude_code_agent(&path).unwrap();
        assert_eq!(agent.name, "coder");
        assert_eq!(agent.model, "claude-opus-4-6");
        assert_eq!(agent.provider, "anthropic");
        assert_eq!(agent.role, "build");
        assert_eq!(agent.source, "claude-code");
        assert!(agent.system_prompt.unwrap().contains("Write code."));
    }

    #[test]
    fn test_parse_claude_code_agent_with_tools() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("reviewer.md");
        fs::write(
            &path,
            "---\nname: reviewer\nmodel: sonnet\ntools:\n  - Read\n  - Grep\n---\n\nReview only.\n",
        )
        .unwrap();

        let agent = parse_claude_code_agent(&path).unwrap();
        assert_eq!(agent.name, "reviewer");
        assert_eq!(agent.role, "research");
        assert_eq!(agent.tools, vec!["Read", "Grep"]);
    }

    #[test]
    fn test_parse_claude_code_agent_no_body() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("minimal.md");
        fs::write(&path, "---\nname: minimal\n---\n").unwrap();

        let agent = parse_claude_code_agent(&path).unwrap();
        assert_eq!(agent.name, "minimal");
        assert!(agent.system_prompt.is_none());
    }

    #[test]
    fn test_parse_claude_code_agent_crlf() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("crlf.md");
        fs::write(
            &path,
            "---\r\nname: crlf-agent\r\nmodel: haiku\r\n---\r\n\r\nBody text.\r\n",
        )
        .unwrap();

        let agent = parse_claude_code_agent(&path).unwrap();
        assert_eq!(agent.name, "crlf-agent");
        assert_eq!(agent.model, "claude-haiku-4-5");
        assert!(agent.system_prompt.unwrap().contains("Body text."));
    }

    #[test]
    fn test_parse_claude_code_agent_no_frontmatter() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("bad.md");
        fs::write(&path, "# Just markdown\nNo frontmatter here.\n").unwrap();

        assert!(parse_claude_code_agent(&path).is_err());
    }

    #[test]
    fn test_parse_claude_code_agent_name_from_filename() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("my-agent.md");
        fs::write(&path, "---\nmodel: sonnet\n---\n\nPrompt.\n").unwrap();

        let agent = parse_claude_code_agent(&path).unwrap();
        assert_eq!(agent.name, "my-agent");
    }

    #[test]
    fn test_discover_claude_code_agents_nonexistent_dir() {
        let agents = discover_claude_code_agents(Path::new("/nonexistent/path"));
        assert!(agents.is_empty());
    }

    #[test]
    fn test_discover_claude_code_agents_skips_non_md() {
        let dir = tempfile::tempdir().unwrap();
        let agents_dir = dir.path().join("agents");
        fs::create_dir(&agents_dir).unwrap();
        fs::write(
            agents_dir.join("good.md"),
            "---\nname: good\n---\n\nPrompt.\n",
        )
        .unwrap();
        fs::write(agents_dir.join("ignored.txt"), "not an agent").unwrap();

        let agents = discover_claude_code_agents(&agents_dir);
        assert_eq!(agents.len(), 1);
        assert_eq!(agents[0].name, "good");
    }

    #[test]
    fn test_discover_codex_agents_basic() {
        let dir = tempfile::tempdir().unwrap();
        let config_path = dir.path().join("config.toml");
        fs::write(
            &config_path,
            r#"
model = "gpt-5"

[agents.explorer]
description = "Explores code"

[agents.builder]
description = "Builds things"
"#,
        )
        .unwrap();

        let agents = discover_codex_agents(&config_path);
        assert_eq!(agents.len(), 2);

        let explorer = agents.iter().find(|a| a.name == "explorer").unwrap();
        assert_eq!(explorer.role, "research");
        assert_eq!(explorer.provider, "openai");
        assert_eq!(explorer.model, "gpt-5");
        assert_eq!(explorer.source, "codex");
        assert!(explorer.source_path.contains("#explorer"));

        let builder = agents.iter().find(|a| a.name == "builder").unwrap();
        assert_eq!(builder.role, "build");
    }

    #[test]
    fn test_discover_codex_agents_skips_bare_default() {
        let dir = tempfile::tempdir().unwrap();
        let config_path = dir.path().join("config.toml");
        fs::write(
            &config_path,
            r#"
[agents.default]
# no description, no config_file → should be skipped

[agents.worker]
# same

[agents.custom]
description = "Should be kept"
"#,
        )
        .unwrap();

        let agents = discover_codex_agents(&config_path);
        assert_eq!(agents.len(), 1);
        assert_eq!(agents[0].name, "custom");
    }

    #[test]
    fn test_discover_codex_agents_nonexistent() {
        let agents = discover_codex_agents(Path::new("/nonexistent/config.toml"));
        assert!(agents.is_empty());
    }

    #[test]
    fn test_discover_codex_agents_no_agents_table() {
        let dir = tempfile::tempdir().unwrap();
        let config_path = dir.path().join("config.toml");
        fs::write(&config_path, "model = \"gpt-4o\"\n").unwrap();

        let agents = discover_codex_agents(&config_path);
        assert!(agents.is_empty());
    }

    #[test]
    fn test_discover_codex_agents_claude_model_detection() {
        let dir = tempfile::tempdir().unwrap();
        let config_path = dir.path().join("config.toml");
        fs::write(
            &config_path,
            r#"
model = "claude-sonnet-4-6"

[agents.helper]
description = "Uses Claude"
"#,
        )
        .unwrap();

        let agents = discover_codex_agents(&config_path);
        assert_eq!(agents[0].provider, "anthropic");
    }
}
