use super::{
    append_event, load_redaction_secrets, read_keychain_secret, register_project_redaction_secrets,
    store_keychain_secret, ProjectSecretDeleteInput, ProjectSecretExportTemplateInput,
    ProjectSecretExportTemplateResult, ProjectSecretImportInput, ProjectSecretImportResult,
    ProjectSecretUpsertInput, ProjectSecretView,
};
use crate::event_emitter::EventEmitter;
use crate::state::AppState;
use chrono::Utc;
use pnevma_db::{Db, SecretRefRow};
use serde_json::json;
use std::collections::{BTreeMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tokio::fs;
use tokio::process::Command;
use uuid::Uuid;

const KEYCHAIN_BACKEND: &str = "keychain";
const ENV_FILE_BACKEND: &str = "env_file";
const PROJECT_SCOPE: &str = "project";
const GLOBAL_SCOPE: &str = "global";
const DEFAULT_ENV_FILE_PATH: &str = ".env.local";
const MANAGED_BLOCK_BEGIN: &str = "# >>> pnevma managed >>>";
const MANAGED_BLOCK_END: &str = "# <<< pnevma managed <<<";

pub async fn list_project_secrets(
    scope: Option<String>,
    state: &AppState,
) -> Result<Vec<ProjectSecretView>, String> {
    let (db, project_id, project_path) = current_project_basics(state).await?;
    let rows = db
        .list_secret_refs(&project_id.to_string(), scope.as_deref())
        .await
        .map_err(|e| e.to_string())?;
    let mut out = Vec::with_capacity(rows.len());
    for row in rows {
        out.push(secret_row_to_view(&row, &project_path).await);
    }
    Ok(out)
}

pub async fn upsert_project_secret(
    input: ProjectSecretUpsertInput,
    emitter: &Arc<dyn EventEmitter>,
    state: &AppState,
) -> Result<ProjectSecretView, String> {
    let project = current_project_details(state).await?;
    let name = normalize_secret_name(&input.name)?;
    let scope = normalize_secret_scope(&input.scope);
    let backend = normalize_secret_backend(&input.backend)?;
    if scope == GLOBAL_SCOPE && backend == ENV_FILE_BACKEND {
        return Err("global secrets must use the keychain backend".to_string());
    }

    let env_file_path = normalize_env_file_path(input.env_file_path.as_deref())?;
    let project_scope_id = if scope == PROJECT_SCOPE {
        Some(project.project_id.to_string())
    } else {
        None
    };

    let existing = match input.id.as_deref() {
        Some(id) => project
            .db
            .get_secret_ref(id)
            .await
            .map_err(|e| e.to_string())?,
        None => None,
    };
    if let Some(existing) = &existing {
        ensure_secret_belongs_to_project(existing, project.project_id)?;
    }
    let scope_rows = project
        .db
        .list_secret_refs(&project.project_id.to_string(), Some(scope))
        .await
        .map_err(|e| e.to_string())?;
    if scope_rows.iter().any(|row| {
        row.name == name
            && row.project_id == project_scope_id
            && existing.as_ref().map(|current| current.id.as_str()) != Some(row.id.as_str())
    }) {
        return Err(format!(
            "{name} is already configured for this {scope} scope"
        ));
    }

    let value = match (input.value.as_deref(), existing.as_ref()) {
        (Some(value), _) => value.trim().to_string(),
        (None, Some(row)) => resolve_secret_value(row, &project.project_path).await?,
        (None, None) => return Err("value is required when creating a secret".to_string()),
    };
    if value.is_empty() {
        return Err("secret value must not be empty".to_string());
    }
    pnevma_agents::validate_agent_env_entry_for_registration(&name, &value)?;

    let id = existing
        .as_ref()
        .map(|row| row.id.clone())
        .unwrap_or_else(|| Uuid::new_v4().to_string());
    let now = Utc::now();
    let row = match backend {
        KEYCHAIN_BACKEND => {
            let service = project_keychain_service(scope, project.project_id);
            store_keychain_secret(&service, &name, &value).await?;
            SecretRefRow {
                id,
                project_id: project_scope_id,
                scope: scope.to_string(),
                name: name.clone(),
                backend: backend.to_string(),
                keychain_service: Some(service),
                keychain_account: Some(name.clone()),
                env_file_path: None,
                created_at: existing.as_ref().map(|row| row.created_at).unwrap_or(now),
                updated_at: now,
            }
        }
        ENV_FILE_BACKEND => {
            if value.contains('\n') || value.contains('\r') {
                return Err(
                    "file-backed secrets cannot contain newlines; use the keychain backend instead"
                        .to_string(),
                );
            }
            let rel_path = env_file_path.unwrap_or_else(|| DEFAULT_ENV_FILE_PATH.to_string());
            upsert_env_file_secret(&project.project_path, &rel_path, &name, &value).await?;
            SecretRefRow {
                id,
                project_id: project_scope_id,
                scope: scope.to_string(),
                name: name.clone(),
                backend: backend.to_string(),
                keychain_service: None,
                keychain_account: None,
                env_file_path: Some(rel_path),
                created_at: existing.as_ref().map(|row| row.created_at).unwrap_or(now),
                updated_at: now,
            }
        }
        _ => return Err(format!("unsupported secret backend: {backend}")),
    };

    if existing.is_some() {
        project
            .db
            .update_secret_ref(&row)
            .await
            .map_err(|e| e.to_string())?;
    } else {
        project
            .db
            .upsert_secret_ref(&row)
            .await
            .map_err(|e| e.to_string())?;
    }

    if let Some(existing) = existing {
        if !same_secret_storage(&existing, &row) {
            if let Err(error) = delete_secret_storage(&existing, &project.project_path).await {
                tracing::warn!(
                    secret_id = %existing.id,
                    old_backend = %existing.backend,
                    new_backend = %row.backend,
                    %error,
                    "updated project secret but failed to remove previous storage"
                );
            }
        }
    }

    refresh_secret_runtime(
        &project.db,
        project.project_id,
        &project.sessions,
        &project.redaction_secrets,
    )
    .await;
    append_event(
        &project.db,
        project.project_id,
        None,
        None,
        "security",
        "ProjectSecretUpserted",
        json!({
            "secret_id": row.id,
            "name": row.name,
            "scope": row.scope,
            "backend": row.backend
        }),
    )
    .await;
    emitter.emit(
        "project_secrets_updated",
        json!({"project_id": project.project_id, "reason": "upsert"}),
    );
    Ok(secret_row_to_view(&row, &project.project_path).await)
}

pub async fn delete_project_secret(
    input: ProjectSecretDeleteInput,
    emitter: &Arc<dyn EventEmitter>,
    state: &AppState,
) -> Result<(), String> {
    let project = current_project_details(state).await?;
    let row = project
        .db
        .get_secret_ref(&input.id)
        .await
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "secret not found".to_string())?;
    ensure_secret_belongs_to_project(&row, project.project_id)?;

    delete_secret_storage(&row, &project.project_path).await?;
    project
        .db
        .delete_secret_ref(&row.id)
        .await
        .map_err(|e| e.to_string())?;
    refresh_secret_runtime(
        &project.db,
        project.project_id,
        &project.sessions,
        &project.redaction_secrets,
    )
    .await;
    append_event(
        &project.db,
        project.project_id,
        None,
        None,
        "security",
        "ProjectSecretDeleted",
        json!({"secret_id": row.id, "name": row.name, "scope": row.scope, "backend": row.backend}),
    )
    .await;
    emitter.emit(
        "project_secrets_updated",
        json!({"project_id": project.project_id, "reason": "delete"}),
    );
    Ok(())
}

