use crate::error::SessionError;
use crate::model::{SessionHealth, SessionMetadata, SessionStatus};
use chrono::{Duration, Utc};
use regex::Regex;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncSeekExt, AsyncWriteExt};
use tokio::process::{Child, ChildStdin, Command};
use tokio::sync::{broadcast, Mutex, RwLock};
use uuid::Uuid;

fn redaction_authorization_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"(?i)(authorization\s*:\s*bearer\s+)[^\s]+")
            .expect("authorization redaction regex must compile")
    })
}

fn redaction_key_value_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(
            r#"(?i)\b(api[_-]?key|token|secret|password)\b\s*[:=]\s*("[^"]*"|'[^']*'|[^\s,;]+)"#,
        )
        .expect("key-value redaction regex must compile")
    })
}

fn redaction_aws_key_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"AKIA[0-9A-Z]{16}").expect("AWS key redaction regex must compile")
    })
}

fn redaction_github_token_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"(?:ghp_|gho_|ghu_|ghs_|ghr_|github_pat_)[A-Za-z0-9_]{36,255}")
            .expect("GitHub token redaction regex must compile")
    })
}

fn redaction_slack_token_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"xox[bpras]-[A-Za-z0-9\-]{10,}")
            .expect("Slack token redaction regex must compile")
    })
}

fn redaction_pem_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"-----BEGIN (?:RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----")
            .expect("PEM redaction regex must compile")
    })
}

fn redaction_connection_string_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"://[^:]+:([^@]+)@").expect("connection string redaction regex must compile")
    })
}

fn redaction_partial_authorization_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"(?i)authorization\s*:\s*(?:(?:b|be|bea|bear|beare|bearer)(?:\s+[^\s]*)?)?$")
            .expect("partial authorization redaction regex must compile")
    })
}

fn redaction_partial_key_value_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(
            r#"(?i)\b(api[_-]?key|token|secret|password)\b\s*[:=]\s*("[^"]*|'[^']*|[^\s,;]*)$"#,
        )
        .expect("partial key-value redaction regex must compile")
    })
}

fn redaction_partial_aws_key_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"AKIA[0-9A-Z]{0,15}$").expect("partial AWS key redaction regex must compile")
    })
}

fn redaction_partial_github_token_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"(?:ghp_|gho_|ghu_|ghs_|ghr_|github_pat_)[A-Za-z0-9_]{0,255}$")
            .expect("partial GitHub token redaction regex must compile")
    })
}

fn redaction_partial_slack_token_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"xox[bpras]-[A-Za-z0-9\-]*$")
            .expect("partial Slack token redaction regex must compile")
    })
}

fn redaction_partial_connection_string_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"[A-Za-z][A-Za-z0-9+.-]*://[^:@\s]+:[^@\s]*$")
            .expect("partial connection string redaction regex must compile")
    })
}

fn redact_stream_text(input: &str, secrets: &[String]) -> String {
    let mut result = redaction_authorization_regex()
        .replace_all(input, "$1[REDACTED]")
        .to_string();
    result = redaction_key_value_regex()
        .replace_all(&result, "$1=[REDACTED]")
        .to_string();
    result = redaction_aws_key_regex()
        .replace_all(&result, "[REDACTED]")
        .to_string();
    result = redaction_github_token_regex()
        .replace_all(&result, "[REDACTED]")
        .to_string();
    result = redaction_slack_token_regex()
        .replace_all(&result, "[REDACTED]")
        .to_string();
    result = redaction_pem_regex()
        .replace_all(&result, "[REDACTED]")
        .to_string();
    result = redaction_connection_string_regex()
        .replace_all(&result, "://[REDACTED]@")
        .to_string();
    for secret in secrets {
        if secret.is_empty() {
            continue;
        }
        result = result.replace(secret, "[REDACTED]");
    }
    result
}

#[cfg(test)]
fn redact_stream_chunk(input: &str) -> String {
    redact_stream_text(input, &[])
}

fn normalize_redaction_secrets(secrets: &[String]) -> Vec<String> {
    let mut seen = HashSet::new();
    let mut normalized = secrets
        .iter()
        .filter(|secret| !secret.is_empty())
        .filter_map(|secret| {
            if seen.insert(secret.clone()) {
                Some(secret.clone())
            } else {
                None
            }
        })
        .collect::<Vec<_>>();
    normalized.sort_by(|a, b| b.len().cmp(&a.len()).then_with(|| a.cmp(b)));
    normalized
}

const STREAM_REDACTION_TAIL_BYTES: usize = 256;

fn minimum_partial_match_bytes(literal: &str) -> usize {
    if literal.len() <= 4 {
        2
    } else {
        3
    }
}

fn partial_literal_start(
    input: &str,
    literal: &str,
    retain_full_match: bool,
    min_match_bytes: usize,
) -> Option<usize> {
    if input.is_empty() || literal.is_empty() {
        return None;
    }

    let mut retain_start = None;
    for (idx, _) in literal.char_indices().skip(1) {
        if idx < min_match_bytes {
            continue;
        }
        if input.ends_with(&literal[..idx]) {
            retain_start = Some(input.len() - idx);
        }
    }

    if retain_full_match && literal.len() >= min_match_bytes && input.ends_with(literal) {
        return Some(input.len() - literal.len());
    }

    retain_start
}

fn partial_redaction_start(input: &str, secrets: &[String]) -> Option<usize> {
    const PEM_PREFIX_MARKERS: &[&str] = &[
        "-----BEGIN ",
        "-----BEGIN RSA PRIVATE KEY-----",
        "-----BEGIN EC PRIVATE KEY-----",
        "-----BEGIN DSA PRIVATE KEY-----",
        "-----BEGIN OPENSSH PRIVATE KEY-----",
        "-----BEGIN PRIVATE KEY-----",
    ];

    let mut retain_start = None;

    for marker in PEM_PREFIX_MARKERS {
        let candidate =
            partial_literal_start(input, marker, false, minimum_partial_match_bytes(marker));
        if let Some(start) = candidate {
            retain_start = Some(retain_start.map_or(start, |current: usize| current.min(start)));
        }
    }

    for secret in secrets {
        if let Some(start) =
            partial_literal_start(input, secret, false, minimum_partial_match_bytes(secret))
        {
            retain_start = Some(retain_start.map_or(start, |current: usize| current.min(start)));
        }
    }

    for regex in [
        redaction_partial_authorization_regex(),
        redaction_partial_key_value_regex(),
        redaction_partial_aws_key_regex(),
        redaction_partial_github_token_regex(),
        redaction_partial_slack_token_regex(),
        redaction_partial_connection_string_regex(),
    ] {
        if let Some(found) = regex.find(input) {
            retain_start = Some(
                retain_start.map_or(found.start(), |current: usize| current.min(found.start())),
            );
        }
    }

    retain_start
}

