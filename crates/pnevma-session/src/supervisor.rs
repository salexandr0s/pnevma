use crate::error::SessionError;
use crate::model::{SessionHealth, SessionMetadata, SessionStatus};
use chrono::{Duration, Utc};
use pnevma_redaction::{normalize_secrets, StreamRedactionBuffer};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicI64, AtomicU8, Ordering};
use std::sync::Arc;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncSeekExt, AsyncWriteExt};
use tokio::process::{Child, ChildStdin, Command};
use tokio::sync::{broadcast, Mutex, RwLock};
use uuid::Uuid;

#[cfg(test)]
fn redact_stream_chunk(input: &str) -> String {
    pnevma_redaction::redact_text(input, &[])
}

#[derive(Debug, Clone)]
struct StreamRedactor {
    buffer: StreamRedactionBuffer,
    secrets: Arc<RwLock<Vec<String>>>,
}

impl StreamRedactor {
    fn new(secrets: Arc<RwLock<Vec<String>>>) -> Self {
        Self {
            buffer: StreamRedactionBuffer::new(),
            secrets,
        }
    }

    async fn push_chunk(&mut self, chunk: &str) -> Option<String> {
        let secrets = self.secrets.read().await.clone();
        self.buffer.push_chunk(chunk, &secrets)
    }

    async fn finish(&mut self) -> Option<String> {
        let secrets = self.secrets.read().await.clone();
        self.buffer.finish(&secrets)
    }
}

async fn open_append_only_file(path: &Path) -> std::io::Result<tokio::fs::File> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};

        let path = path.to_path_buf();
        let std_file = tokio::task::spawn_blocking(move || {
            let file = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .mode(0o600)
                .open(&path)?;
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
            Ok::<std::fs::File, std::io::Error>(file)
        })
        .await
        .map_err(std::io::Error::other)??;
        Ok(tokio::fs::File::from_std(std_file))
    }

    #[cfg(not(unix))]
    {
        Ok(tokio::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .await?)
    }
}

/// Maximum scrollback file size for re-redaction (avoid unbounded memory).
const MAX_RE_REDACT_BYTES: u64 = 50 * 1024 * 1024; // 50 MB

/// Open a scrollback file in read+write+create mode for sharing between
/// the reader task and re-redaction.
async fn open_scrollback_rw(path: &Path) -> std::io::Result<tokio::fs::File> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
        let path = path.to_path_buf();
        let std_file = tokio::task::spawn_blocking(move || {
            let file = std::fs::OpenOptions::new()
                .create(true)
                .truncate(false)
                .read(true)
                .write(true)
                .mode(0o600)
                .open(&path)?;
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
            Ok::<std::fs::File, std::io::Error>(file)
        })
        .await
        .map_err(std::io::Error::other)??;
        Ok(tokio::fs::File::from_std(std_file))
    }

    #[cfg(not(unix))]
    {
        tokio::fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(path)
            .await
    }
}