pub async fn import_project_secrets(
    input: ProjectSecretImportInput,
    emitter: &Arc<dyn EventEmitter>,
    state: &AppState,
) -> Result<ProjectSecretImportResult, String> {
    let project = current_project_details(state).await?;
    let scope = normalize_secret_scope(&input.scope);
    let backend = normalize_secret_backend(&input.destination_backend)?;
    if scope == GLOBAL_SCOPE && backend == ENV_FILE_BACKEND {
        return Err("global secrets must use the keychain backend".to_string());
    }
    let replace_existing = matches!(input.on_conflict.as_deref(), Some("replace"));
    let content = fs::read_to_string(&input.path)
        .await
        .map_err(|e| format!("failed to read env file {}: {e}", input.path))?;
    let parsed = parse_env_assignments(&content);
    let existing = project
        .db
        .list_secret_refs(&project.project_id.to_string(), Some(scope))
        .await
        .map_err(|e| e.to_string())?;
    let existing_names: HashSet<String> = existing.iter().map(|row| row.name.clone()).collect();
    let existing_ids = existing
        .into_iter()
        .map(|row| (row.name, row.id))
        .collect::<BTreeMap<_, _>>();

    let mut imported_names = Vec::new();
    let mut skipped_names = Vec::new();
    let mut error_names = Vec::new();
    for (name, value) in parsed {
        if normalize_secret_name(&name).is_err()
            || pnevma_agents::validate_agent_env_entry_for_registration(&name, &value).is_err()
        {
            error_names.push(name);
            continue;
        }
        if existing_names.contains(&name) && !replace_existing {
            skipped_names.push(name);
            continue;
        }
        let result = upsert_project_secret(
            ProjectSecretUpsertInput {
                id: existing_ids.get(&name).cloned(),
                name: name.clone(),
                scope: scope.to_string(),
                backend: backend.to_string(),
                value: Some(value),
                env_file_path: None,
            },
            emitter,
            state,
        )
        .await;
        match result {
            Ok(_) => imported_names.push(name),
            Err(_) => error_names.push(name),
        }
    }

    append_event(
        &project.db,
        project.project_id,
        None,
        None,
        "security",
        "ProjectSecretsImported",
        json!({
            "path": input.path,
            "scope": scope,
            "backend": backend,
            "imported_count": imported_names.len(),
            "skipped_count": skipped_names.len(),
            "error_count": error_names.len()
        }),
    )
    .await;
    emitter.emit(
        "project_secrets_updated",
        json!({"project_id": project.project_id, "reason": "import"}),
    );
    Ok(ProjectSecretImportResult {
        imported_names,
        skipped_names,
        error_names,
    })
}