fn drain_to_retained_tail(input: &str, retain_bytes: usize) -> usize {
    if input.len() <= retain_bytes {
        return input.len();
    }

    let mut split_at = input.len() - retain_bytes;
    while split_at > 0 && !input.is_char_boundary(split_at) {
        split_at -= 1;
    }
    split_at
}

#[derive(Debug, Clone)]
struct StreamRedactor {
    pending: String,
    secrets: Arc<RwLock<Vec<String>>>,
}

impl StreamRedactor {
    fn new(secrets: Arc<RwLock<Vec<String>>>) -> Self {
        Self {
            pending: String::new(),
            secrets,
        }
    }

    async fn push_chunk(&mut self, chunk: &str) -> Option<String> {
        self.pending.push_str(chunk);
        self.drain(false).await
    }

    async fn finish(&mut self) -> Option<String> {
        self.drain(true).await
    }

    async fn drain(&mut self, flush_all: bool) -> Option<String> {
        if self.pending.is_empty() {
            return None;
        }

        let secrets = self.secrets.read().await.clone();
        let drain_to = if flush_all {
            self.pending.len()
        } else {
            let tail_boundary = drain_to_retained_tail(&self.pending, STREAM_REDACTION_TAIL_BYTES);
            partial_redaction_start(&self.pending, &secrets).map_or(tail_boundary, |retain_start| {
                tail_boundary.min(retain_start)
            })
        };

        if drain_to == 0 {
            return None;
        }

        let chunk = self.pending[..drain_to].to_string();
        self.pending.replace_range(..drain_to, "");
        Some(redact_stream_text(&chunk, &secrets))
    }
}

#[derive(Debug, Clone)]
pub enum SessionEvent {
    Spawned(SessionMetadata),
    Output {
        session_id: Uuid,
        chunk: String,
    },
    Heartbeat {
        session_id: Uuid,
        health: SessionHealth,
    },
    Exited {
        session_id: Uuid,
        code: Option<i32>,
    },
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct ScrollbackSlice {
    pub session_id: Uuid,
    pub start_offset: u64,
    pub end_offset: u64,
    pub total_bytes: u64,
    pub data: String,
}

#[derive(Debug, Clone, Copy)]
enum ScrollbackReadStart {
    Offset(u64),
    Tail,
}

/// Resolve a binary name to its full path, searching common macOS locations
/// in addition to the inherited PATH (which may be minimal for GUI apps).
fn resolve_binary(name: &str) -> PathBuf {
    let extra_dirs = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
    ];
    for dir in &extra_dirs {
        let candidate = PathBuf::from(dir).join(name);
        if candidate.exists() {
            return candidate;
        }
    }
    // Fall back to bare name (rely on PATH)
    PathBuf::from(name)
}

#[derive(Debug, Clone)]
pub struct SessionSupervisor {
    sessions: Arc<RwLock<HashMap<Uuid, SessionMetadata>>>,
    inputs: Arc<RwLock<HashMap<Uuid, Arc<Mutex<ChildStdin>>>>>,
    redaction_secrets: Arc<RwLock<Vec<String>>>,
    tx: broadcast::Sender<SessionEvent>,
    idle_after: Duration,
    stuck_after: Duration,
    data_dir: PathBuf,
    tmux_tmpdir: PathBuf,
    max_sessions: usize,
    tmux_bin: PathBuf,
    script_bin: PathBuf,
}

impl SessionSupervisor {
    pub fn new(data_dir: impl AsRef<Path>) -> Self {
        let data_dir = data_dir.as_ref().to_path_buf();
        let (tx, _) = broadcast::channel(512);
        Self {
            sessions: Arc::new(RwLock::new(HashMap::new())),
            inputs: Arc::new(RwLock::new(HashMap::new())),
            redaction_secrets: Arc::new(RwLock::new(Vec::new())),
            tx,
            idle_after: Duration::minutes(2),
            stuck_after: Duration::minutes(10),
            tmux_tmpdir: data_dir.join("tmux"),
            data_dir,
            max_sessions: 16,
            tmux_bin: resolve_binary("tmux"),
            script_bin: resolve_binary("script"),
        }
    }

    pub fn subscribe(&self) -> broadcast::Receiver<SessionEvent> {
        self.tx.subscribe()
    }

    pub fn tmux_tmpdir(&self) -> PathBuf {
        self.tmux_tmpdir.clone()
    }

    pub async fn set_redaction_secrets(&self, secrets: Vec<String>) {
        *self.redaction_secrets.write().await = normalize_redaction_secrets(&secrets);
    }