/// Retroactively redact secrets from a scrollback file.
///
/// Uses the SAME `Arc<Mutex<File>>` as the reader task, ensuring the
/// reader is blocked during rewrite. After completion the file position
/// is at the end so the reader can resume appending.
async fn re_redact_scrollback(
    file: Arc<Mutex<tokio::fs::File>>,
    secrets: &[String],
) -> std::io::Result<()> {
    use tokio::io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt};
    let mut f = file.lock().await;

    // Skip large files to avoid unbounded memory usage.
    let file_len = f.seek(std::io::SeekFrom::End(0)).await?;
    if file_len > MAX_RE_REDACT_BYTES {
        tracing::warn!(
            file_len,
            max = MAX_RE_REDACT_BYTES,
            "scrollback too large for re-redaction, skipping"
        );
        return Ok(());
    }

    f.seek(std::io::SeekFrom::Start(0)).await?;
    let mut content = String::new();
    f.read_to_string(&mut content).await?;

    let redacted = pnevma_redaction::redact_text(&content, secrets);
    if redacted == content {
        f.seek(std::io::SeekFrom::End(0)).await?;
        return Ok(());
    }

    f.seek(std::io::SeekFrom::Start(0)).await?;
    f.set_len(0).await?;
    f.write_all(redacted.as_bytes()).await?;
    f.flush().await?;
    Ok(())
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionBackendKillResult {
    Killed,
    AlreadyGone,
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
pub fn resolve_binary(name: &str) -> PathBuf {
    let extra_dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"];
    for dir in &extra_dirs {
        let candidate = PathBuf::from(dir).join(name);
        if candidate.exists() {
            return candidate;
        }
    }
    // Fall back to bare name (rely on PATH)
    PathBuf::from(name)
}

/// Encodes `SessionHealth` as a `u8` for atomic storage.
fn health_to_u8(h: &SessionHealth) -> u8 {
    match h {
        SessionHealth::Active => 0,
        SessionHealth::Idle => 1,
        SessionHealth::Stuck => 2,
        SessionHealth::Waiting => 3,
        SessionHealth::Error => 4,
        SessionHealth::Complete => 5,
    }
}

/// Decodes a `u8` back to `SessionHealth`.
fn u8_to_health(v: u8) -> SessionHealth {
    match v {
        0 => SessionHealth::Active,
        1 => SessionHealth::Idle,
        2 => SessionHealth::Stuck,
        3 => SessionHealth::Waiting,
        4 => SessionHealth::Error,
        _ => SessionHealth::Complete,
    }
}

/// Lock-free heartbeat and health state, stored parallel to `SessionMetadata`.
/// Reads from these atomics avoid taking a write lock on the sessions map.
#[derive(Debug)]
struct AtomicSessionState {
    last_heartbeat: AtomicI64,
    health: AtomicU8,
}

impl AtomicSessionState {
    fn new(heartbeat_ts: i64, health: &SessionHealth) -> Self {
        Self {
            last_heartbeat: AtomicI64::new(heartbeat_ts),
            health: AtomicU8::new(health_to_u8(health)),
        }
    }
}

// Manual Clone impl because AtomicI64/AtomicU8 are not Clone; we load+copy.
impl Clone for AtomicSessionState {
    fn clone(&self) -> Self {
        Self {
            last_heartbeat: AtomicI64::new(self.last_heartbeat.load(Ordering::Relaxed)),
            health: AtomicU8::new(self.health.load(Ordering::Relaxed)),
        }
    }
}

#[derive(Debug, Clone)]
pub struct SessionSupervisor {
    sessions: Arc<RwLock<HashMap<Uuid, SessionMetadata>>>,
    /// Lock-free heartbeat/health data parallel to `sessions`.
    atomic_states: Arc<RwLock<HashMap<Uuid, Arc<AtomicSessionState>>>>,
    inputs: Arc<RwLock<HashMap<Uuid, Arc<Mutex<ChildStdin>>>>>,
    /// Shared scrollback file handles for re-redaction. The SAME handle is
    /// used by reader tasks and `re_redact_scrollback`, ensuring mutual
    /// exclusion via a single Mutex.
    scrollback_files: Arc<RwLock<HashMap<Uuid, Arc<Mutex<tokio::fs::File>>>>>,
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
            atomic_states: Arc::new(RwLock::new(HashMap::new())),
            inputs: Arc::new(RwLock::new(HashMap::new())),
            scrollback_files: Arc::new(RwLock::new(HashMap::new())),
            redaction_secrets: Arc::new(RwLock::new(Vec::new())),
            tx,
            idle_after: Duration::minutes(2),
            stuck_after: Duration::minutes(10),
            tmux_tmpdir: data_dir.join("tmux"),
            data_dir,
            max_sessions: 64,
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
        let new_secrets = normalize_secrets(&secrets);
        let old_secrets = {
            let mut guard = self.redaction_secrets.write().await;
            let old = guard.clone();
            *guard = new_secrets.clone();
            old
        };

        // Only re-redact if new secrets were actually added.
        let has_new = new_secrets.iter().any(|s| !old_secrets.contains(s));
        if !has_new {
            return;
        }

        // Collect file handles for active sessions.
        let handles: Vec<Arc<Mutex<tokio::fs::File>>> = {
            let sessions = self.sessions.read().await;
            let files = self.scrollback_files.read().await;
            sessions
                .iter()
                .filter(|(_, m)| {
                    matches!(m.status, SessionStatus::Running | SessionStatus::Waiting)
                })
                .filter_map(|(id, _)| files.get(id).cloned())
                .collect()
        };

        let all_secrets = new_secrets;
        tokio::spawn(async move {
            for handle in handles {
                if let Err(e) = re_redact_scrollback(handle, &all_secrets).await {
                    tracing::warn!(error = %e, "scrollback re-redaction failed");
                }
            }
        });
    }

    fn canonical_scrollback_path(&self, session_id: Uuid) -> PathBuf {
        self.data_dir
            .join("scrollback")
            .join(format!("{session_id}.log"))
    }

    pub async fn spawn_shell(
        &self,
        project_id: Uuid,
        name: impl Into<String>,
        cwd: impl Into<String>,
        command: impl Into<String>,
    ) -> Result<SessionMetadata, SessionError> {
        let session_id = Uuid::new_v4();
        let now = Utc::now();
        let cwd = cwd.into();
        let command = command.into();
        let command_for_meta = if command.trim().is_empty() {
            "zsh".to_string()
        } else {
            command.clone()
        };

        let scrollback_path = self.canonical_scrollback_path(session_id);

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

        // Atomically check the limit and reserve a slot under a single write lock.
        {
            let mut sessions = self.sessions.write().await;
            let active_count = sessions
                .values()
                .filter(|m| matches!(m.status, SessionStatus::Running | SessionStatus::Waiting))
                .count();
            if active_count >= self.max_sessions {
                return Err(SessionError::LimitReached(format!(
                    "maximum of {} sessions reached",
                    self.max_sessions
                )));
            }
            sessions.insert(session_id, meta.clone());
        }

        // Insert atomic state for lock-free heartbeat reads.
        self.atomic_states.write().await.insert(
            session_id,
            Arc::new(AtomicSessionState::new(
                meta.last_heartbeat.timestamp(),
                &meta.health,
            )),
        );

        // Perform I/O outside the lock. On failure, remove the reserved slot
        // and any partial state left by attach_tmux_client.
        if let Err(err) = self
            .finish_spawn(session_id, &cwd, &command, &scrollback_path)
            .await
        {
            self.sessions.write().await.remove(&session_id);
            self.atomic_states.write().await.remove(&session_id);
            self.inputs.write().await.remove(&session_id);
            self.scrollback_files.write().await.remove(&session_id);
            return Err(err);
        }

        if self.tx.send(SessionEvent::Spawned(meta)).is_err() {
            tracing::debug!("no active subscribers for session spawned event");
        }

        self.get(session_id)
            .await
            .ok_or_else(|| SessionError::NotFound(session_id.to_string()))
    }

    /// Performs the I/O-heavy portion of session spawn (file creation, tmux,
    /// attach). Separated so the caller can roll back the HashMap entry on
    /// failure.
    async fn finish_spawn(
        &self,
        session_id: Uuid,
        cwd: &str,
        command: &str,
        scrollback_path: &std::path::Path,
    ) -> Result<(), SessionError> {
        let scrollback_index_path = scrollback_path.with_extension("idx");
        if let Some(parent) = scrollback_path.parent() {
            tokio::fs::create_dir_all(parent).await?;
        }
        let _ = open_append_only_file(scrollback_path).await?;
        let _ = open_append_only_file(&scrollback_index_path).await?;

        self.create_tmux_session(session_id, cwd, command).await?;
        self.attach_tmux_client(session_id).await?;

        Ok(())
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

    pub async fn kill_session_backend(
        &self,
        session_id: Uuid,
    ) -> Result<SessionBackendKillResult, SessionError> {
        self.ensure_tmux_tmpdir().await?;
        let name = tmux_name(session_id);
        let out = self
            .tmux_command()
            .args(["kill-session", "-t", &name])
            .output()
            .await
            .map_err(|e| SessionError::SpawnFailed(e.to_string()))?;

        if out.status.success() {
            return Ok(SessionBackendKillResult::Killed);
        }

        let stderr = String::from_utf8_lossy(&out.stderr).to_string();
        if stderr.contains("can't find session") {
            return Ok(SessionBackendKillResult::AlreadyGone);
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

        let explicit_shell = explicit_shell_command(command);

        // Create the tmux session directly with an explicit shell path/name when requested.
        // Other commands still flow through send-keys below so they are not shell-expanded.
        let mut args = vec![
            "new-session".to_string(),
            "-d".to_string(),
            "-s".to_string(),
            name.clone(),
            "-c".to_string(),
            cwd.to_string(),
        ];
        if let Some(explicit_shell) = explicit_shell.as_ref() {
            args.push(explicit_shell.clone());
        }

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

        // Allow escape-sequence passthrough so protocols such as Kitty
        // graphics reach the outer terminal emulator (Ghostty) instead of
        // being swallowed by tmux.  `all` rather than `on` so that
        // passthrough works from any pane, not only the active one.
        match self
            .tmux_command()
            .args(["set", "-t", &name, "allow-passthrough", "all"])
            .output()
            .await
        {
            Ok(out) if !out.status.success() => {
                let stderr = String::from_utf8_lossy(&out.stderr);
                tracing::warn!(
                    session_id = %session_id,
                    "tmux set allow-passthrough failed: {}",
                    stderr.trim()
                );
            }
            Err(e) => {
                tracing::warn!(
                    session_id = %session_id,
                    "tmux set allow-passthrough failed: {e}"
                );
            }
            _ => {}
        }

        // Send non-shell commands as literal keystrokes to prevent shell injection.
        if !command.trim().is_empty() && explicit_shell.is_none() {
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

        if self
            .tx
            .send(SessionEvent::Heartbeat {
                session_id,
                health: SessionHealth::Active,
            })
            .is_err()
        {
            tracing::debug!("no active subscribers for session heartbeat event");
        }

        // Create a single shared scrollback file handle for both reader tasks
        // and re-redaction. One handle + one Mutex = mutual exclusion.
        let shared_scrollback = match open_scrollback_rw(&scrollback_path).await {
            Ok(f) => {
                let mut f = f;
                let _ = f.seek(std::io::SeekFrom::End(0)).await;
                let handle = Arc::new(Mutex::new(f));
                self.scrollback_files
                    .write()
                    .await
                    .insert(session_id, handle.clone());
                handle
            }
            Err(e) => {
                tracing::warn!(
                    error = %e,
                    %session_id,
                    "failed to open shared scrollback handle; re-redaction disabled for this session"
                );
                Arc::new(Mutex::new(
                    open_append_only_file(&scrollback_path).await.map_err(|e| {
                        SessionError::SpawnFailed(format!("scrollback open failed: {e}"))
                    })?,
                ))
            }
        };

        if let Some(stdout) = stdout {
            self.spawn_reader_task(
                session_id,
                stdout,
                shared_scrollback.clone(),
                scrollback_index_path.clone(),
                self.redaction_secrets.clone(),
            );
        }
        if let Some(stderr) = stderr {
            self.spawn_reader_task(
                session_id,
                stderr,
                shared_scrollback,
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
        file: Arc<Mutex<tokio::fs::File>>,
        scrollback_index_path: PathBuf,
        redaction_secrets: Arc<RwLock<Vec<String>>>,
    ) where
        R: AsyncRead + Send + Unpin + 'static,
    {
        let atomic_states = self.atomic_states.clone();
        let tx = self.tx.clone();

        tokio::spawn(async move {
            if let Some(parent) = scrollback_index_path.parent() {
                if tokio::fs::create_dir_all(parent).await.is_err() {
                    return;
                }
            }

            let index = open_append_only_file(scrollback_index_path.as_path()).await;
            let Ok(index) = index else {
                return;
            };
            let index = Arc::new(Mutex::new(index));
            // Get initial file size from the shared handle.
            let mut total = {
                let mut f = file.lock().await;
                f.seek(std::io::SeekFrom::End(0)).await.unwrap_or(0)
            };
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
                    let states = atomic_states.read().await;
                    if let Some(state) = states.get(&session_id) {
                        state
                            .last_heartbeat
                            .store(Utc::now().timestamp(), Ordering::Relaxed);
                        state
                            .health
                            .store(health_to_u8(&SessionHealth::Active), Ordering::Relaxed);
                    }
                }
                if tx
                    .send(SessionEvent::Heartbeat {
                        session_id,
                        health: SessionHealth::Active,
                    })
                    .is_err()
                {
                    tracing::debug!("no active subscribers for reader heartbeat event");
                }
                if let Some(chunk) = redactor.push_chunk(&raw_chunk).await {
                    let chunk_bytes = chunk.as_bytes();

                    {
                        let mut out = file.lock().await;
                        // Seek to end — not O_APPEND. Also re-syncs after re-redaction.
                        if let Ok(pos) = out.seek(std::io::SeekFrom::End(0)).await {
                            total = pos;
                        }
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

                    if tx.send(SessionEvent::Output { session_id, chunk }).is_err() {
                        tracing::debug!("no active subscribers for session output event");
                    }
                }
            }

            if let Some(chunk) = redactor.finish().await {
                let chunk_bytes = chunk.as_bytes();
                {
                    let mut out = file.lock().await;
                    // Seek to end — not O_APPEND. Also re-syncs after re-redaction.
                    if let Ok(pos) = out.seek(std::io::SeekFrom::End(0)).await {
                        total = pos;
                    }
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
                if tx.send(SessionEvent::Output { session_id, chunk }).is_err() {
                    tracing::debug!("no active subscribers for session output event");
                }
            }
        });
    }

    fn spawn_exit_task(&self, session_id: Uuid, mut child: Child) {
        let sessions = self.sessions.clone();
        let atomic_states = self.atomic_states.clone();
        let inputs = self.inputs.clone();
        let scrollback_files = self.scrollback_files.clone();
        let tx = self.tx.clone();
        let tmux_tmpdir = self.tmux_tmpdir.clone();
        let tmux_bin = self.tmux_bin.clone();

        tokio::spawn(async move {
            let code = child.wait().await.ok().and_then(|status| status.code());
            let tmux_alive =
                tmux_has_session_name(&tmux_name(session_id), &tmux_tmpdir, &tmux_bin).await;

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

            // Sync atomic state to match the transition applied above.
            {
                let states = atomic_states.read().await;
                if let Some(state) = states.get(&session_id) {
                    let now_ts = Utc::now().timestamp();
                    state.last_heartbeat.store(now_ts, Ordering::Release);
                    if tmux_alive {
                        state
                            .health
                            .store(health_to_u8(&SessionHealth::Waiting), Ordering::Release);
                    } else {
                        state
                            .health
                            .store(health_to_u8(&SessionHealth::Complete), Ordering::Release);
                    }
                }
            }

            inputs.write().await.remove(&session_id);
            scrollback_files.write().await.remove(&session_id);
            if tx.send(SessionEvent::Exited { session_id, code }).is_err() {
                tracing::debug!("no active subscribers for session exited event");
            }
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
        // Fast path: update atomics without taking the sessions write lock.
        let now = Utc::now();
        {
            let atomic_states = self.atomic_states.read().await;
            if let Some(state) = atomic_states.get(&session_id) {
                state
                    .last_heartbeat
                    .store(now.timestamp(), Ordering::Relaxed);
                state
                    .health
                    .store(health_to_u8(&SessionHealth::Active), Ordering::Relaxed);
            } else {
                return Err(SessionError::NotFound(session_id.to_string()));
            }
        }

        // Update the canonical metadata under write lock.
        let mut sessions = self.sessions.write().await;
        let Some(meta) = sessions.get_mut(&session_id) else {
            return Err(SessionError::NotFound(session_id.to_string()));
        };

        meta.last_heartbeat = now;
        meta.health = SessionHealth::Active;
        if meta.status != SessionStatus::Complete {
            meta.status = SessionStatus::Running;
        }
        if self
            .tx
            .send(SessionEvent::Heartbeat {
                session_id,
                health: SessionHealth::Active,
            })
            .is_err()
        {
            tracing::debug!("no active subscribers for session heartbeat event");
        }
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

    pub async fn register_restored(&self, mut meta: SessionMetadata) -> Result<(), SessionError> {
        meta.scrollback_path = self
            .canonical_scrollback_path(meta.id)
            .to_string_lossy()
            .to_string();

        // Enforce the same session limit as spawn_shell. Only active
        // (Running | Waiting) sessions count against the cap.
        let is_active = matches!(meta.status, SessionStatus::Running | SessionStatus::Waiting);
        {
            let mut sessions = self.sessions.write().await;
            if is_active {
                let active_count = sessions
                    .values()
                    .filter(|m| matches!(m.status, SessionStatus::Running | SessionStatus::Waiting))
                    .count();
                if active_count >= self.max_sessions {
                    return Err(SessionError::LimitReached(format!(
                        "maximum of {} sessions reached",
                        self.max_sessions
                    )));
                }
            }
            sessions.insert(meta.id, meta.clone());
        }

        self.atomic_states.write().await.insert(
            meta.id,
            Arc::new(AtomicSessionState::new(
                meta.last_heartbeat.timestamp(),
                &meta.health,
            )),
        );

        if self.tx.send(SessionEvent::Spawned(meta)).is_err() {
            tracing::debug!("no active subscribers for session spawned event");
        }
        Ok(())
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
            return Err(SessionError::ScrollbackTooLarge {
                size: total,
                max: MAX_SCROLLBACK_READ_BYTES,
            });
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
        let now_ts = now.timestamp();

        // First pass: read atomics to find candidate sessions whose health may
        // need a transition. This avoids taking the sessions write lock when
        // nothing changed.
        let candidates: Vec<Uuid> = {
            let atomic_states = self.atomic_states.read().await;
            let sessions = self.sessions.read().await;

            let mut ids = Vec::new();
            for (id, meta) in sessions.iter() {
                if meta.status != SessionStatus::Running {
                    continue;
                }

                let heartbeat_ts = atomic_states
                    .get(id)
                    .map(|s| s.last_heartbeat.load(Ordering::Relaxed))
                    .unwrap_or(meta.last_heartbeat.timestamp());

                let delta_secs = now_ts.saturating_sub(heartbeat_ts);
                let next = if delta_secs >= self.stuck_after.num_seconds() {
                    SessionHealth::Stuck
                } else if delta_secs >= self.idle_after.num_seconds() {
                    SessionHealth::Idle
                } else {
                    SessionHealth::Active
                };

                let current = atomic_states
                    .get(id)
                    .map(|s| u8_to_health(s.health.load(Ordering::Relaxed)))
                    .unwrap_or(meta.health.clone());

                if current != next {
                    ids.push(*id);
                }
            }
            ids
        };

        if candidates.is_empty() {
            return;
        }

        // Second pass: take write lock and re-read atomics before applying.
        // Between the two passes, a reader task or mark_activity may have
        // updated the heartbeat, making the earlier reading stale. Re-reading
        // under the write lock prevents incorrect transitions.
        let mut sessions = self.sessions.write().await;
        let atomic_states = self.atomic_states.read().await;
        let now_ts = Utc::now().timestamp(); // refresh to latest wall-clock
        for id in candidates {
            let Some(meta) = sessions.get_mut(&id) else {
                continue;
            };

            // Skip sessions that are no longer Running (may have exited
            // between the two passes).
            if meta.status != SessionStatus::Running {
                continue;
            }

            // Re-read the atomic heartbeat to get the freshest value.
            let heartbeat_ts = atomic_states
                .get(&id)
                .map(|s| s.last_heartbeat.load(Ordering::Acquire))
                .unwrap_or(meta.last_heartbeat.timestamp());

            let delta_secs = now_ts.saturating_sub(heartbeat_ts);
            let next = if delta_secs >= self.stuck_after.num_seconds() {
                SessionHealth::Stuck
            } else if delta_secs >= self.idle_after.num_seconds() {
                SessionHealth::Idle
            } else {
                SessionHealth::Active
            };

            // Re-read current health under the lock and skip if unchanged.
            let current = atomic_states
                .get(&id)
                .map(|s| u8_to_health(s.health.load(Ordering::Acquire)))
                .unwrap_or(meta.health.clone());

            if current == next {
                continue;
            }

            meta.health = next.clone();
            if let Some(state) = atomic_states.get(&id) {
                state.health.store(health_to_u8(&next), Ordering::Release);
            }
            if self
                .tx
                .send(SessionEvent::Heartbeat {
                    session_id: id,
                    health: next,
                })
                .is_err()
            {
                tracing::debug!("no active subscribers for session health change event");
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
        self.atomic_states.write().await.remove(&session_id);
        self.inputs.write().await.remove(&session_id);
        self.scrollback_files.write().await.remove(&session_id);
        if self
            .tx
            .send(SessionEvent::Exited { session_id, code })
            .is_err()
        {
            tracing::debug!("no active subscribers for session exited event");
        }
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
        cmd.env("PATH", gui_safe_path());
        cmd
    }

    fn script_command(&self) -> Command {
        let mut cmd = Command::new(&self.script_bin);
        cmd.env("TMUX_TMPDIR", &self.tmux_tmpdir);
        cmd.env("PATH", gui_safe_path());
        if let Some(term) = fallback_script_term(std::env::var_os("TERM")) {
            cmd.env("TERM", term);
        }
        cmd
    }

    async fn ensure_tmux_tmpdir(&self) -> Result<(), SessionError> {
        tokio::fs::create_dir_all(&self.tmux_tmpdir).await?;
        Ok(())
    }

    async fn tmux_has_session(&self, name: &str) -> bool {
        tmux_has_session_name(name, &self.tmux_tmpdir, &self.tmux_bin).await
    }

    /// Spawn a background task that periodically checks whether tmux sessions
    /// are still alive. If a session is marked Running but tmux reports it
    /// gone, mark it as Error and emit an Exited event.
    pub fn spawn_health_probe(&self, mut shutdown: tokio::sync::watch::Receiver<bool>) {
        let sessions = self.sessions.clone();
        let tx = self.tx.clone();
        let tmux_tmpdir = self.tmux_tmpdir.clone();
        let tmux_bin = self.tmux_bin.clone();

        tokio::spawn(async move {
            let mut interval = tokio::time::interval(std::time::Duration::from_secs(30));
            loop {
                tokio::select! {
                    _ = interval.tick() => {
                        let snapshot: Vec<(Uuid, String)> = {
                            let guard = sessions.read().await;
                            guard.iter()
                                .filter(|(_, m)| m.status == SessionStatus::Running)
                                .map(|(id, _)| (*id, tmux_name(*id)))
                                .collect()
                        };
                        for (id, name) in snapshot {
                            if !tmux_has_session_name(&name, &tmux_tmpdir, &tmux_bin).await {
                                tracing::warn!(
                                    session_id = %id,
                                    tmux_name = %name,
                                    "tmux session lost — marking dead"
                                );
                                {
                                    let mut guard = sessions.write().await;
                                    if let Some(meta) = guard.get_mut(&id) {
                                        if meta.status == SessionStatus::Running {
                                            meta.status = SessionStatus::Error;
                                        }
                                    }
                                }
                                let _ = tx.send(SessionEvent::Exited {
                                    session_id: id,
                                    code: None,
                                });
                            }
                        }
                    }
                    _ = shutdown.changed() => {
                        break;
                    }
                }
            }
        });
    }
}

fn tmux_name(session_id: Uuid) -> String {
    format!("pnevma_{}", session_id.simple())
}

/// Build a PATH that includes Homebrew and other common directories.
/// GUI apps launched from Finder inherit a minimal PATH that lacks
/// `/opt/homebrew/bin` and similar locations.  The tmux server inherits
/// its environment at first launch, so every child shell would also
/// miss these paths unless we inject them here.
fn gui_safe_path() -> String {
    let extra = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"];
    let current = std::env::var("PATH").unwrap_or_default();
    let mut parts: Vec<&str> = extra
        .iter()
        .copied()
        .filter(|dir| !current.split(':').any(|p| p == *dir))
        .collect();
    if !current.is_empty() {
        parts.push(&current);
    }
    parts.join(":")
}

fn explicit_shell_command(command: &str) -> Option<String> {
    let trimmed = command.trim();
    if trimmed.is_empty() || trimmed.split_whitespace().count() != 1 {
        return None;
    }

    let shell_name = std::path::Path::new(trimmed)
        .file_name()
        .and_then(|name| name.to_str())?;

    ["zsh", "bash", "sh", "fish"]
        .contains(&shell_name)
        .then(|| trimmed.to_string())
}

fn fallback_script_term(term: Option<std::ffi::OsString>) -> Option<&'static str> {
    match term.as_ref().and_then(|term| term.to_str()) {
        Some(term) if !term.is_empty() && term != "dumb" && term != "unknown" => None,
        _ => Some("xterm-256color"),
    }
}

async fn tmux_has_session_name(name: &str, tmux_tmpdir: &Path, tmux_bin: &Path) -> bool {
    let _ = tokio::fs::create_dir_all(tmux_tmpdir).await;

    Command::new(tmux_bin)
        .env("TMUX_TMPDIR", tmux_tmpdir)
        .args(["has-session", "-t", name])
        .status()
        .await
        .map(|status| status.success())
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::explicit_shell_command;
    use super::fallback_script_term;
    use super::redact_stream_chunk;
    use super::SessionBackendKillResult;
    use super::SessionSupervisor;
    use super::StreamRedactor;
    use crate::error::SessionError;
    use crate::model::{SessionHealth, SessionMetadata, SessionStatus};
    use chrono::Utc;
    use std::os::unix::fs::PermissionsExt;
    use std::path::{Path, PathBuf};
    use std::sync::Arc;
    use tokio::io::AsyncWriteExt;
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
        let missing_path = root.join("off-root").join("ignored.log");
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
            .await
            .expect("register_restored");

        let err = supervisor
            .read_scrollback(session_id, 0, 128)
            .await
            .expect_err("missing scrollback file should error");
        assert!(matches!(err, SessionError::Io(_)));
    }

    #[tokio::test]
    async fn register_restored_ignores_caller_supplied_scrollback_path() {
        let root = std::env::temp_dir().join(format!("pnevma-session-test-{}", Uuid::new_v4()));
        let supervisor = SessionSupervisor::new(&root);
        let session_id = Uuid::new_v4();
        let now = Utc::now();
        let canonical_path = supervisor.canonical_scrollback_path(session_id);
        let attacker_path = root.join("..").join(format!("{session_id}-attacker.log"));

        tokio::fs::create_dir_all(canonical_path.parent().expect("scrollback parent"))
            .await
            .expect("create canonical scrollback dir");
        tokio::fs::write(&canonical_path, b"canonical output")
            .await
            .expect("write canonical scrollback");
        tokio::fs::write(&attacker_path, b"attacker output")
            .await
            .expect("write attacker scrollback");

        let _ = supervisor
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
                scrollback_path: attacker_path.to_string_lossy().to_string(),
                exit_code: None,
                ended_at: None,
            })
            .await;

        let meta = supervisor.get(session_id).await.expect("restored session");
        assert_eq!(
            PathBuf::from(meta.scrollback_path),
            canonical_path,
            "restored sessions must store the canonical scrollback path"
        );

        let slice = supervisor
            .read_scrollback(session_id, 0, 128)
            .await
            .expect("canonical scrollback should be readable");
        assert_eq!(slice.data, "canonical output");
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

        let _ = supervisor
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

        let _ = supervisor
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

        let _ = supervisor
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

        let _ = supervisor
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

        let _ = supervisor
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
            .await
            .expect("register_restored");
        session_id
    }

    fn write_fake_tmux(root: &Path, body: &str) -> std::path::PathBuf {
        std::fs::create_dir_all(root).expect("create fake tmux root");
        let path = root.join("fake-tmux.sh");
        std::fs::write(&path, format!("#!/bin/sh\n{body}\n")).expect("write fake tmux");
        let mut permissions = std::fs::metadata(&path)
            .expect("fake tmux metadata")
            .permissions();
        permissions.set_mode(0o755);
        std::fs::set_permissions(&path, permissions).expect("set fake tmux permissions");
        path
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
        let _ = supervisor
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

    #[tokio::test]
    async fn kill_session_backend_returns_killed_for_successful_tmux_exit() {
        let root = std::env::temp_dir().join(format!("pnevma-session-test-{}", Uuid::new_v4()));
        let mut supervisor = SessionSupervisor::new(&root);
        supervisor.tmux_bin = write_fake_tmux(&root, "exit 0");

        let result = supervisor
            .kill_session_backend(Uuid::new_v4())
            .await
            .expect("successful tmux exit should report killed");
        assert_eq!(result, SessionBackendKillResult::Killed);
    }

    #[tokio::test]
    async fn kill_session_backend_returns_already_gone_for_missing_tmux_session() {
        let root = std::env::temp_dir().join(format!("pnevma-session-test-{}", Uuid::new_v4()));
        let mut supervisor = SessionSupervisor::new(&root);
        supervisor.tmux_bin = write_fake_tmux(&root, "echo \"can't find session\" 1>&2\nexit 1");

        let result = supervisor
            .kill_session_backend(Uuid::new_v4())
            .await
            .expect("missing tmux session should classify as already gone");
        assert_eq!(result, SessionBackendKillResult::AlreadyGone);
    }

    #[tokio::test]
    async fn kill_session_backend_returns_error_for_real_tmux_failure() {
        let root = std::env::temp_dir().join(format!("pnevma-session-test-{}", Uuid::new_v4()));
        let mut supervisor = SessionSupervisor::new(&root);
        supervisor.tmux_bin = write_fake_tmux(&root, "echo \"permission denied\" 1>&2\nexit 1");

        let err = supervisor
            .kill_session_backend(Uuid::new_v4())
            .await
            .expect_err("hard tmux failure should bubble as an error");
        assert!(matches!(err, SessionError::SpawnFailed(_)));
    }

    // ── mark_exit ───────────────────────────────────────────────────────────

    #[tokio::test]
    async fn mark_exit_transitions_session_to_complete() {
        let root = std::env::temp_dir().join(format!("pnevma-session-test-{}", Uuid::new_v4()));
        let supervisor = SessionSupervisor::new(&root);
        let session_id = Uuid::new_v4();
        let scrollback = root.join("scrollback").join(format!("{session_id}.log"));

        let _ = supervisor
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
    fn redacts_provider_token_and_env_assignment() {
        let input = r#"OPENAI_API_KEY="sk-proj-abcdefghijklmnopqrstuvwxyz1234567890""#;
        let output = redact_stream_chunk(input);
        assert_eq!(output, "OPENAI_API_KEY=[REDACTED]");
        assert!(!output.contains("sk-proj-"));
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

    #[tokio::test]
    async fn spawn_reader_task_persists_provider_tokens_redacted() {
        let root = std::env::temp_dir().join(format!("pnevma-session-test-{}", Uuid::new_v4()));
        let supervisor = SessionSupervisor::new(&root);
        let session_id = Uuid::new_v4();
        let now = Utc::now();
        let scrollback_path = root.join("scrollback").join(format!("{session_id}.log"));
        let scrollback_index_path = scrollback_path.with_extension("idx");

        let _ = supervisor
            .register_restored(SessionMetadata {
                id: session_id,
                project_id: Uuid::new_v4(),
                name: "persist-redacted".to_string(),
                status: SessionStatus::Running,
                health: SessionHealth::Active,
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

        tokio::fs::create_dir_all(scrollback_path.parent().unwrap())
            .await
            .expect("create scrollback dir");
        let shared_file = {
            let f = super::open_scrollback_rw(&scrollback_path)
                .await
                .expect("open scrollback rw");
            Arc::new(tokio::sync::Mutex::new(f))
        };

        let (mut writer, reader) = tokio::io::duplex(512);
        supervisor.spawn_reader_task(
            session_id,
            reader,
            shared_file,
            scrollback_index_path,
            Arc::new(RwLock::new(Vec::new())),
        );

        writer
            .write_all(b"prefix sk-pr")
            .await
            .expect("write first chunk");
        writer
            .write_all(b"oj-abcdefghijklmnopqrstuvwxyz1234567890 suffix")
            .await
            .expect("write second chunk");
        writer.shutdown().await.expect("shutdown writer");
        drop(writer);

        let persisted = tokio::time::timeout(std::time::Duration::from_secs(2), async {
            loop {
                if let Ok(contents) = tokio::fs::read_to_string(&scrollback_path).await {
                    if !contents.is_empty() {
                        break contents;
                    }
                }
                tokio::time::sleep(std::time::Duration::from_millis(20)).await;
            }
        })
        .await
        .expect("persisted redacted scrollback");

        assert_eq!(persisted, "prefix [REDACTED] suffix");
        assert!(!persisted.contains("sk-proj-"));

        let slice = supervisor
            .read_scrollback(session_id, 0, 4096)
            .await
            .expect("read scrollback");
        assert_eq!(slice.data, persisted);
        assert!(!slice.data.contains("sk-proj-"));
    }

    #[test]
    fn explicit_shell_command_detects_supported_shell_paths_and_names() {
        assert_eq!(explicit_shell_command("bash"), Some("bash".to_string()));
        assert_eq!(
            explicit_shell_command("/bin/zsh"),
            Some("/bin/zsh".to_string())
        );
        assert_eq!(explicit_shell_command("cargo test"), None);
        assert_eq!(explicit_shell_command("/bin/bash -l"), None);
        assert_eq!(explicit_shell_command(""), None);
    }

    #[test]
    fn fallback_script_term_only_overrides_missing_or_unusable_values() {
        assert_eq!(fallback_script_term(None), Some("xterm-256color"));
        assert_eq!(
            fallback_script_term(Some(std::ffi::OsString::from(""))),
            Some("xterm-256color")
        );
        assert_eq!(
            fallback_script_term(Some(std::ffi::OsString::from("dumb"))),
            Some("xterm-256color")
        );
        assert_eq!(
            fallback_script_term(Some(std::ffi::OsString::from("unknown"))),
            Some("xterm-256color")
        );
        assert_eq!(
            fallback_script_term(Some(std::ffi::OsString::from("xterm-256color"))),
            None
        );
    }

    // ── list/get ─────────────────────────────────────────────────────────────

    #[tokio::test]
    async fn list_returns_all_registered_sessions() {
        let root = std::env::temp_dir().join(format!("pnevma-session-test-{}", Uuid::new_v4()));
        let supervisor = SessionSupervisor::new(&root);

        for i in 0..3 {
            let id = Uuid::new_v4();
            let scrollback = root.join("scrollback").join(format!("{id}.log"));
            let _ = supervisor
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

    // ── Session limit ───────────────────────────────────────────────────────

    #[tokio::test]
    async fn session_limit_ignores_completed_and_errored_sessions() {
        let root = std::env::temp_dir().join(format!("pnevma-session-test-{}", Uuid::new_v4()));
        let mut supervisor = SessionSupervisor::new(&root);
        supervisor.max_sessions = 2;

        let now = Utc::now();
        let project_id = Uuid::new_v4();

        // Register a Complete and an Error session — should not count against limit
        for status in [SessionStatus::Complete, SessionStatus::Error] {
            let id = Uuid::new_v4();
            let scrollback = root.join("scrollback").join(format!("{id}.log"));
            let _ = supervisor
                .register_restored(SessionMetadata {
                    id,
                    project_id,
                    name: format!("{status:?}"),
                    status,
                    health: SessionHealth::Complete,
                    pid: None,
                    cwd: ".".to_string(),
                    command: "zsh".to_string(),
                    branch: None,
                    worktree_id: None,
                    started_at: now,
                    last_heartbeat: now,
                    scrollback_path: scrollback.to_string_lossy().to_string(),
                    exit_code: Some(0),
                    ended_at: Some(now),
                })
                .await;
        }

        // Register 2 Waiting sessions — these fill the limit
        for i in 0..2 {
            let id = Uuid::new_v4();
            let scrollback = root.join("scrollback").join(format!("{id}.log"));
            let _ = supervisor
                .register_restored(SessionMetadata {
                    id,
                    project_id,
                    name: format!("waiting-{i}"),
                    status: SessionStatus::Waiting,
                    health: SessionHealth::Waiting,
                    pid: None,
                    cwd: ".".to_string(),
                    command: "zsh".to_string(),
                    branch: None,
                    worktree_id: None,
                    started_at: now,
                    last_heartbeat: now,
                    scrollback_path: scrollback.to_string_lossy().to_string(),
                    exit_code: None,
                    ended_at: None,
                })
                .await;
        }

        // 4 sessions in the HashMap, but only 2 active — limit is 2, so next spawn should fail
        assert_eq!(supervisor.list().await.len(), 4);

        let err = supervisor
            .spawn_shell(project_id, "over-limit", ".", "")
            .await
            .expect_err("should hit session limit");
        assert!(matches!(err, SessionError::LimitReached(_)));
    }

    #[tokio::test]
    async fn spawn_failure_rolls_back_reserved_slot() {
        let root = std::env::temp_dir().join(format!("pnevma-session-test-{}", Uuid::new_v4()));
        let mut supervisor = SessionSupervisor::new(&root);
        // Use a tmux binary that always fails so create_tmux_session errors out.
        supervisor.tmux_bin = write_fake_tmux(&root, "echo 'fail' >&2\nexit 1");
        supervisor.max_sessions = 1;

        let project_id = Uuid::new_v4();
        let _err = supervisor
            .spawn_shell(project_id, "will-fail", ".", "")
            .await
            .expect_err("spawn should fail with bad tmux");

        // The reserved slot must have been removed — HashMap should be empty.
        assert_eq!(supervisor.list().await.len(), 0);

        // A subsequent spawn attempt should not hit LimitReached.
        let err = supervisor
            .spawn_shell(project_id, "retry", ".", "")
            .await
            .expect_err("still fails because tmux is fake");
        assert!(
            !matches!(err, SessionError::LimitReached(_)),
            "slot was freed, should not be LimitReached"
        );
    }

    #[tokio::test]
    async fn re_redact_scrollback_replaces_secrets() {
        use super::re_redact_scrollback;
        use tokio::io::{AsyncReadExt, AsyncSeekExt};
        use tokio::sync::Mutex;

        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("test.log");
        tokio::fs::write(&path, "hello API_KEY=mysecretkey123 world")
            .await
            .unwrap();

        let file: tokio::fs::File = tokio::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(&path)
            .await
            .unwrap();
        let handle = Arc::new(Mutex::new(file));

        let secrets = vec!["mysecretkey123".to_string()];
        re_redact_scrollback(handle.clone(), &secrets)
            .await
            .expect("re-redaction should succeed");

        let mut f = handle.lock().await;
        f.seek(std::io::SeekFrom::Start(0)).await.unwrap();
        let mut content = String::new();
        f.read_to_string(&mut content).await.unwrap();

        assert!(
            !content.contains("mysecretkey123"),
            "secret should be redacted"
        );
        assert!(content.contains("[REDACTED]"), "redaction marker expected");
    }

    #[tokio::test]
    async fn re_redact_scrollback_skips_when_unchanged() {
        use super::re_redact_scrollback;
        use tokio::sync::Mutex;

        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("clean.log");
        tokio::fs::write(&path, "nothing secret here")
            .await
            .unwrap();

        let file: tokio::fs::File = tokio::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(&path)
            .await
            .unwrap();
        let handle = Arc::new(Mutex::new(file));

        re_redact_scrollback(handle, &["unrelated".to_string()])
            .await
            .expect("should succeed");

        let content: String = tokio::fs::read_to_string(&path).await.unwrap();
        assert_eq!(content, "nothing secret here");
    }
}