pub async fn export_project_secret_template(
    input: ProjectSecretExportTemplateInput,
    state: &AppState,
) -> Result<ProjectSecretExportTemplateResult, String> {
    let (db, project_id, project_path) = current_project_basics(state).await?;
    let refs = dedupe_secret_refs(
        db.list_secret_refs(&project_id.to_string(), None)
            .await
            .map_err(|e| e.to_string())?,
    );
    let rel_path = input
        .path
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| DEFAULT_ENV_FILE_PATH.to_string());
    ensure_env_file_git_ignored(&project_path, &rel_path).await?;
    let output_path = project_path.join(&rel_path);
    let mut entries = BTreeMap::new();
    for row in refs {
        entries.insert(row.name, encode_env_value(""));
    }
    let existing = read_existing_env_file(&output_path).await?;
    let updated = write_managed_entries(&existing, &entries)?;
    write_env_file(&output_path, &updated).await?;
    Ok(ProjectSecretExportTemplateResult {
        path: rel_path,
        count: entries.len(),
    })
}

pub(crate) async fn resolve_project_secret_env(
    db: &Db,
    project_id: Uuid,
) -> Result<(Vec<(String, String)>, Vec<String>), String> {
    let project_path = db
        .get_project(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?
        .map(|row| PathBuf::from(row.path))
        .unwrap_or_else(|| PathBuf::from("."));
    let refs = dedupe_secret_refs(
        db.list_secret_refs(&project_id.to_string(), None)
            .await
            .map_err(|e| e.to_string())?,
    );
    let mut env = Vec::with_capacity(refs.len());
    let mut values = Vec::with_capacity(refs.len());
    for row in refs {
        match resolve_secret_value(&row, &project_path).await {
            Ok(value) => {
                values.push(value.clone());
                match pnevma_agents::validate_agent_env_entry(&row.name, &value) {
                    Ok(()) => env.push((row.name.clone(), value)),
                    Err(error) => tracing::warn!(
                        name = %row.name,
                        project_id = %project_id,
                        %error,
                        "skipping unsafe secret environment variable"
                    ),
                }
            }
            Err(err) => tracing::warn!(
                name = %row.name,
                project_id = %project_id,
                %err,
                "failed to resolve secret value"
            ),
        }
    }
    Ok((env, values))
}

pub(crate) async fn resolve_secret_value(
    row: &SecretRefRow,
    project_path: &Path,
) -> Result<String, String> {
    match row.backend.as_str() {
        KEYCHAIN_BACKEND => {
            let service = row
                .keychain_service
                .as_deref()
                .ok_or_else(|| "keychain secret missing service".to_string())?;
            let account = row
                .keychain_account
                .as_deref()
                .ok_or_else(|| "keychain secret missing account".to_string())?;
            read_keychain_secret(service, account).await
        }
        ENV_FILE_BACKEND => {
            let rel_path = row
                .env_file_path
                .as_deref()
                .ok_or_else(|| "env-file secret missing path".to_string())?;
            read_env_file_secret(project_path, rel_path, &row.name).await
        }
        other => Err(format!("unsupported secret backend: {other}")),
    }
}

pub(crate) async fn resolve_secret_value_by_name(
    db: &Db,
    project_id: Uuid,
    name: &str,
) -> Result<Option<String>, String> {
    let project_path = db
        .get_project(&project_id.to_string())
        .await
        .map_err(|e| e.to_string())?
        .map(|row| PathBuf::from(row.path))
        .unwrap_or_else(|| PathBuf::from("."));
    let refs = dedupe_secret_refs(
        db.list_secret_refs(&project_id.to_string(), None)
            .await
            .map_err(|e| e.to_string())?,
    );
    let Some(row) = refs.into_iter().find(|row| row.name == name) else {
        return Ok(None);
    };
    resolve_secret_value(&row, &project_path).await.map(Some)
}

pub(crate) fn dedupe_secret_refs(rows: Vec<SecretRefRow>) -> Vec<SecretRefRow> {
    let mut by_name: BTreeMap<String, SecretRefRow> = BTreeMap::new();
    for row in rows {
        match by_name.get(&row.name) {
            Some(existing) if existing.scope == PROJECT_SCOPE => {}
            _ => {
                by_name.insert(row.name.clone(), row);
            }
        }
    }
    by_name.into_values().collect()
}

pub(crate) fn visible_secret_names(rows: &[SecretRefRow]) -> Vec<String> {
    rows.iter().map(|row| row.name.clone()).collect()
}

pub(crate) async fn available_secret_names(
    db: &Db,
    project_id: Uuid,
) -> Result<Vec<String>, String> {
    let rows = dedupe_secret_refs(
        db.list_secret_refs(&project_id.to_string(), None)
            .await
            .map_err(|e| e.to_string())?,
    );
    Ok(visible_secret_names(&rows))
}

struct ProjectSecretContext {
    db: Db,
    project_id: Uuid,
    project_path: PathBuf,
    sessions: pnevma_session::SessionSupervisor,
    redaction_secrets: Arc<tokio::sync::RwLock<Vec<String>>>,
}

async fn current_project_details(state: &AppState) -> Result<ProjectSecretContext, String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;
    Ok(ProjectSecretContext {
        db: ctx.db.clone(),
        project_id: ctx.project_id,
        project_path: ctx.project_path.clone(),
        sessions: ctx.sessions.clone(),
        redaction_secrets: Arc::clone(&ctx.redaction_secrets),
    })
}