    pub async fn spawn_shell(
        &self,
        project_id: Uuid,
        name: impl Into<String>,
        cwd: impl Into<String>,
        command: impl Into<String>,
    ) -> Result<SessionMetadata, SessionError> {
        let session_id = Uuid::new_v4();

        // Check session count limit
        let current_count = self.sessions.read().await.len();
        if current_count >= self.max_sessions {
            return Err(SessionError::LimitReached(format!(
                "maximum of {} sessions reached",
                self.max_sessions
            )));
        }

        let now = Utc::now();
        let cwd = cwd.into();
        let command = command.into();
        let command_for_meta = if command.trim().is_empty() {
            "zsh".to_string()
        } else {
            command.clone()
        };

        let scrollback_path = self
            .data_dir
            .join("scrollback")
            .join(format!("{session_id}.log"));
        let scrollback_index_path = self
            .data_dir
            .join("scrollback")
            .join(format!("{session_id}.idx"));
        if let Some(parent) = scrollback_path.parent() {
            tokio::fs::create_dir_all(parent).await?;
        }
        tokio::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&scrollback_path)
            .await?;
        tokio::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&scrollback_index_path)
            .await?;

        self.create_tmux_session(session_id, &cwd, &command).await?;

        let meta = SessionMetadata {
            id: session_id,
            project_id,
            name: name.into(),
            status: SessionStatus::Waiting,
            health: SessionHealth::Waiting,
            pid: None,
            cwd: cwd.clone(),
            command: command_for_meta,
            branch: None,
            worktree_id: None,
            started_at: now,
            last_heartbeat: now,
            scrollback_path: scrollback_path.to_string_lossy().to_string(),
            exit_code: None,
            ended_at: None,
        };

        self.sessions.write().await.insert(session_id, meta.clone());
        let _ = self.tx.send(SessionEvent::Spawned(meta.clone()));
        self.attach_tmux_client(session_id).await?;

        self.get(session_id)
            .await
            .ok_or_else(|| SessionError::NotFound(session_id.to_string()))
    }

    pub async fn attach_existing(&self, session_id: Uuid) -> Result<(), SessionError> {
        if !self.sessions.read().await.contains_key(&session_id) {
            return Err(SessionError::NotFound(session_id.to_string()));
        }

        if self.inputs.read().await.contains_key(&session_id) {
            return Ok(());
        }

        if !self.tmux_has_session(&tmux_name(session_id)).await {
            return Err(SessionError::SpawnFailed(format!(
                "tmux session not found for {}",
                session_id
            )));
        }

        self.attach_tmux_client(session_id).await
    }

    pub async fn kill_session_backend(&self, session_id: Uuid) -> Result<(), SessionError> {
        self.ensure_tmux_tmpdir().await?;
        let name = tmux_name(session_id);
        let out = self
            .tmux_command()
            .args(["kill-session", "-t", &name])
            .output()
            .await
            .map_err(|e| SessionError::SpawnFailed(e.to_string()))?;

        if out.status.success() {
            return Ok(());
        }

        let stderr = String::from_utf8_lossy(&out.stderr).to_string();
        if stderr.contains("can't find session") {
            return Ok(());
        }

        Err(SessionError::SpawnFailed(format!(
            "tmux kill-session failed: {}",
            stderr.trim()
        )))
    }

    async fn create_tmux_session(
        &self,
        session_id: Uuid,
        cwd: &str,
        command: &str,
    ) -> Result<(), SessionError> {
        self.ensure_tmux_tmpdir().await?;
        let name = tmux_name(session_id);

        if self.tmux_has_session(&name).await {
            return Ok(());
        }

        // Create session WITHOUT a command to avoid shell expansion
        let args = vec![
            "new-session".to_string(),
            "-d".to_string(),
            "-s".to_string(),
            name.clone(),
            "-c".to_string(),
            cwd.to_string(),
        ];

        let out = self
            .tmux_command()
            .args(args)
            .output()
            .await
            .map_err(|e| SessionError::SpawnFailed(e.to_string()))?;

        if !out.status.success() {
            let stderr = String::from_utf8_lossy(&out.stderr).to_string();
            return Err(SessionError::SpawnFailed(format!(
                "tmux new-session failed: {}",
                stderr.trim()
            )));
        }

        // Hide the tmux status bar so only the shell content is visible
        let _ = self
            .tmux_command()
            .args(["set", "-t", &name, "status", "off"])
            .output()
            .await;

        // Send the command as literal keystrokes to prevent shell injection.
        // Skip bare shell names — tmux already starts a default shell.
        let bare_shells = ["zsh", "bash", "sh", "fish"];
        let is_bare_shell = bare_shells.iter().any(|s| {
            let trimmed = command.trim();
            trimmed == *s
                || std::path::Path::new(trimmed)
                    .file_name()
                    .and_then(|n| n.to_str())
                    .map_or(false, |n| n == *s)
        });
        if !command.trim().is_empty() && !is_bare_shell {
            let send_out = self
                .tmux_command()
                .args(["send-keys", "-t", &name, "-l", command])
                .output()
                .await
                .map_err(|e| SessionError::SpawnFailed(e.to_string()))?;

            if !send_out.status.success() {
                let stderr = String::from_utf8_lossy(&send_out.stderr).to_string();
                tracing::warn!(session_id = %session_id, "tmux send-keys failed: {}", stderr.trim());
            }

            // Press Enter to execute the command
            let enter_out = self
                .tmux_command()
                .args(["send-keys", "-t", &name, "Enter"])
                .output()
                .await
                .map_err(|e| SessionError::SpawnFailed(e.to_string()))?;

            if !enter_out.status.success() {
                let stderr = String::from_utf8_lossy(&enter_out.stderr).to_string();
                tracing::warn!(session_id = %session_id, "tmux send-keys Enter failed: {}", stderr.trim());
            }
        }

        Ok(())
    }

    async fn attach_tmux_client(&self, session_id: Uuid) -> Result<(), SessionError> {
        self.ensure_tmux_tmpdir().await?;

        let tmux_target = tmux_name(session_id);
        let scrollback_path = {
            let sessions = self.sessions.read().await;
            sessions
                .get(&session_id)
                .map(|meta| PathBuf::from(&meta.scrollback_path))
                .ok_or_else(|| SessionError::NotFound(session_id.to_string()))?
        };
        let scrollback_index_path = scrollback_path.with_extension("idx");

        let tmux_bin_str = self.tmux_bin.to_string_lossy().to_string();
        let mut child = self
            .script_command()
            .args([
                "-q",
                "/dev/null",
                &tmux_bin_str,
                "attach-session",
                "-t",
                &tmux_target,
            ])
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .map_err(|e| SessionError::SpawnFailed(e.to_string()))?;

        let pid = child.id();
        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| SessionError::SpawnFailed("attach stdin unavailable".to_string()))?;
        let stdout = child.stdout.take();
        let stderr = child.stderr.take();

        self.inputs
            .write()
            .await
            .insert(session_id, Arc::new(Mutex::new(stdin)));

        {
            let mut sessions = self.sessions.write().await;
            let meta = sessions
                .get_mut(&session_id)
                .ok_or_else(|| SessionError::NotFound(session_id.to_string()))?;
            meta.pid = pid;
            meta.status = SessionStatus::Running;
            meta.health = SessionHealth::Active;
            meta.last_heartbeat = Utc::now();
            meta.exit_code = None;
            meta.ended_at = None;
        }

        let _ = self.tx.send(SessionEvent::Heartbeat {
            session_id,
            health: SessionHealth::Active,
        });

        if let Some(stdout) = stdout {
            self.spawn_reader_task(
                session_id,
                stdout,
                scrollback_path.clone(),
                scrollback_index_path.clone(),
                self.redaction_secrets.clone(),
            );
        }
        if let Some(stderr) = stderr {
            self.spawn_reader_task(
                session_id,
                stderr,
                scrollback_path.clone(),
                scrollback_index_path.clone(),
                self.redaction_secrets.clone(),
            );
        }
        self.spawn_exit_task(session_id, child);

        Ok(())
    }

    fn spawn_reader_task<R>(
        &self,
        session_id: Uuid,
        mut reader: R,
        scrollback_path: PathBuf,
        scrollback_index_path: PathBuf,
        redaction_secrets: Arc<RwLock<Vec<String>>>,
    ) where
        R: AsyncRead + Send + Unpin + 'static,
    {
        let sessions = self.sessions.clone();
        let tx = self.tx.clone();

        tokio::spawn(async move {
            let file = tokio::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(scrollback_path.clone())
                .await;
            let Ok(file) = file else {
                return;
            };
            let file = Arc::new(Mutex::new(file));
            let index = tokio::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(scrollback_index_path)
                .await;
            let Ok(index) = index else {
                return;
            };
            let index = Arc::new(Mutex::new(index));
            let mut total = tokio::fs::metadata(&scrollback_path)
                .await
                .map(|m| m.len())
                .unwrap_or(0);
            let mut redactor = StreamRedactor::new(redaction_secrets);

            let mut buf = [0u8; 4096];
            loop {
                let read = match reader.read(&mut buf).await {
                    Ok(0) => break,
                    Ok(n) => n,
                    Err(_) => break,
                };
                let raw_chunk = String::from_utf8_lossy(&buf[..read]).to_string();
                {
                    let mut guard = sessions.write().await;
                    if let Some(meta) = guard.get_mut(&session_id) {
                        meta.last_heartbeat = Utc::now();
                        meta.health = SessionHealth::Active;
                        if meta.status != SessionStatus::Complete {
                            meta.status = SessionStatus::Running;
                        }
                    }
                }
                let _ = tx.send(SessionEvent::Heartbeat {
                    session_id,
                    health: SessionHealth::Active,
                });
                if let Some(chunk) = redactor.push_chunk(&raw_chunk).await {
                    let chunk_bytes = chunk.as_bytes();

                    {
                        let mut out = file.lock().await;
                        if out.write_all(chunk_bytes).await.is_err() {
                            break;
                        }
                        let _ = out.flush().await;
                    }
                    total = total.saturating_add(chunk_bytes.len() as u64);
                    {
                        let mut idx = index.lock().await;
                        let _ = idx.write_all(format!("{total}\n").as_bytes()).await;
                        let _ = idx.flush().await;
                    }

                    let _ = tx.send(SessionEvent::Output { session_id, chunk });
                }
            }

            if let Some(chunk) = redactor.finish().await {
                let chunk_bytes = chunk.as_bytes();
                {
                    let mut out = file.lock().await;
                    if out.write_all(chunk_bytes).await.is_ok() {
                        let _ = out.flush().await;
                    }
                }
                total = total.saturating_add(chunk_bytes.len() as u64);
                {
                    let mut idx = index.lock().await;
                    let _ = idx.write_all(format!("{total}\n").as_bytes()).await;
                    let _ = idx.flush().await;
                }
                let _ = tx.send(SessionEvent::Output { session_id, chunk });
            }
        });
    }

    fn spawn_exit_task(&self, session_id: Uuid, mut child: Child) {
        let sessions = self.sessions.clone();
        let inputs = self.inputs.clone();
        let tx = self.tx.clone();
        let tmux_tmpdir = self.tmux_tmpdir.clone();

        tokio::spawn(async move {
            let code = child.wait().await.ok().and_then(|status| status.code());
            let tmux_alive = tmux_has_session_name(&tmux_name(session_id), &tmux_tmpdir).await;

            {
                let mut guard = sessions.write().await;
                if let Some(meta) = guard.get_mut(&session_id) {
                    meta.last_heartbeat = Utc::now();
                    if tmux_alive {
                        meta.status = SessionStatus::Waiting;
                        meta.health = SessionHealth::Waiting;
                        meta.pid = None;
                    } else {
                        meta.status = SessionStatus::Complete;
                        meta.health = SessionHealth::Complete;
                        meta.pid = None;
                        meta.exit_code = code;
                        meta.ended_at = Some(Utc::now());
                    }
                }
            }

            inputs.write().await.remove(&session_id);
            let _ = tx.send(SessionEvent::Exited { session_id, code });
        });
    }

    pub async fn resize(&self, session_id: Uuid, cols: u16, rows: u16) -> Result<(), SessionError> {
        if !self.sessions.read().await.contains_key(&session_id) {
            return Err(SessionError::NotFound(session_id.to_string()));
        }

        self.ensure_tmux_tmpdir().await?;
        let name = tmux_name(session_id);

        let out = self
            .tmux_command()
            .args([
                "resize-window",
                "-t",
                &name,
                "-x",
                &cols.to_string(),
                "-y",
                &rows.to_string(),
            ])
            .output()
            .await
            .map_err(|e| SessionError::SpawnFailed(e.to_string()))?;

        if !out.status.success() {
            let stderr = String::from_utf8_lossy(&out.stderr);
            if !stderr.contains("no current client") && !stderr.contains("can't find session") {
                return Err(SessionError::SpawnFailed(format!(
                    "tmux resize-window failed: {}",
                    stderr.trim()
                )));
            }
        }

        Ok(())
    }

    pub async fn mark_activity(&self, session_id: Uuid) -> Result<(), SessionError> {
        let mut sessions = self.sessions.write().await;
        let Some(meta) = sessions.get_mut(&session_id) else {
            return Err(SessionError::NotFound(session_id.to_string()));
        };

        meta.last_heartbeat = Utc::now();
        meta.health = SessionHealth::Active;
        if meta.status != SessionStatus::Complete {
            meta.status = SessionStatus::Running;
        }
        let _ = self.tx.send(SessionEvent::Heartbeat {
            session_id,
            health: SessionHealth::Active,
        });
        Ok(())
    }

    pub async fn send_input(&self, session_id: Uuid, input: &str) -> Result<(), SessionError> {
        const MAX_INPUT_BYTES: usize = 64 * 1024; // 64 KB per send_input call
        if input.len() > MAX_INPUT_BYTES {
            return Err(SessionError::SpawnFailed(format!(
                "input too large: {} bytes (max {})",
                input.len(),
                MAX_INPUT_BYTES
            )));
        }

        // CONCURRENCY: Read lock on `inputs` is dropped before acquiring the per-session
        // ChildStdin Mutex. This two-step pattern (clone Arc then lock) avoids holding
        // the map lock while doing I/O, preventing contention across sessions.
        let writer = self
            .inputs
            .read()
            .await
            .get(&session_id)
            .cloned()
            .ok_or_else(|| SessionError::NotFound(session_id.to_string()))?;

        let mut lock = writer.lock().await;
        lock.write_all(input.as_bytes()).await?;
        lock.flush().await?;
        drop(lock);
        self.mark_activity(session_id).await
    }

    pub async fn register_restored(&self, meta: SessionMetadata) {
        self.sessions.write().await.insert(meta.id, meta.clone());
        let _ = self.tx.send(SessionEvent::Spawned(meta));
    }

    pub async fn read_scrollback(
        &self,
        session_id: Uuid,
        offset: u64,
        limit: usize,
    ) -> Result<ScrollbackSlice, SessionError> {
        self.read_scrollback_slice(session_id, ScrollbackReadStart::Offset(offset), limit)
            .await
    }

    pub async fn read_scrollback_tail(
        &self,
        session_id: Uuid,
        limit: usize,
    ) -> Result<ScrollbackSlice, SessionError> {
        self.read_scrollback_slice(session_id, ScrollbackReadStart::Tail, limit)
            .await
    }

    async fn read_scrollback_slice(
        &self,
        session_id: Uuid,
        start: ScrollbackReadStart,
        limit: usize,
    ) -> Result<ScrollbackSlice, SessionError> {
        const MAX_SCROLLBACK_READ_BYTES: usize = 10 * 1024 * 1024; // 10 MB
        const MAX_READ_LIMIT: usize = 1024 * 1024; // 1 MB per read

        let meta = self
            .sessions
            .read()
            .await
            .get(&session_id)
            .cloned()
            .ok_or_else(|| SessionError::NotFound(session_id.to_string()))?;

        let mut file = tokio::fs::OpenOptions::new()
            .read(true)
            .open(&meta.scrollback_path)
            .await?;
        let total = file.metadata().await?.len();

        if total as usize > MAX_SCROLLBACK_READ_BYTES {
            return Err(SessionError::SpawnFailed(format!(
                "scrollback file too large: {} bytes (max {})",
                total, MAX_SCROLLBACK_READ_BYTES
            )));
        }

        let capped_limit = limit.min(MAX_READ_LIMIT);
        let start = match start {
            ScrollbackReadStart::Offset(offset) => offset.min(total),
            ScrollbackReadStart::Tail => total.saturating_sub(capped_limit as u64),
        };
        file.seek(std::io::SeekFrom::Start(start)).await?;
        let mut buf = vec![0u8; capped_limit];
        let read = file.read(&mut buf).await?;
        buf.truncate(read);
        let data = String::from_utf8_lossy(&buf).to_string();

        Ok(ScrollbackSlice {
            session_id,
            start_offset: start,
            end_offset: start.saturating_add(read as u64),
            total_bytes: total,
            data,
        })
    }

    pub async fn refresh_health(&self) {
        let now = Utc::now();
        let mut sessions = self.sessions.write().await;

        for meta in sessions.values_mut() {
            if meta.status != SessionStatus::Running {
                continue;
            }

            let delta = now - meta.last_heartbeat;
            let next = if delta >= self.stuck_after {
                SessionHealth::Stuck
            } else if delta >= self.idle_after {
                SessionHealth::Idle
            } else {
                SessionHealth::Active
            };

            if meta.health != next {
                meta.health = next.clone();
                let _ = self.tx.send(SessionEvent::Heartbeat {
                    session_id: meta.id,
                    health: next,
                });
            }
        }
    }

    pub async fn mark_exit(&self, session_id: Uuid, code: Option<i32>) -> Result<(), SessionError> {
        {
            let mut sessions = self.sessions.write().await;
            let Some(meta) = sessions.get_mut(&session_id) else {
                return Err(SessionError::NotFound(session_id.to_string()));
            };

            meta.status = SessionStatus::Complete;
            meta.health = SessionHealth::Complete;
            meta.last_heartbeat = Utc::now();
            meta.pid = None;
            meta.exit_code = code;
            meta.ended_at = Some(Utc::now());
        }
        self.inputs.write().await.remove(&session_id);
        let _ = self.tx.send(SessionEvent::Exited { session_id, code });
        Ok(())
    }

    pub async fn get(&self, session_id: Uuid) -> Option<SessionMetadata> {
        self.sessions.read().await.get(&session_id).cloned()
    }

    pub async fn list(&self) -> Vec<SessionMetadata> {
        self.sessions.read().await.values().cloned().collect()
    }

    fn tmux_command(&self) -> Command {
        let mut cmd = Command::new(&self.tmux_bin);
        cmd.env("TMUX_TMPDIR", &self.tmux_tmpdir);
        cmd
    }

    fn script_command(&self) -> Command {
        let mut cmd = Command::new(&self.script_bin);
        cmd.env("TMUX_TMPDIR", &self.tmux_tmpdir);
        cmd
    }

    async fn ensure_tmux_tmpdir(&self) -> Result<(), SessionError> {
        tokio::fs::create_dir_all(&self.tmux_tmpdir).await?;
        Ok(())
    }

    async fn tmux_has_session(&self, name: &str) -> bool {
        tmux_has_session_name(name, &self.tmux_tmpdir).await
    }
}

