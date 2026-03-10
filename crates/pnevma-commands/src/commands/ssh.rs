use super::*;
use pnevma_db::GlobalSshProfileRow;

// ─── SSH ─────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SshProfileInput {
    pub id: Option<String>,
    pub name: String,
    pub host: String,
    #[serde(default = "default_ssh_port")]
    pub port: u16,
    pub user: Option<String>,
    pub identity_file: Option<String>,
    pub proxy_jump: Option<String>,
    #[serde(default)]
    pub tags: Vec<String>,
    pub source: Option<String>,
}

fn default_ssh_port() -> u16 {
    22
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SshProfileView {
    pub id: String,
    pub name: String,
    pub host: String,
    pub port: u16,
    pub user: Option<String>,
    pub identity_file: Option<String>,
    pub proxy_jump: Option<String>,
    pub tags: Vec<String>,
    pub source: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SshKeyInfoView {
    pub name: String,
    pub path: String,
    pub key_type: String,
    pub fingerprint: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GenerateSshKeyInput {
    pub name: String,
    pub key_type: Option<String>,
    pub comment: Option<String>,
}

fn ssh_profile_row_to_view(row: SshProfileRow) -> SshProfileView {
    let tags: Vec<String> = serde_json::from_str(&row.tags_json).unwrap_or_default();
    SshProfileView {
        id: row.id,
        name: row.name,
        host: row.host,
        port: row.port as u16,
        user: row.user,
        identity_file: row.identity_file,
        proxy_jump: row.proxy_jump,
        tags,
        source: row.source,
        created_at: row.created_at,
        updated_at: row.updated_at,
    }
}

fn global_ssh_profile_row_to_view(row: GlobalSshProfileRow) -> SshProfileView {
    let tags: Vec<String> = serde_json::from_str(&row.tags_json).unwrap_or_default();
    SshProfileView {
        id: row.id,
        name: row.name,
        host: row.host,
        port: row.port as u16,
        user: row.user,
        identity_file: row.identity_file,
        proxy_jump: row.proxy_jump,
        tags,
        source: row.source,
        created_at: row.created_at,
        updated_at: row.updated_at,
    }
}

fn ssh_profile_to_global_row(profile: &pnevma_ssh::SshProfile) -> GlobalSshProfileRow {
    GlobalSshProfileRow {
        id: profile.id.clone(),
        name: profile.name.clone(),
        host: profile.host.clone(),
        port: profile.port as i64,
        user: profile.user.clone(),
        identity_file: profile.identity_file.clone(),
        proxy_jump: profile.proxy_jump.clone(),
        tags_json: serde_json::to_string(&profile.tags).unwrap_or_else(|_| "[]".to_string()),
        source: profile.source.clone(),
        created_at: profile.created_at,
        updated_at: profile.updated_at,
    }
}

fn ssh_profile_input_to_global_row(input: SshProfileInput) -> GlobalSshProfileRow {
    let now = Utc::now();
    GlobalSshProfileRow {
        id: input.id.unwrap_or_else(|| Uuid::new_v4().to_string()),
        name: input.name,
        host: input.host,
        port: input.port as i64,
        user: input.user,
        identity_file: input.identity_file,
        proxy_jump: input.proxy_jump,
        tags_json: serde_json::to_string(&input.tags).unwrap_or_else(|_| "[]".to_string()),
        source: input.source.unwrap_or_else(|| "manual".to_string()),
        created_at: now,
        updated_at: now,
    }
}

async fn list_project_ssh_profile_rows(state: &AppState) -> Result<Vec<SshProfileRow>, String> {
    let current = state.current.lock().await;
    let Some(ctx) = current.as_ref() else {
        return Ok(Vec::new());
    };
    ctx.db
        .list_ssh_profiles(&ctx.project_id.to_string())
        .await
        .map_err(|e| e.to_string())
}

pub async fn list_ssh_profiles(state: &AppState) -> Result<Vec<SshProfileView>, String> {
    let mut views: Vec<SshProfileView> = state
        .global_db()?
        .list_global_ssh_profiles()
        .await
        .map_err(|e| e.to_string())?
        .into_iter()
        .map(global_ssh_profile_row_to_view)
        .collect();

    for row in list_project_ssh_profile_rows(state).await? {
        if views.iter().any(|view| view.id == row.id) {
            continue;
        }
        views.push(ssh_profile_row_to_view(row));
    }

    views.sort_by(|left, right| left.name.cmp(&right.name));
    Ok(views)
}

pub async fn upsert_ssh_profile(
    input: SshProfileInput,
    state: &AppState,
) -> Result<String, String> {
    let row = ssh_profile_input_to_global_row(input);
    state
        .global_db()?
        .upsert_global_ssh_profile(&row)
        .await
        .map_err(|e| e.to_string())?;
    Ok(row.id)
}

pub async fn delete_ssh_profile(id: String, state: &AppState) -> Result<(), String> {
    state
        .global_db()?
        .delete_global_ssh_profile(&id)
        .await
        .map_err(|e| e.to_string())?;
    Ok(())
}

pub async fn import_ssh_config(state: &AppState) -> Result<Vec<SshProfileView>, String> {
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
    let ssh_config_path = PathBuf::from(&home).join(".ssh/config");
    let profiles = pnevma_ssh::parse_ssh_config(&ssh_config_path).map_err(|e| e.to_string())?;
    let mut views = Vec::new();
    for profile in &profiles {
        let row = ssh_profile_to_global_row(profile);
        state
            .global_db()?
            .upsert_global_ssh_profile(&row)
            .await
            .map_err(|e| e.to_string())?;
        views.push(global_ssh_profile_row_to_view(row));
    }
    Ok(views)
}

pub async fn discover_tailscale(state: &AppState) -> Result<Vec<SshProfileView>, String> {
    let profiles = pnevma_ssh::discover_tailscale_devices()
        .await
        .map_err(|e| e.to_string())?;
    let mut views = Vec::new();
    for profile in &profiles {
        let row = ssh_profile_to_global_row(profile);
        state
            .global_db()?
            .upsert_global_ssh_profile(&row)
            .await
            .map_err(|e| e.to_string())?;
        views.push(global_ssh_profile_row_to_view(row));
    }
    Ok(views)
}

pub async fn connect_ssh(profile_id: String, state: &AppState) -> Result<String, String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;
    let row = match state
        .global_db()?
        .get_global_ssh_profile(&profile_id)
        .await
        .map_err(|e| e.to_string())?
    {
        Some(row) => row,
        None => {
            let project_row = ctx
                .db
                .get_ssh_profile(&profile_id)
                .await
                .map_err(|e| e.to_string())?;
            GlobalSshProfileRow {
                id: project_row.id,
                name: project_row.name,
                host: project_row.host,
                port: project_row.port,
                user: project_row.user,
                identity_file: project_row.identity_file,
                proxy_jump: project_row.proxy_jump,
                tags_json: project_row.tags_json,
                source: project_row.source,
                created_at: project_row.created_at,
                updated_at: project_row.updated_at,
            }
        }
    };

    let tags: Vec<String> = serde_json::from_str(&row.tags_json).unwrap_or_default();
    let ssh_profile = pnevma_ssh::SshProfile {
        id: row.id.clone(),
        name: row.name.clone(),
        host: row.host.clone(),
        port: row.port as u16,
        user: row.user.clone(),
        identity_file: row.identity_file.clone(),
        proxy_jump: row.proxy_jump.clone(),
        tags,
        source: row.source.clone(),
        created_at: row.created_at,
        updated_at: row.updated_at,
    };

    let ssh_args = pnevma_ssh::build_ssh_command(&ssh_profile);
    let command = ssh_args
        .iter()
        .map(|a| pnevma_ssh::shell_escape_arg(a))
        .collect::<Vec<_>>()
        .join(" ");

    let session = ctx
        .sessions
        .spawn_shell(
            ctx.project_id,
            format!("ssh-{}", row.name),
            ".".to_string(),
            command,
        )
        .await
        .map_err(|e| e.to_string())?;

    let mut session_row = session_row_from_meta(&session);
    session_row.r#type = Some("ssh".to_string());
    ctx.db
        .upsert_session(&session_row)
        .await
        .map_err(|e| e.to_string())?;

    let pane_row = PaneRow {
        id: Uuid::new_v4().to_string(),
        project_id: ctx.project_id.to_string(),
        session_id: Some(session.id.to_string()),
        r#type: "terminal".to_string(),
        position: "root".to_string(),
        label: row.name.clone(),
        metadata_json: None,
    };
    ctx.db
        .upsert_pane(&pane_row)
        .await
        .map_err(|e| e.to_string())?;

    Ok(session.id.to_string())
}

pub async fn disconnect_ssh(_profile_id: String, _state: &AppState) -> Result<(), String> {
    Ok(())
}

pub async fn list_ssh_keys(state: &AppState) -> Result<Vec<SshKeyInfoView>, String> {
    let _current = state.current.lock().await;
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
    let ssh_dir = PathBuf::from(&home).join(".ssh");
    let keys = pnevma_ssh::list_ssh_keys(&ssh_dir).map_err(|e| e.to_string())?;
    Ok(keys
        .into_iter()
        .map(|k| SshKeyInfoView {
            name: k.name,
            path: k.path,
            key_type: k.key_type,
            fingerprint: k.fingerprint,
        })
        .collect())
}

pub async fn generate_ssh_key(
    input: GenerateSshKeyInput,
    state: &AppState,
) -> Result<SshKeyInfoView, String> {
    let _current = state.current.lock().await;
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
    let ssh_dir = PathBuf::from(&home).join(".ssh");
    let key_type = input.key_type.as_deref().unwrap_or("ed25519");
    let comment = input.comment.as_deref().unwrap_or("");
    let key = pnevma_ssh::generate_key(&ssh_dir, &input.name, key_type, comment)
        .map_err(|e| e.to_string())?;
    Ok(SshKeyInfoView {
        name: key.name,
        path: key.path,
        key_type: key.key_type,
        fingerprint: key.fingerprint,
    })
}

#[cfg(test)]
mod tests {
    use super::{
        build_default_project_toml, is_supported_keybinding_action, normalize_layout_template_name,
        pane_contains_unsaved_metadata, parse_osc_attention, project_is_initialized, redact_text,
        session_state_may_be_unsaved,
    };
    use std::path::PathBuf;
    use uuid::Uuid;

    #[test]
    fn parses_osc_attention_sequences() {
        let chunk = "pre\x1b]9;build done\x07mid\x1b]99;needs input\x1b\\post";
        let items = parse_osc_attention(chunk);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].code, "9");
        assert_eq!(items[0].body, "build done");
        assert_eq!(items[1].code, "99");
        assert_eq!(items[1].body, "needs input");
    }

    #[test]
    fn redacts_known_secret_values_and_patterns() {
        let input = "Authorization: Bearer abc123 password=hunter2 token:xyz";
        let redacted = redact_text(input, &["abc123".to_string(), "hunter2".to_string()]);
        assert!(!redacted.contains("abc123"));
        assert!(!redacted.contains("hunter2"));
        assert!(!redacted.contains("xyz"));
        assert!(redacted.contains("[REDACTED]"));
    }

    #[test]
    fn normalizes_layout_template_names() {
        assert_eq!(
            normalize_layout_template_name("  Review Mode / Team A "),
            "review-mode-team-a"
        );
        assert_eq!(normalize_layout_template_name(""), "");
    }

    #[test]
    fn detects_unsaved_metadata_flags() {
        assert!(pane_contains_unsaved_metadata(Some(r#"{"unsaved":true}"#)));
        assert!(pane_contains_unsaved_metadata(Some(r#"{"dirty":true}"#)));
        assert!(!pane_contains_unsaved_metadata(Some(r#"{"dirty":false}"#)));
        assert!(!pane_contains_unsaved_metadata(Some("not-json")));
    }

    #[test]
    fn recognizes_running_session_states_as_unsaved() {
        assert!(session_state_may_be_unsaved("Running"));
        assert!(!session_state_may_be_unsaved("Exited"));
        assert!(!session_state_may_be_unsaved("Completed"));
    }

    #[test]
    fn default_project_toml_contains_required_sections() {
        let content = build_default_project_toml(
            PathBuf::from("/tmp/sample").as_path(),
            Some("Sample"),
            Some("Brief"),
            "claude-code",
        );
        assert!(content.contains("[project]"));
        assert!(content.contains("[agents]"));
        assert!(content.contains("[automation]"));
        assert!(content.contains("default_provider = \"claude-code\""));
    }

    #[test]
    fn project_initialized_requires_config_and_data_dir() {
        let root = std::env::temp_dir().join(format!("pnevma-init-test-{}", Uuid::new_v4()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join(".pnevma")).expect("create .pnevma");
        assert!(!project_is_initialized(&root));
        std::fs::write(
            root.join("pnevma.toml"),
            "[project]\nname=\"x\"\nbrief=\"y\"\n",
        )
        .expect("write config");
        assert!(project_is_initialized(&root));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn keybinding_actions_are_allowlisted() {
        assert!(is_supported_keybinding_action("command_palette.toggle"));
        assert!(is_supported_keybinding_action("task.dispatch_next_ready"));
        assert!(is_supported_keybinding_action("review.approve_next"));
        assert!(!is_supported_keybinding_action("custom.unknown"));
    }
}