async fn current_project_basics(state: &AppState) -> Result<(Db, Uuid, PathBuf), String> {
    let current = state.current.lock().await;
    let ctx = current
        .as_ref()
        .ok_or_else(|| "no open project".to_string())?;
    Ok((ctx.db.clone(), ctx.project_id, ctx.project_path.clone()))
}

fn normalize_secret_scope(scope: &str) -> &'static str {
    if scope.eq_ignore_ascii_case(GLOBAL_SCOPE) {
        GLOBAL_SCOPE
    } else {
        PROJECT_SCOPE
    }
}

fn normalize_secret_backend(backend: &str) -> Result<&'static str, String> {
    match backend.trim() {
        "" | KEYCHAIN_BACKEND => Ok(KEYCHAIN_BACKEND),
        ENV_FILE_BACKEND => Ok(ENV_FILE_BACKEND),
        other => Err(format!("unsupported secret backend: {other}")),
    }
}

fn normalize_secret_name(name: &str) -> Result<String, String> {
    let trimmed = name.trim();
    if trimmed.is_empty() {
        return Err("secret name must not be empty".to_string());
    }
    if trimmed.len() > 128 {
        return Err("secret name exceeds 128 characters".to_string());
    }
    if !trimmed.chars().enumerate().all(|(idx, ch)| {
        ch == '_' || ch.is_ascii_alphanumeric() && (idx > 0 || !ch.is_ascii_digit())
    }) {
        return Err("secret name must be a valid environment variable name".to_string());
    }
    Ok(trimmed.to_string())
}