fn tmux_name(session_id: Uuid) -> String {
    format!("pnevma_{}", session_id.simple())
}

async fn tmux_has_session_name(name: &str, tmux_tmpdir: &Path) -> bool {
    let _ = tokio::fs::create_dir_all(tmux_tmpdir).await;

    Command::new(resolve_binary("tmux"))
        .env("TMUX_TMPDIR", tmux_tmpdir)
        .args(["has-session", "-t", name])
        .status()
        .await
        .map(|status| status.success())
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::redact_stream_chunk;
    use super::SessionSupervisor;
    use super::StreamRedactor;
    use crate::error::SessionError;
    use crate::model::{SessionHealth, SessionMetadata, SessionStatus};
    use chrono::Utc;
    use std::sync::Arc;
    use tokio::sync::RwLock;
    use uuid::Uuid;

    #[test]
    fn redacts_stream_secrets_by_pattern() {
        let input = "Authorization: Bearer abc123 password=swordfish";
        let redacted = redact_stream_chunk(input);
        assert!(!redacted.contains("abc123"));
        assert!(!redacted.contains("swordfish"));
        assert!(redacted.contains("[REDACTED]"));
    }

    #[tokio::test]
    async fn stream_redactor_redacts_secret_split_across_chunks() {
        let secrets = Arc::new(RwLock::new(vec!["supersecret123".to_string()]));
        let mut redactor = StreamRedactor::new(secrets);

        let first = redactor
            .push_chunk("prefix super")
            .await
            .expect("safe prefix should flush");
        assert_eq!(first, "prefix ");

        let second = redactor
            .push_chunk("secret123 suffix")
            .await
            .expect("completed secret should flush");
        assert_eq!(second, "[REDACTED] suffix");
    }

    #[tokio::test]
    async fn stream_redactor_redacts_pattern_split_across_chunks() {
        let secrets = Arc::new(RwLock::new(Vec::new()));
        let mut redactor = StreamRedactor::new(secrets);

        assert!(
            redactor.push_chunk("Authorization: Bea").await.is_none(),
            "partial auth prefix should be retained"
        );

        let output = redactor
            .push_chunk("rer abc123\n")
            .await
            .expect("completed auth header should flush");
        assert_eq!(output, "Authorization: Bearer [REDACTED]\n");
    }

    #[tokio::test]
    async fn stream_redactor_flushes_safe_marker_words_immediately() {
        let secrets = Arc::new(RwLock::new(Vec::new()));
        let mut redactor = StreamRedactor::new(secrets);

        let output = redactor
            .push_chunk("enter password\n")
            .await
            .expect("safe text should flush immediately");
        assert_eq!(output, "enter password\n");
    }

    #[tokio::test]
    async fn read_scrollback_missing_session_is_not_found() {
        let root = std::env::temp_dir().join(format!("pnevma-session-test-{}", Uuid::new_v4()));
        let supervisor = SessionSupervisor::new(&root);
        let err = supervisor
            .read_scrollback(Uuid::new_v4(), 0, 128)
            .await
            .expect_err("missing session should error");
        assert!(matches!(err, SessionError::NotFound(_)));
    }

    #[tokio::test]
    async fn send_input_missing_session_is_not_found() {
        let root = std::env::temp_dir().join(format!("pnevma-session-test-{}", Uuid::new_v4()));
        let supervisor = SessionSupervisor::new(&root);
        let err = supervisor
            .send_input(Uuid::new_v4(), "echo test\n")
            .await
            .expect_err("missing session should error");
        assert!(matches!(err, SessionError::NotFound(_)));
    }

    #[tokio::test]
    async fn read_scrollback_missing_file_returns_io_error() {
        let root = std::env::temp_dir().join(format!("pnevma-session-test-{}", Uuid::new_v4()));
        let supervisor = SessionSupervisor::new(&root);
        let session_id = Uuid::new_v4();
        let now = Utc::now();
        let missing_path = root
            .join("scrollback")
            .join(format!("{session_id}.missing.log"));
        supervisor
            .register_restored(SessionMetadata {
                id: session_id,
                project_id: Uuid::new_v4(),
                name: "restored".to_string(),
                status: SessionStatus::Waiting,
                health: SessionHealth::Waiting,
                pid: None,
                cwd: ".".to_string(),
                command: "zsh".to_string(),
                branch: None,
                worktree_id: None,
                started_at: now,
                last_heartbeat: now,
                scrollback_path: missing_path.to_string_lossy().to_string(),
                exit_code: None,
                ended_at: None,
            })
            .await;

        let err = supervisor
            .read_scrollback(session_id, 0, 128)
            .await
            .expect_err("missing scrollback file should error");
        assert!(matches!(err, SessionError::Io(_)));
    }

    #[tokio::test]
    async fn read_scrollback_clamps_offset_beyond_total() {
        let root = std::env::temp_dir().join(format!("pnevma-session-test-{}", Uuid::new_v4()));
        let supervisor = SessionSupervisor::new(&root);
        let session_id = Uuid::new_v4();
        let now = Utc::now();
        let scrollback_path = root.join("scrollback").join(format!("{session_id}.log"));
        tokio::fs::create_dir_all(scrollback_path.parent().expect("scrollback parent"))
            .await
            .expect("create scrollback dir");
        tokio::fs::write(&scrollback_path, b"hello world")
            .await
            .expect("write scrollback");

        supervisor
            .register_restored(SessionMetadata {
                id: session_id,
                project_id: Uuid::new_v4(),
                name: "restored".to_string(),
                status: SessionStatus::Waiting,
                health: SessionHealth::Waiting,
                pid: None,
                cwd: ".".to_string(),
                command: "zsh".to_string(),
                branch: None,
                worktree_id: None,
                started_at: now,
                last_heartbeat: now,
                scrollback_path: scrollback_path.to_string_lossy().to_string(),
                exit_code: None,
                ended_at: None,
            })
            .await;

        let slice = supervisor
            .read_scrollback(session_id, 10_000, 128)
            .await
            .expect("read scrollback should succeed");
        assert_eq!(slice.start_offset, slice.total_bytes);
        assert_eq!(slice.end_offset, slice.total_bytes);
        assert!(slice.data.is_empty());
    }

    #[tokio::test]
    async fn read_scrollback_tail_returns_latest_bytes() {
        let root = std::env::temp_dir().join(format!("pnevma-session-test-{}", Uuid::new_v4()));
        let supervisor = SessionSupervisor::new(&root);
        let session_id = Uuid::new_v4();
        let now = Utc::now();
        let scrollback_path = root.join("scrollback").join(format!("{session_id}.log"));
        tokio::fs::create_dir_all(scrollback_path.parent().expect("scrollback parent"))
            .await
            .expect("create scrollback dir");
        tokio::fs::write(&scrollback_path, b"alpha\nbeta\ngamma\n")
            .await
            .expect("write scrollback");

        supervisor
            .register_restored(SessionMetadata {
                id: session_id,
                project_id: Uuid::new_v4(),
                name: "restored".to_string(),
                status: SessionStatus::Waiting,
                health: SessionHealth::Waiting,
                pid: None,
                cwd: ".".to_string(),
                command: "zsh".to_string(),
                branch: None,
                worktree_id: None,
                started_at: now,
                last_heartbeat: now,
                scrollback_path: scrollback_path.to_string_lossy().to_string(),
                exit_code: None,
                ended_at: None,
            })
            .await;

        let slice = supervisor
            .read_scrollback_tail(session_id, 6)
            .await
            .expect("tail read should succeed");
        assert_eq!(slice.start_offset, slice.total_bytes - 6);
        assert_eq!(slice.end_offset, slice.total_bytes);
        assert_eq!(slice.data, "gamma\n");
    }

    #[tokio::test]
    async fn read_scrollback_zero_limit_returns_empty_slice() {
        let root = std::env::temp_dir().join(format!("pnevma-session-test-{}", Uuid::new_v4()));
        let supervisor = SessionSupervisor::new(&root);
        let session_id = Uuid::new_v4();
        let now = Utc::now();
        let scrollback_path = root.join("scrollback").join(format!("{session_id}.log"));
        tokio::fs::create_dir_all(scrollback_path.parent().expect("scrollback parent"))
            .await
            .expect("create scrollback dir");
        tokio::fs::write(&scrollback_path, b"hello world")
            .await
            .expect("write scrollback");

        supervisor
            .register_restored(SessionMetadata {
                id: session_id,
                project_id: Uuid::new_v4(),
                name: "restored".to_string(),
                status: SessionStatus::Waiting,
                health: SessionHealth::Waiting,
                pid: None,
                cwd: ".".to_string(),
                command: "zsh".to_string(),
                branch: None,
                worktree_id: None,
                started_at: now,
                last_heartbeat: now,
                scrollback_path: scrollback_path.to_string_lossy().to_string(),
                exit_code: None,
                ended_at: None,
            })
            .await;

        let slice = supervisor
            .read_scrollback(session_id, 0, 0)
            .await
            .expect("read scrollback should succeed");
        assert_eq!(slice.start_offset, 0);
        assert_eq!(slice.end_offset, 0);
        assert!(slice.data.is_empty());
    }

    #[tokio::test]
    async fn read_scrollback_directory_path_returns_io_error() {
        let root = std::env::temp_dir().join(format!("pnevma-session-test-{}", Uuid::new_v4()));
        let supervisor = SessionSupervisor::new(&root);
        let session_id = Uuid::new_v4();
        let now = Utc::now();
        let dir_path = root.join("scrollback").join(format!("{session_id}.log"));
        tokio::fs::create_dir_all(&dir_path)
            .await
            .expect("create directory path");

        supervisor
            .register_restored(SessionMetadata {
                id: session_id,
                project_id: Uuid::new_v4(),
                name: "restored".to_string(),
                status: SessionStatus::Waiting,
                health: SessionHealth::Waiting,
                pid: None,
                cwd: ".".to_string(),
                command: "zsh".to_string(),
                branch: None,
                worktree_id: None,
                started_at: now,
                last_heartbeat: now,
                scrollback_path: dir_path.to_string_lossy().to_string(),
                exit_code: None,
                ended_at: None,
            })
            .await;

        let err = supervisor
            .read_scrollback(session_id, 0, 128)
            .await
            .expect_err("directory scrollback path should error");
        assert!(matches!(err, SessionError::Io(_)));
    }

    #[tokio::test]
    async fn read_scrollback_invalid_utf8_is_lossy_but_safe() {
        let root = std::env::temp_dir().join(format!("pnevma-session-test-{}", Uuid::new_v4()));
        let supervisor = SessionSupervisor::new(&root);
        let session_id = Uuid::new_v4();
        let now = Utc::now();
        let scrollback_path = root.join("scrollback").join(format!("{session_id}.log"));
        tokio::fs::create_dir_all(scrollback_path.parent().expect("scrollback parent"))
            .await
            .expect("create scrollback dir");
        tokio::fs::write(&scrollback_path, [b'f', b'o', 0x80, b'o'])
            .await
            .expect("write invalid utf8");

        supervisor
            .register_restored(SessionMetadata {
                id: session_id,
                project_id: Uuid::new_v4(),
                name: "restored".to_string(),
                status: SessionStatus::Waiting,
                health: SessionHealth::Waiting,
                pid: None,
                cwd: ".".to_string(),
                command: "zsh".to_string(),
                branch: None,
                worktree_id: None,
                started_at: now,
                last_heartbeat: now,
                scrollback_path: scrollback_path.to_string_lossy().to_string(),
                exit_code: None,
                ended_at: None,
            })
            .await;

        let slice = supervisor
            .read_scrollback(session_id, 0, 128)
            .await
            .expect("read scrollback should succeed");
        assert!(slice.data.contains('\u{FFFD}'));
    }

    // ── Health state transitions ─────────────────────────────────────────────

    async fn make_running_session(
        root: &std::path::Path,
        supervisor: &SessionSupervisor,
        last_heartbeat: chrono::DateTime<Utc>,
    ) -> Uuid {
        let session_id = Uuid::new_v4();
        let scrollback_path = root.join("scrollback").join(format!("{session_id}.log"));
        let now = Utc::now();
        supervisor
            .register_restored(SessionMetadata {
                id: session_id,
                project_id: Uuid::new_v4(),
                name: "test".to_string(),
                status: SessionStatus::Running,
                health: SessionHealth::Active,
                pid: None,
                cwd: ".".to_string(),
                command: "zsh".to_string(),
                branch: None,
                worktree_id: None,
                started_at: now,
                last_heartbeat,
                scrollback_path: scrollback_path.to_string_lossy().to_string(),
                exit_code: None,
                ended_at: None,
            })
            .await;
        session_id
    }

    #[tokio::test]
    async fn refresh_health_active_when_recent_heartbeat() {
        let root = std::env::temp_dir().join(format!("pnevma-session-test-{}", Uuid::new_v4()));
        let supervisor = SessionSupervisor::new(&root);

        let session_id = make_running_session(&root, &supervisor, Utc::now()).await;

        supervisor.refresh_health().await;

        let meta = supervisor.get(session_id).await.expect("session exists");
        assert_eq!(meta.health, SessionHealth::Active);
    }

    #[tokio::test]
    async fn refresh_health_idle_after_2_minutes() {
        let root = std::env::temp_dir().join(format!("pnevma-session-test-{}", Uuid::new_v4()));
        let supervisor = SessionSupervisor::new(&root);

        // Last heartbeat 3 minutes ago — crosses idle_after (2min)
        let session_id = make_running_session(
            &root,
            &supervisor,
            Utc::now() - chrono::Duration::minutes(3),
        )
        .await;

        supervisor.refresh_health().await;

        let meta = supervisor.get(session_id).await.expect("session exists");
        assert_eq!(meta.health, SessionHealth::Idle);
    }

    #[tokio::test]
    async fn refresh_health_stuck_after_10_minutes() {
        let root = std::env::temp_dir().join(format!("pnevma-session-test-{}", Uuid::new_v4()));
        let supervisor = SessionSupervisor::new(&root);

        // Last heartbeat 11 minutes ago — crosses stuck_after (10min)
        let session_id = make_running_session(
            &root,
            &supervisor,
            Utc::now() - chrono::Duration::minutes(11),
        )
        .await;

        supervisor.refresh_health().await;

        let meta = supervisor.get(session_id).await.expect("session exists");
        assert_eq!(meta.health, SessionHealth::Stuck);
    }

    #[tokio::test]
    async fn refresh_health_skips_non_running_sessions() {
        let root = std::env::temp_dir().join(format!("pnevma-session-test-{}", Uuid::new_v4()));
        let supervisor = SessionSupervisor::new(&root);
        let session_id = Uuid::new_v4();
        let old_heartbeat = Utc::now() - chrono::Duration::minutes(30);
        let scrollback = root.join("scrollback").join(format!("{session_id}.log"));

        // Register a session that is Complete — should not be changed by refresh
        supervisor
            .register_restored(SessionMetadata {
                id: session_id,
                project_id: Uuid::new_v4(),
                name: "complete".to_string(),
                status: SessionStatus::Complete,
                health: SessionHealth::Complete,
                pid: None,
                cwd: ".".to_string(),
                command: "zsh".to_string(),
                branch: None,
                worktree_id: None,
                started_at: Utc::now(),
                last_heartbeat: old_heartbeat,
                scrollback_path: scrollback.to_string_lossy().to_string(),
                exit_code: Some(0),
                ended_at: None,
            })
            .await;

        supervisor.refresh_health().await;

        let meta = supervisor.get(session_id).await.expect("session exists");
        assert_eq!(meta.health, SessionHealth::Complete);
    }

    // ── mark_exit ───────────────────────────────────────────────────────────

    #[tokio::test]
    async fn mark_exit_transitions_session_to_complete() {
        let root = std::env::temp_dir().join(format!("pnevma-session-test-{}", Uuid::new_v4()));
        let supervisor = SessionSupervisor::new(&root);
        let session_id = Uuid::new_v4();
        let scrollback = root.join("scrollback").join(format!("{session_id}.log"));

        supervisor
            .register_restored(SessionMetadata {
                id: session_id,
                project_id: Uuid::new_v4(),
                name: "exiting".to_string(),
                status: SessionStatus::Running,
                health: SessionHealth::Active,
                pid: None,
                cwd: ".".to_string(),
                command: "zsh".to_string(),
                branch: None,
                worktree_id: None,
                started_at: Utc::now(),
                last_heartbeat: Utc::now(),
                scrollback_path: scrollback.to_string_lossy().to_string(),
                exit_code: None,
                ended_at: None,
            })
            .await;

        supervisor
            .mark_exit(session_id, Some(0))
            .await
            .expect("mark_exit");

        let meta = supervisor.get(session_id).await.expect("session exists");
        assert_eq!(meta.status, SessionStatus::Complete);
        assert_eq!(meta.health, SessionHealth::Complete);
        assert_eq!(meta.exit_code, Some(0));
        assert!(meta.ended_at.is_some());
    }

    #[tokio::test]
    async fn mark_exit_missing_session_returns_not_found() {
        let root = std::env::temp_dir().join(format!("pnevma-session-test-{}", Uuid::new_v4()));
        let supervisor = SessionSupervisor::new(&root);
        let err = supervisor
            .mark_exit(Uuid::new_v4(), None)
            .await
            .expect_err("missing session");
        assert!(matches!(err, SessionError::NotFound(_)));
    }

    // ── Redaction patterns ───────────────────────────────────────────────────

    #[test]
    fn redacts_aws_access_key() {
        let input = "found key AKIAIOSFODNN7EXAMPLE in config";
        let output = redact_stream_chunk(input);
        assert!(!output.contains("AKIAIOSFODNN7EXAMPLE"));
        assert!(output.contains("[REDACTED]"));
    }

    #[test]
    fn redacts_github_token() {
        let input = "GITHUB_TOKEN=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij0123";
        let output = redact_stream_chunk(input);
        assert!(!output.contains("ghp_"));
    }

    #[test]
    fn redacts_slack_token() {
        let input = "SLACK_TOKEN=xoxb-123456789012-abcdef";
        let output = redact_stream_chunk(input);
        assert!(!output.contains("xoxb-"));
    }

    #[test]
    fn redacts_pem_private_key() {
        let input = "-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAK...";
        let output = redact_stream_chunk(input);
        assert!(!output.contains("BEGIN RSA PRIVATE KEY"));
    }

    #[test]
    fn redacts_connection_string_password() {
        let input = "postgres://user:secretpass@localhost:5432/db";
        let output = redact_stream_chunk(input);
        assert!(!output.contains("secretpass"));
    }

    #[test]
    fn does_not_redact_normal_text() {
        let input = "Hello, world! This is a normal log line.";
        let output = redact_stream_chunk(input);
        assert_eq!(output, input);
    }

    #[test]
    fn redacts_api_key_assignment() {
        let input = "api_key=supersecret123";
        let output = redact_stream_chunk(input);
        assert!(!output.contains("supersecret123"));
        assert!(output.contains("[REDACTED]"));
    }

    #[test]
    fn redacts_password_colon_form() {
        let input = r#"password: "mypassword""#;
        let output = redact_stream_chunk(input);
        assert!(!output.contains("mypassword"));
        assert!(output.contains("[REDACTED]"));
    }

    // ── list/get ─────────────────────────────────────────────────────────────

    #[tokio::test]
    async fn list_returns_all_registered_sessions() {
        let root = std::env::temp_dir().join(format!("pnevma-session-test-{}", Uuid::new_v4()));
        let supervisor = SessionSupervisor::new(&root);

        for i in 0..3 {
            let id = Uuid::new_v4();
            let scrollback = root.join("scrollback").join(format!("{id}.log"));
            supervisor
                .register_restored(SessionMetadata {
                    id,
                    project_id: Uuid::new_v4(),
                    name: format!("session-{i}"),
                    status: SessionStatus::Waiting,
                    health: SessionHealth::Waiting,
                    pid: None,
                    cwd: ".".to_string(),
                    command: "zsh".to_string(),
                    branch: None,
                    worktree_id: None,
                    started_at: Utc::now(),
                    last_heartbeat: Utc::now(),
                    scrollback_path: scrollback.to_string_lossy().to_string(),
                    exit_code: None,
                    ended_at: None,
                })
                .await;
        }

        assert_eq!(supervisor.list().await.len(), 3);
    }

    #[tokio::test]
    async fn get_returns_none_for_unknown_id() {
        let root = std::env::temp_dir().join(format!("pnevma-session-test-{}", Uuid::new_v4()));
        let supervisor = SessionSupervisor::new(&root);
        assert!(supervisor.get(Uuid::new_v4()).await.is_none());
    }
}
