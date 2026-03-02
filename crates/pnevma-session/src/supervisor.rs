use crate::error::SessionError;
use crate::model::{SessionHealth, SessionMetadata, SessionStatus};
use chrono::{Duration, Utc};
use regex::Regex;
use std::collections::HashMap;
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

fn redact_stream_chunk(input: &str) -> String {
    let first = redaction_authorization_regex()
        .replace_all(input, "$1[REDACTED]")
        .to_string();
    redaction_key_value_regex()
        .replace_all(&first, "$1=[REDACTED]")
        .to_string()
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

#[derive(Debug, Clone)]
pub struct SessionSupervisor {
    sessions: Arc<RwLock<HashMap<Uuid, SessionMetadata>>>,
    inputs: Arc<RwLock<HashMap<Uuid, Arc<Mutex<ChildStdin>>>>>,
    tx: broadcast::Sender<SessionEvent>,
    idle_after: Duration,
    stuck_after: Duration,
    data_dir: PathBuf,
    tmux_tmpdir: PathBuf,
}

impl SessionSupervisor {
    pub fn new(data_dir: impl AsRef<Path>) -> Self {
        let data_dir = data_dir.as_ref().to_path_buf();
        let (tx, _) = broadcast::channel(512);
        Self {
            sessions: Arc::new(RwLock::new(HashMap::new())),
            inputs: Arc::new(RwLock::new(HashMap::new())),
            tx,
            idle_after: Duration::minutes(2),
            stuck_after: Duration::minutes(10),
            tmux_tmpdir: data_dir.join("tmux"),
            data_dir,
        }
    }

    pub fn subscribe(&self) -> broadcast::Receiver<SessionEvent> {
        self.tx.subscribe()
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

        let mut args = vec![
            "new-session".to_string(),
            "-d".to_string(),
            "-s".to_string(),
            name,
            "-c".to_string(),
            cwd.to_string(),
        ];
        if !command.trim().is_empty() {
            args.push(command.to_string());
        }

        let out = self
            .tmux_command()
            .args(args)
            .output()
            .await
            .map_err(|e| SessionError::SpawnFailed(e.to_string()))?;

        if out.status.success() {
            return Ok(());
        }

        let stderr = String::from_utf8_lossy(&out.stderr).to_string();
        Err(SessionError::SpawnFailed(format!(
            "tmux new-session failed: {}",
            stderr.trim()
        )))
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

        let mut child = self
            .script_command()
            .args([
                "-q",
                "/dev/null",
                "tmux",
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
            );
        }
        if let Some(stderr) = stderr {
            self.spawn_reader_task(
                session_id,
                stderr,
                scrollback_path.clone(),
                scrollback_index_path.clone(),
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

            let mut buf = [0u8; 4096];
            loop {
                let read = match reader.read(&mut buf).await {
                    Ok(0) => break,
                    Ok(n) => n,
                    Err(_) => break,
                };
                let raw_chunk = String::from_utf8_lossy(&buf[..read]).to_string();
                let chunk = redact_stream_chunk(&raw_chunk);
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
        let meta = self
            .sessions
            .read()
            .await
            .get(&session_id)
            .cloned()
            .ok_or_else(|| SessionError::NotFound(session_id.to_string()))?;

        let mut file = tokio::fs::OpenOptions::new()
            .read(true)
            .open(meta.scrollback_path)
            .await?;
        let total = file.metadata().await?.len();
        let start = offset.min(total);
        file.seek(std::io::SeekFrom::Start(start)).await?;
        let mut buf = vec![0u8; limit];
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
        let mut cmd = Command::new("tmux");
        cmd.env("TMUX_TMPDIR", &self.tmux_tmpdir);
        cmd
    }

    fn script_command(&self) -> Command {
        let mut cmd = Command::new("script");
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

    Command::new("tmux")
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
    use crate::error::SessionError;
    use crate::model::{SessionHealth, SessionMetadata, SessionStatus};
    use chrono::Utc;
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
}