fn normalize_env_file_path(path: Option<&str>) -> Result<Option<String>, String> {
    let Some(path) = path.map(str::trim).filter(|path| !path.is_empty()) else {
        return Ok(None);
    };
    if path != DEFAULT_ENV_FILE_PATH {
        return Err(format!(
            "file-backed secrets currently only support {DEFAULT_ENV_FILE_PATH}"
        ));
    }
    Ok(Some(path.to_string()))
}

fn project_keychain_service(scope: &str, project_id: Uuid) -> String {
    if scope == PROJECT_SCOPE {
        format!("pnevma.project.{project_id}")
    } else {
        "pnevma.global".to_string()
    }
}

fn ensure_secret_belongs_to_project(row: &SecretRefRow, project_id: Uuid) -> Result<(), String> {
    if row.scope == PROJECT_SCOPE
        && row.project_id.as_deref() != Some(project_id.to_string().as_str())
    {
        return Err("secret belongs to a different project".to_string());
    }
    Ok(())
}

async fn secret_row_to_view(row: &SecretRefRow, project_path: &Path) -> ProjectSecretView {
    let (status, status_message) = match resolve_secret_value(row, project_path).await {
        Ok(_) => ("configured".to_string(), None),
        Err(err)
            if err.contains("missing")
                || err.contains("not found")
                || err.contains("not managed")
                || err.contains("failed to read") =>
        {
            ("missing".to_string(), Some(err))
        }
        Err(err) => ("error".to_string(), Some(err)),
    };
    ProjectSecretView {
        id: row.id.clone(),
        project_id: row.project_id.clone(),
        scope: row.scope.clone(),
        name: row.name.clone(),
        backend: row.backend.clone(),
        location_display: if row.backend == KEYCHAIN_BACKEND {
            "Keychain".to_string()
        } else {
            row.env_file_path
                .clone()
                .unwrap_or_else(|| DEFAULT_ENV_FILE_PATH.to_string())
        },
        status,
        status_message,
        created_at: row.created_at,
        updated_at: row.updated_at,
    }
}

async fn refresh_secret_runtime(
    db: &Db,
    project_id: Uuid,
    sessions: &pnevma_session::SessionSupervisor,
    redaction_secrets: &Arc<tokio::sync::RwLock<Vec<String>>>,
) {
    let updated_redaction_secrets = load_redaction_secrets(db, project_id).await;
    register_project_redaction_secrets(project_id, &updated_redaction_secrets);
    sessions
        .set_redaction_secrets(updated_redaction_secrets.clone())
        .await;
    *redaction_secrets.write().await = updated_redaction_secrets;
}

