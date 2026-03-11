use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiscoveredAgent {
    pub name: String,
    pub description: Option<String>,
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
    description: Option<String>,
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
    let content = std::fs::read_to_string(path).map_err(|e| e.to_string())?;

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
        description: fm.description,
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

        let description = agent_table
            .get("description")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string());

        // Try to load referenced config file
        let mut model = String::new();
        let mut system_prompt = None;

        if let Some(config_file) = agent_table.get("config_file").and_then(|v| v.as_str()) {
            let config_file_path = config_dir.join(config_file);
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
                    "codex agent config_file escapes config directory, skipping"
                );
                continue;
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

        // Skip built-in roles with no config_file
        if (name == "default" || name == "worker")
            && agent_table.get("config_file").is_none()
            && description.is_none()
        {
            continue;
        }

        agents.push(DiscoveredAgent {
            name: name.clone(),
            description,
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