async fn delete_secret_storage(row: &SecretRefRow, project_path: &Path) -> Result<(), String> {
    match row.backend.as_str() {
        KEYCHAIN_BACKEND => {
            let service = row
                .keychain_service
                .as_deref()
                .ok_or_else(|| "keychain secret missing service".to_string())?;
            let account = row
                .keychain_account
                .as_deref()
                .ok_or_else(|| "keychain secret missing account".to_string())?;
            delete_keychain_secret(service, account).await
        }
        ENV_FILE_BACKEND => {
            let rel_path = row
                .env_file_path
                .as_deref()
                .unwrap_or(DEFAULT_ENV_FILE_PATH);
            delete_env_file_secret(project_path, rel_path, &row.name).await
        }
        other => Err(format!("unsupported secret backend: {other}")),
    }
}

fn same_secret_storage(left: &SecretRefRow, right: &SecretRefRow) -> bool {
    left.backend == right.backend
        && left.keychain_service == right.keychain_service
        && left.keychain_account == right.keychain_account
        && left.env_file_path == right.env_file_path
        && left.name == right.name
}

async fn delete_keychain_secret(service: &str, account: &str) -> Result<(), String> {
    let status = Command::new("security")
        .args(["delete-generic-password", "-s", service, "-a", account])
        .status()
        .await
        .map_err(|e| format!("failed to delete Keychain item {service}/{account}: {e}"))?;
    if status.success() || status.code() == Some(44) {
        Ok(())
    } else {
        Err(format!(
            "failed to delete Keychain item {service}/{account}"
        ))
    }
}

async fn upsert_env_file_secret(
    project_path: &Path,
    rel_path: &str,
    name: &str,
    value: &str,
) -> Result<(), String> {
    ensure_env_file_git_ignored(project_path, rel_path).await?;
    let path = project_path.join(rel_path);
    let existing = read_existing_env_file(&path).await?;
    let mut entries = parse_managed_entries(&existing)?;
    entries.insert(name.to_string(), encode_env_value(value));
    let updated = write_managed_entries(&existing, &entries)?;
    write_env_file(&path, &updated).await
}

async fn read_env_file_secret(
    project_path: &Path,
    rel_path: &str,
    name: &str,
) -> Result<String, String> {
    let path = project_path.join(rel_path);
    let content = fs::read_to_string(&path)
        .await
        .map_err(|e| format!("failed to read {}: {e}", path.display()))?;
    let entries = parse_managed_entries(&content)?;
    let encoded = entries
        .get(name)
        .ok_or_else(|| format!("secret {name} missing from {}", path.display()))?;
    decode_env_value(encoded)
}

async fn delete_env_file_secret(
    project_path: &Path,
    rel_path: &str,
    name: &str,
) -> Result<(), String> {
    let path = project_path.join(rel_path);
    if fs::metadata(&path).await.is_err() {
        return Ok(());
    }
    let existing = read_existing_env_file(&path).await?;
    let mut entries = parse_managed_entries(&existing)?;
    entries.remove(name);
    let updated = write_managed_entries(&existing, &entries)?;
    write_env_file(&path, &updated).await
}

async fn read_existing_env_file(path: &Path) -> Result<String, String> {
    match fs::read_to_string(path).await {
        Ok(content) => Ok(content),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(String::new()),
        Err(err) => Err(format!("failed to read {}: {err}", path.display())),
    }
}

fn parse_managed_entries(content: &str) -> Result<BTreeMap<String, String>, String> {
    let trimmed = content.trim();
    let Some((start, end)) = managed_block_range(content) else {
        if trimmed.is_empty() {
            return Ok(BTreeMap::new());
        }
        return Err(format!(
            "{} exists but is not managed by Pnevma; import it first instead of overwriting it",
            DEFAULT_ENV_FILE_PATH
        ));
    };
    let block = &content[start..end];
    let mut out = BTreeMap::new();
    for (name, value) in parse_env_assignments(block) {
        out.insert(name, encode_env_value(&value));
    }
    Ok(out)
}

fn write_managed_entries(
    existing: &str,
    entries: &BTreeMap<String, String>,
) -> Result<String, String> {
    let mut block = String::new();
    block.push_str(MANAGED_BLOCK_BEGIN);
    block.push('\n');
    for (name, encoded_value) in entries {
        block.push_str(name);
        block.push('=');
        block.push_str(encoded_value);
        block.push('\n');
    }
    block.push_str(MANAGED_BLOCK_END);
    block.push('\n');

    match managed_block_sections(existing) {
        Some((prefix, suffix)) => Ok(format!("{prefix}{block}{suffix}")),
        None if existing.trim().is_empty() => Ok(block),
        None => Err(format!(
            "{} exists but is not managed by Pnevma; import it first instead of overwriting it",
            DEFAULT_ENV_FILE_PATH
        )),
    }
}

fn managed_block_sections(content: &str) -> Option<(String, String)> {
    let start = content.find(MANAGED_BLOCK_BEGIN)?;
    let end = content[start + MANAGED_BLOCK_BEGIN.len()..].find(MANAGED_BLOCK_END)?
        + start
        + MANAGED_BLOCK_BEGIN.len();
    let suffix_start = end + MANAGED_BLOCK_END.len();
    Some((
        content[..start].to_string(),
        content[suffix_start..].to_string(),
    ))
}

fn managed_block_range(content: &str) -> Option<(usize, usize)> {
    let start_marker = content.find(MANAGED_BLOCK_BEGIN)?;
    let after_start = start_marker + MANAGED_BLOCK_BEGIN.len();
    let end_marker = content[after_start..].find(MANAGED_BLOCK_END)? + after_start;
    Some((after_start, end_marker))
}

async fn write_env_file(path: &Path, content: &str) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .await
            .map_err(|e| format!("failed to create {}: {e}", parent.display()))?;
    }
    fs::write(path, content)
        .await
        .map_err(|e| format!("failed to write {}: {e}", path.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
            .await
            .map_err(|e| format!("failed to set permissions on {}: {e}", path.display()))?;
    }
    Ok(())
}

async fn ensure_env_file_git_ignored(project_path: &Path, rel_path: &str) -> Result<(), String> {
    if git_check_ignored(project_path, rel_path).await? {
        return Ok(());
    }
    let exclude_path = git_info_exclude_path(project_path).await?;
    let existing = read_existing_env_file(&exclude_path).await?;
    if !existing.lines().any(|line| line.trim() == rel_path) {
        let mut updated = existing;
        if !updated.is_empty() && !updated.ends_with('\n') {
            updated.push('\n');
        }
        updated.push_str(rel_path);
        updated.push('\n');
        write_env_file(&exclude_path, &updated).await?;
    }
    if git_check_ignored(project_path, rel_path).await? {
        Ok(())
    } else {
        Err(format!(
            "{rel_path} must be ignored by git before Pnevma can manage it"
        ))
    }
}

async fn git_check_ignored(project_path: &Path, rel_path: &str) -> Result<bool, String> {
    let status = tokio::process::Command::new("git")
        .args(["check-ignore", "-q", "--", rel_path])
        .current_dir(project_path)
        .status()
        .await
        .map_err(|e| format!("failed to run git check-ignore: {e}"))?;
    Ok(status.success())
}

async fn git_info_exclude_path(project_path: &Path) -> Result<PathBuf, String> {
    let output = tokio::process::Command::new("git")
        .args(["rev-parse", "--git-path", "info/exclude"])
        .current_dir(project_path)
        .output()
        .await
        .map_err(|e| format!("failed to locate git info/exclude: {e}"))?;
    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).trim().to_string());
    }
    let rel = PathBuf::from(String::from_utf8_lossy(&output.stdout).trim().to_string());
    if rel.is_absolute() {
        Ok(rel)
    } else {
        Ok(project_path.join(rel))
    }
}

fn parse_env_assignments(content: &str) -> Vec<(String, String)> {
    let mut out = Vec::new();
    for raw_line in content.lines() {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if line == MANAGED_BLOCK_BEGIN || line == MANAGED_BLOCK_END {
            continue;
        }
        let line = line.strip_prefix("export ").unwrap_or(line);
        let Some((name, value)) = line.split_once('=') else {
            continue;
        };
        let name = name.trim();
        if name.is_empty() {
            continue;
        }
        let value = value.trim();
        if let Ok(decoded) = decode_env_value(value) {
            out.push((name.to_string(), decoded));
        }
    }
    out
}

fn encode_env_value(value: &str) -> String {
    let mut out = String::with_capacity(value.len() + 2);
    out.push('"');
    for ch in value.chars() {
        match ch {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\t' => out.push_str("\\t"),
            _ => out.push(ch),
        }
    }
    out.push('"');
    out
}

fn decode_env_value(raw: &str) -> Result<String, String> {
    let trimmed = raw.trim();
    if trimmed.starts_with('"') && trimmed.ends_with('"') && trimmed.len() >= 2 {
        let mut out = String::new();
        let mut chars = trimmed[1..trimmed.len() - 1].chars();
        while let Some(ch) = chars.next() {
            if ch == '\\' {
                match chars.next() {
                    Some('\\') => out.push('\\'),
                    Some('"') => out.push('"'),
                    Some('t') => out.push('\t'),
                    Some(other) => out.push(other),
                    None => return Err("unterminated escape sequence".to_string()),
                }
            } else {
                out.push(ch);
            }
        }
        return Ok(out);
    }
    if trimmed.starts_with('\'') && trimmed.ends_with('\'') && trimmed.len() >= 2 {
        return Ok(trimmed[1..trimmed.len() - 1].to_string());
    }
    Ok(trimmed.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;
    use uuid::Uuid;

    #[test]
    fn decode_env_value_supports_quotes() {
        assert_eq!(decode_env_value("\"abc\\\"def\"").unwrap(), "abc\"def");
        assert_eq!(decode_env_value("'abc def'").unwrap(), "abc def");
        assert_eq!(decode_env_value("plain").unwrap(), "plain");
    }

    #[test]
    fn parse_env_assignments_skips_comments() {
        let parsed = parse_env_assignments(
            r#"
            # comment
            FOO=bar
            export BAR="baz qux"
            "#,
        );
        assert_eq!(
            parsed,
            vec![
                ("FOO".to_string(), "bar".to_string()),
                ("BAR".to_string(), "baz qux".to_string())
            ]
        );
    }

    #[test]
    fn dedupe_secret_refs_prefers_project_scope() {
        let name = "OPENAI_API_KEY".to_string();
        let global = SecretRefRow {
            id: Uuid::new_v4().to_string(),
            project_id: None,
            scope: GLOBAL_SCOPE.to_string(),
            name: name.clone(),
            backend: KEYCHAIN_BACKEND.to_string(),
            keychain_service: Some("pnevma.global".to_string()),
            keychain_account: Some(name.clone()),
            env_file_path: None,
            created_at: Utc::now(),
            updated_at: Utc::now(),
        };
        let project = SecretRefRow {
            id: Uuid::new_v4().to_string(),
            project_id: Some(Uuid::new_v4().to_string()),
            scope: PROJECT_SCOPE.to_string(),
            name: name.clone(),
            backend: KEYCHAIN_BACKEND.to_string(),
            keychain_service: Some(format!("pnevma.project.{}", Uuid::new_v4())),
            keychain_account: Some(name.clone()),
            env_file_path: None,
            created_at: Utc::now(),
            updated_at: Utc::now(),
        };

        let rows = dedupe_secret_refs(vec![global, project.clone()]);

        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].scope, PROJECT_SCOPE);
        assert_eq!(rows[0].id, project.id);
    }
}
