use std::env;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::fs::{FileTypeExt, PermissionsExt};
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
use std::thread;
use std::time::{Duration, UNIX_EPOCH};
use thiserror::Error;
use uuid::Uuid;

const PROTOCOL_VERSION: &str = "1";
const HELPER_KIND: &str = "binary";
const DEFAULT_ATTACH_TAIL_BYTES: u64 = 16_384;
const DEFAULT_SHELL_COMMAND: &str = "${SHELL:-/bin/sh} -il";
const CONTROLLER_ID_FILENAME: &str = "controller-id";
const INSTALL_METADATA_EXTENSION: &str = "metadata";
const HELPER_DEPENDENCIES: &[&str] = &["sh", "mkfifo", "nohup", "kill"];
const FIFO_POLL_INTERVAL: Duration = Duration::from_millis(50);

#[derive(Debug, Error)]
pub enum HelperError {
    #[error("io error: {0}")]
    Io(#[from] io::Error),
    #[error("invalid arguments: {0}")]
    InvalidArgs(String),
    #[error("command failed: {0}")]
    CommandFailed(String),
    #[error("environment error: {0}")]
    Environment(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HelperPaths {
    pub helper_path: PathBuf,
    pub state_root: PathBuf,
    pub sessions_root: PathBuf,
    pub controller_root: PathBuf,
}

impl HelperPaths {
    pub fn from_env() -> Result<Self, HelperError> {
        let helper_path = env::var_os("PNEVMA_REMOTE_HELPER_PATH")
            .map(PathBuf::from)
            .unwrap_or(env::current_exe()?);
        let state_root = env::var_os("PNEVMA_REMOTE_HELPER_STATE_ROOT")
            .map(PathBuf::from)
            .or_else(default_state_root)
            .ok_or_else(|| HelperError::Environment("HOME is not set".to_string()))?;
        Ok(Self::new(helper_path, state_root))
    }

    pub fn new(helper_path: PathBuf, state_root: PathBuf) -> Self {
        let sessions_root = state_root.join("sessions");
        let controller_root = state_root.join("controller");
        Self {
            helper_path,
            state_root,
            sessions_root,
            controller_root,
        }
    }

    fn ensure_layout(&self) -> Result<(), HelperError> {
        ensure_dir(&self.state_root)?;
        ensure_dir(&self.sessions_root)?;
        ensure_dir(&self.controller_root)?;
        Ok(())
    }

    fn controller_id_path(&self) -> PathBuf {
        self.controller_root.join(CONTROLLER_ID_FILENAME)
    }

    fn install_metadata_path(&self) -> PathBuf {
        self.helper_path.with_extension(INSTALL_METADATA_EXTENSION)
    }

    fn session_dir(&self, session_id: &str) -> PathBuf {
        self.sessions_root.join(session_id)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
struct InstallMetadata {
    target_triple: Option<String>,
    artifact_source: Option<String>,
    artifact_sha256: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HelperHealth {
    pub version: String,
    pub protocol_version: String,
    pub helper_kind: String,
    pub helper_path: String,
    pub state_root: String,
    pub controller_id: String,
    pub healthy: bool,
    pub target_triple: Option<String>,
    pub artifact_source: Option<String>,
    pub artifact_sha256: Option<String>,
    pub missing_dependencies: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionCreateResult {
    pub session_id: String,
    pub controller_id: String,
    pub state: String,
    pub pid: Option<u32>,
    pub log_path: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionStatusResult {
    pub session_id: String,
    pub controller_id: String,
    pub state: String,
    pub pid: Option<u32>,
    pub exit_code: Option<i32>,
    pub total_bytes: u64,
    pub last_output_at_epoch: Option<i64>,
}

pub fn run_cli<I, S>(args: I) -> Result<(), HelperError>
where
    I: IntoIterator<Item = S>,
    S: Into<String>,
{
    let mut args = args.into_iter().map(Into::into);
    let _program = args.next();
    let Some(command) = args.next() else {
        return Err(HelperError::InvalidArgs(
            "missing command (expected version, health, controller, or session)".to_string(),
        ));
    };
    let runtime = HelperRuntime::new(HelperPaths::from_env()?);
    let rest = args.collect::<Vec<_>>();
    runtime.run_command(&command, &rest)
}

#[derive(Debug, Clone)]
pub struct HelperRuntime {
    paths: HelperPaths,
}

impl HelperRuntime {
    pub fn new(paths: HelperPaths) -> Self {
        Self { paths }
    }

    pub fn health(&self) -> Result<HelperHealth, HelperError> {
        let controller_id = self.ensure_controller_id(None)?;
        let install_metadata = read_install_metadata(&self.paths.install_metadata_path())?;
        let missing_dependencies = missing_dependencies();
        Ok(HelperHealth {
            version: helper_version(),
            protocol_version: PROTOCOL_VERSION.to_string(),
            helper_kind: HELPER_KIND.to_string(),
            helper_path: self.paths.helper_path.display().to_string(),
            state_root: self.paths.state_root.display().to_string(),
            controller_id,
            healthy: missing_dependencies.is_empty(),
            target_triple: install_metadata.target_triple,
            artifact_source: install_metadata.artifact_source,
            artifact_sha256: install_metadata.artifact_sha256,
            missing_dependencies,
        })
    }

    pub fn ensure_controller_id(&self, requested: Option<&str>) -> Result<String, HelperError> {
        self.paths.ensure_layout()?;
        let path = self.paths.controller_id_path();
        if let Some(existing) = read_trimmed_string(&path)? {
            if !existing.is_empty() {
                return Ok(existing);
            }
        }
        let controller_id = requested
            .filter(|value| !value.trim().is_empty())
            .map(ToOwned::to_owned)
            .unwrap_or_else(|| Uuid::new_v4().to_string());
        write_private_file(&path, controller_id.as_bytes())?;
        Ok(controller_id)
    }

    pub fn create_session(
        &self,
        session_id: &str,
        cwd: &str,
        command: Option<&str>,
    ) -> Result<SessionCreateResult, HelperError> {
        if session_id.trim().is_empty() {
            return Err(HelperError::InvalidArgs("missing --session-id".to_string()));
        }
        if cwd.trim().is_empty() {
            return Err(HelperError::InvalidArgs("missing --cwd".to_string()));
        }

        let controller_id = self.ensure_controller_id(None)?;
        let session_dir = self.paths.session_dir(session_id);
        ensure_dir(&session_dir)?;

        let fifo_path = session_dir.join("input.fifo");
        let log_path = session_dir.join("output.log");
        let launch_path = session_dir.join("launch.sh");
        let runner_pid_path = session_dir.join("runner.pid");
        let child_pid_path = session_dir.join("child.pid");
        let keepalive_pid_path = session_dir.join("keepalive.pid");
        let exit_code_path = session_dir.join("exit_code");
        let attach_marker_path = session_dir.join("attached.lock");
        let attach_pid_path = session_dir.join("attach.pid");

        ensure_fifo(&fifo_path)?;
        touch_file(&log_path)?;
        write_launch_script(&launch_path, cwd, command.unwrap_or(DEFAULT_SHELL_COMMAND))?;

        cleanup_dead_pid_file(&runner_pid_path)?;
        cleanup_dead_pid_file(&keepalive_pid_path)?;

        if let Some(runner_pid) = read_pid_file(&runner_pid_path)? {
            if pid_alive(runner_pid) {
                let state = if attach_marker_path.exists() {
                    "attached"
                } else {
                    "detached"
                };
                return Ok(SessionCreateResult {
                    session_id: session_id.to_string(),
                    controller_id,
                    state: state.to_string(),
                    pid: Some(runner_pid),
                    log_path: Some(log_path.display().to_string()),
                });
            }
        }

        remove_if_exists(&exit_code_path)?;
        remove_if_exists(&attach_marker_path)?;
        remove_if_exists(&attach_pid_path)?;
        remove_if_exists(&child_pid_path)?;

        let runner_command = format!(
            "exec {} session-runner --session-id {}",
            shell_quote(&self.paths.helper_path.display().to_string()),
            shell_quote(session_id),
        );
        let runner_pid = spawn_detached_shell(&runner_command)?;
        write_private_file(&runner_pid_path, format!("{runner_pid}\n").as_bytes())?;
        remove_if_exists(&keepalive_pid_path)?;

        Ok(SessionCreateResult {
            session_id: session_id.to_string(),
            controller_id,
            state: "detached".to_string(),
            pid: Some(runner_pid),
            log_path: Some(log_path.display().to_string()),
        })
    }

    pub fn session_status(&self, session_id: &str) -> Result<SessionStatusResult, HelperError> {
        if session_id.trim().is_empty() {
            return Err(HelperError::InvalidArgs("missing --session-id".to_string()));
        }

        let controller_id = self.ensure_controller_id(None)?;
        let session_dir = self.paths.session_dir(session_id);
        if !session_dir.is_dir() {
            return Ok(SessionStatusResult {
                session_id: session_id.to_string(),
                controller_id,
                state: "lost".to_string(),
                pid: None,
                exit_code: None,
                total_bytes: 0,
                last_output_at_epoch: None,
            });
        }

        let runner_pid_path = session_dir.join("runner.pid");
        let keepalive_pid_path = session_dir.join("keepalive.pid");
        let log_path = session_dir.join("output.log");
        let exit_code_path = session_dir.join("exit_code");
        let attach_marker_path = session_dir.join("attached.lock");
        let attach_pid_path = session_dir.join("attach.pid");

        cleanup_dead_pid_file(&runner_pid_path)?;
        cleanup_dead_pid_file(&keepalive_pid_path)?;
        cleanup_dead_pid_file(&attach_pid_path)?;

        let attach_active = read_pid_file(&attach_pid_path)?
            .filter(|pid| pid_alive(*pid))
            .is_some();
        if !attach_active {
            let _ = remove_if_exists(&attach_marker_path);
        }

        let runner_pid = read_pid_file(&runner_pid_path)?;
        let state = if let Some(pid) = runner_pid {
            if pid_alive(pid) {
                if attach_active {
                    "attached"
                } else {
                    "detached"
                }
            } else if exit_code_path.exists() {
                "exited"
            } else {
                "lost"
            }
        } else if exit_code_path.exists() {
            "exited"
        } else {
            "lost"
        };

        Ok(SessionStatusResult {
            session_id: session_id.to_string(),
            controller_id,
            state: state.to_string(),
            pid: runner_pid,
            exit_code: read_trimmed_string(&exit_code_path)?
                .and_then(|value| value.parse::<i32>().ok()),
            total_bytes: file_len(&log_path)?,
            last_output_at_epoch: file_mtime_epoch(&log_path)?,
        })
    }

    pub fn signal_session(&self, session_id: &str, signal: &str) -> Result<(), HelperError> {
        if session_id.trim().is_empty() {
            return Err(HelperError::InvalidArgs("missing --session-id".to_string()));
        }
        let session_dir = self.paths.session_dir(session_id);
        let fifo_path = session_dir.join("input.fifo");
        let runner_pid_path = session_dir.join("runner.pid");
        let child_pid_path = session_dir.join("child.pid");
        let runner_pid = read_pid_file(&runner_pid_path)?
            .filter(|pid| pid_alive(*pid))
            .ok_or_else(|| HelperError::CommandFailed("session is not running".to_string()))?;

        match signal {
            "INT" => {
                let mut fifo = OpenOptions::new().write(true).open(&fifo_path)?;
                fifo.write_all(&[3])?;
            }
            "TERM" => {
                if let Some(child_pid) =
                    read_pid_file(&child_pid_path)?.filter(|pid| pid_alive(*pid))
                {
                    kill_process_group("-TERM", child_pid)?;
                } else {
                    kill_pid("-TERM", runner_pid)?;
                }
            }
            "KILL" => {
                if let Some(child_pid) =
                    read_pid_file(&child_pid_path)?.filter(|pid| pid_alive(*pid))
                {
                    kill_process_group("-KILL", child_pid)?;
                } else {
                    kill_pid("-KILL", runner_pid)?;
                }
            }
            other => {
                return Err(HelperError::InvalidArgs(format!(
                    "unsupported signal: {other}"
                )));
            }
        }
        Ok(())
    }

    pub fn terminate_session(&self, session_id: &str) -> Result<(), HelperError> {
        if session_id.trim().is_empty() {
            return Err(HelperError::InvalidArgs("missing --session-id".to_string()));
        }
        let session_dir = self.paths.session_dir(session_id);
        let runner_pid_path = session_dir.join("runner.pid");
        let child_pid_path = session_dir.join("child.pid");
        let keepalive_pid_path = session_dir.join("keepalive.pid");
        let attach_marker_path = session_dir.join("attached.lock");
        let attach_pid_path = session_dir.join("attach.pid");
        let child_pid = read_pid_file(&child_pid_path)?.filter(|pid| pid_alive(*pid));

        if let Some(child_pid) = child_pid {
            kill_process_group("-TERM", child_pid)?;
            thread::sleep(Duration::from_secs(1));
            if pid_alive(child_pid) {
                kill_process_group("-KILL", child_pid)?;
            }
        }
        if let Some(runner_pid) = read_pid_file(&runner_pid_path)? {
            if pid_alive(runner_pid) {
                let _ = kill_pid("-TERM", runner_pid);
                thread::sleep(Duration::from_secs(1));
                if pid_alive(runner_pid) {
                    let _ = kill_pid("-KILL", runner_pid);
                }
            }
        }
        if let Some(keepalive_pid) =
            read_pid_file(&keepalive_pid_path)?.filter(|pid| pid_alive(*pid))
        {
            let _ = kill_pid("-TERM", keepalive_pid);
        }

        remove_if_exists(&runner_pid_path)?;
        remove_if_exists(&child_pid_path)?;
        remove_if_exists(&keepalive_pid_path)?;
        remove_if_exists(&attach_marker_path)?;
        remove_if_exists(&attach_pid_path)?;
        Ok(())
    }

    pub fn tail_session(&self, session_id: &str, limit: usize) -> Result<(), HelperError> {
        if session_id.trim().is_empty() {
            return Err(HelperError::InvalidArgs("missing --session-id".to_string()));
        }
        let log_path = self.paths.session_dir(session_id).join("output.log");
        touch_file(&log_path)?;
        let mut stdout = io::stdout().lock();
        copy_tail_bytes(&log_path, limit as u64, &mut stdout)?;
        stdout.flush()?;
        Ok(())
    }

    pub fn attach_session(&self, session_id: &str) -> Result<(), HelperError> {
        if session_id.trim().is_empty() {
            return Err(HelperError::InvalidArgs("missing --session-id".to_string()));
        }
        let session_dir = self.paths.session_dir(session_id);
        let fifo_path = session_dir.join("input.fifo");
        let log_path = session_dir.join("output.log");
        let runner_pid_path = session_dir.join("runner.pid");
        let attach_marker_path = session_dir.join("attached.lock");
        let attach_pid_path = session_dir.join("attach.pid");
        let runner_pid = read_pid_file(&runner_pid_path)?
            .filter(|pid| pid_alive(*pid))
            .ok_or_else(|| HelperError::CommandFailed("session is not running".to_string()))?;
        let _ = runner_pid;
        touch_file(&log_path)?;
        write_private_file(&attach_marker_path, b"attached\n")?;
        write_private_file(
            &attach_pid_path,
            format!("{}\n", std::process::id()).as_bytes(),
        )?;
        let cleanup = AttachCleanup::new(attach_marker_path.clone(), attach_pid_path.clone());

        let fifo_for_input = fifo_path.clone();
        let input_handle = thread::spawn(move || -> io::Result<()> {
            let mut fifo = OpenOptions::new().write(true).open(&fifo_for_input)?;
            let mut stdin = io::stdin().lock();
            let mut buffer = [0_u8; 8192];
            loop {
                let bytes_read = stdin.read(&mut buffer)?;
                if bytes_read == 0 {
                    break;
                }
                fifo.write_all(&buffer[..bytes_read])?;
                fifo.flush()?;
            }
            Ok(())
        });

        let mut stdout = io::stdout().lock();
        let mut offset = file_len(&log_path)?.saturating_sub(DEFAULT_ATTACH_TAIL_BYTES);
        loop {
            copy_new_bytes(&log_path, &mut offset, &mut stdout)?;
            stdout.flush()?;
            if input_handle.is_finished() {
                break;
            }
            thread::sleep(Duration::from_millis(100));
        }
        copy_new_bytes(&log_path, &mut offset, &mut stdout)?;
        stdout.flush()?;
        let input_result = input_handle
            .join()
            .map_err(|_| HelperError::CommandFailed("attach input thread panicked".to_string()))?;
        cleanup.finish();
        input_result?;
        Ok(())
    }

    pub fn run_session_runner(&self, session_id: &str) -> Result<(), HelperError> {
        if session_id.trim().is_empty() {
            return Err(HelperError::InvalidArgs("missing --session-id".to_string()));
        }

        let session_dir = self.paths.session_dir(session_id);
        let log_path = session_dir.join("output.log");
        let runner_pid_path = session_dir.join("runner.pid");
        let child_pid_path = session_dir.join("child.pid");
        let exit_code_path = session_dir.join("exit_code");
        let attach_marker_path = session_dir.join("attached.lock");
        let attach_pid_path = session_dir.join("attach.pid");

        let result = self.run_session_runner_inner(session_id);
        if let Err(error) = &result {
            touch_file(&log_path)?;
            let mut log = OpenOptions::new().append(true).open(&log_path)?;
            writeln!(log, "runner error: {error}")?;
            write_private_file(&exit_code_path, b"1\n")?;
            let _ = remove_if_exists(&child_pid_path);
            let _ = remove_if_exists(&runner_pid_path);
            let _ = remove_if_exists(&attach_marker_path);
            let _ = remove_if_exists(&attach_pid_path);
        }
        result
    }

    fn run_session_runner_inner(&self, session_id: &str) -> Result<(), HelperError> {
        let session_dir = self.paths.session_dir(session_id);
        let fifo_path = session_dir.join("input.fifo");
        let log_path = session_dir.join("output.log");
        let launch_path = session_dir.join("launch.sh");
        let runner_pid_path = session_dir.join("runner.pid");
        let child_pid_path = session_dir.join("child.pid");
        let exit_code_path = session_dir.join("exit_code");
        let attach_marker_path = session_dir.join("attached.lock");
        let attach_pid_path = session_dir.join("attach.pid");

        ensure_fifo(&fifo_path)?;
        touch_file(&log_path)?;

        let (master_fd, slave_fd) = open_pty_pair()?;
        let master = File::from(master_fd);
        let input_master = master.try_clone()?;
        let output_master = master;
        let fifo = OpenOptions::new()
            .read(true)
            .write(true)
            .custom_flags(libc::O_NONBLOCK)
            .open(&fifo_path)?;
        let log = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&log_path)?;

        let stop = Arc::new(AtomicBool::new(false));
        let input_stop = Arc::clone(&stop);
        let input_handle = thread::spawn(move || copy_fifo_to_pty(fifo, input_master, input_stop));
        let output_handle = thread::spawn(move || copy_pty_to_log(output_master, log));

        let mut child = spawn_session_child(&launch_path, slave_fd)?;
        write_private_file(&child_pid_path, format!("{}\n", child.id()).as_bytes())?;

        let status = child.wait()?;
        let exit_code = exit_status_code(status);
        write_private_file(&exit_code_path, format!("{exit_code}\n").as_bytes())?;

        stop.store(true, Ordering::Relaxed);
        join_helper_thread(input_handle, "session input forwarder")?;
        join_helper_thread(output_handle, "session output recorder")?;

        remove_if_exists(&child_pid_path)?;
        remove_if_exists(&runner_pid_path)?;
        remove_if_exists(&attach_marker_path)?;
        remove_if_exists(&attach_pid_path)?;
        Ok(())
    }

    pub fn run_command(&self, command: &str, args: &[String]) -> Result<(), HelperError> {
        match command {
            "version" => {
                self.print_health(false)?;
                Ok(())
            }
            "health" => {
                self.print_health(true)?;
                Ok(())
            }
            "controller" => self.run_controller_command(args),
            "session" => self.run_session_command(args),
            // compatibility aliases for the initial script-based client
            "create-session" => {
                let request = CreateSessionArgs::parse(args)?;
                self.print_create_result(self.create_session(
                    &request.session_id,
                    &request.cwd,
                    request.command.as_deref(),
                )?);
                Ok(())
            }
            "session-status" => {
                let request = SessionIdArgs::parse(args)?;
                self.print_status_result(self.session_status(&request.session_id)?);
                Ok(())
            }
            "signal" => {
                let request = SignalSessionArgs::parse(args)?;
                self.signal_session(&request.session_id, &request.signal)?;
                print_kv("ok", "true");
                Ok(())
            }
            "terminate" => {
                let request = SessionIdArgs::parse(args)?;
                self.terminate_session(&request.session_id)?;
                print_kv("ok", "true");
                Ok(())
            }
            "tail" => {
                let request = TailSessionArgs::parse(args)?;
                self.tail_session(&request.session_id, request.limit)
            }
            "attach" => {
                let request = SessionIdArgs::parse(args)?;
                self.attach_session(&request.session_id)
            }
            "session-runner" => {
                let request = SessionIdArgs::parse(args)?;
                self.run_session_runner(&request.session_id)
            }
            other => Err(HelperError::InvalidArgs(format!(
                "unknown command: {other}"
            ))),
        }
    }

    fn print_health(&self, include_healthy: bool) -> Result<(), HelperError> {
        let health = self.health()?;
        print_kv("version", &health.version);
        print_kv("protocol_version", &health.protocol_version);
        print_kv("helper_kind", &health.helper_kind);
        print_kv("helper_path", &health.helper_path);
        print_kv("state_root", &health.state_root);
        print_kv("controller_id", &health.controller_id);
        print_kv(
            "target_triple",
            health.target_triple.as_deref().unwrap_or(""),
        );
        print_kv(
            "artifact_source",
            health.artifact_source.as_deref().unwrap_or(""),
        );
        print_kv(
            "artifact_sha256",
            health.artifact_sha256.as_deref().unwrap_or(""),
        );
        print_kv(
            "missing_dependencies",
            &health.missing_dependencies.join(","),
        );
        if include_healthy {
            print_kv("healthy", if health.healthy { "true" } else { "false" });
        }
        Ok(())
    }

    fn run_controller_command(&self, args: &[String]) -> Result<(), HelperError> {
        let Some(subcommand) = args.first().map(String::as_str) else {
            return Err(HelperError::InvalidArgs(
                "missing controller subcommand".to_string(),
            ));
        };
        match subcommand {
            "ensure" => {
                let request = ControllerEnsureArgs::parse(&args[1..])?;
                let controller_id = self.ensure_controller_id(request.controller_id.as_deref())?;
                print_kv("controller_id", &controller_id);
                print_kv("protocol_version", PROTOCOL_VERSION);
                print_kv("helper_kind", HELPER_KIND);
                Ok(())
            }
            other => Err(HelperError::InvalidArgs(format!(
                "unknown controller subcommand: {other}"
            ))),
        }
    }

    fn run_session_command(&self, args: &[String]) -> Result<(), HelperError> {
        let Some(subcommand) = args.first().map(String::as_str) else {
            return Err(HelperError::InvalidArgs(
                "missing session subcommand".to_string(),
            ));
        };
        match subcommand {
            "create" => {
                let request = CreateSessionArgs::parse(&args[1..])?;
                self.print_create_result(self.create_session(
                    &request.session_id,
                    &request.cwd,
                    request.command.as_deref(),
                )?);
                Ok(())
            }
            "status" => {
                let request = SessionIdArgs::parse(&args[1..])?;
                self.print_status_result(self.session_status(&request.session_id)?);
                Ok(())
            }
            "signal" => {
                let request = SignalSessionArgs::parse(&args[1..])?;
                self.signal_session(&request.session_id, &request.signal)?;
                print_kv("ok", "true");
                Ok(())
            }
            "terminate" => {
                let request = SessionIdArgs::parse(&args[1..])?;
                self.terminate_session(&request.session_id)?;
                print_kv("ok", "true");
                Ok(())
            }
            "tail" => {
                let request = TailSessionArgs::parse(&args[1..])?;
                self.tail_session(&request.session_id, request.limit)
            }
            "attach" => {
                let request = SessionIdArgs::parse(&args[1..])?;
                self.attach_session(&request.session_id)
            }
            other => Err(HelperError::InvalidArgs(format!(
                "unknown session subcommand: {other}"
            ))),
        }
    }

    fn print_create_result(&self, result: SessionCreateResult) {
        print_kv("session_id", &result.session_id);
        print_kv("controller_id", &result.controller_id);
        print_kv("state", &result.state);
        print_kv(
            "pid",
            &result.pid.map(|pid| pid.to_string()).unwrap_or_default(),
        );
        print_kv("log_path", result.log_path.as_deref().unwrap_or(""));
    }

    fn print_status_result(&self, result: SessionStatusResult) {
        print_kv("session_id", &result.session_id);
        print_kv("controller_id", &result.controller_id);
        print_kv("state", &result.state);
        print_kv(
            "pid",
            &result.pid.map(|pid| pid.to_string()).unwrap_or_default(),
        );
        print_kv(
            "exit_code",
            &result
                .exit_code
                .map(|code| code.to_string())
                .unwrap_or_default(),
        );
        print_kv("total_bytes", &result.total_bytes.to_string());
        print_kv(
            "last_output_at",
            &result
                .last_output_at_epoch
                .map(|epoch| epoch.to_string())
                .unwrap_or_default(),
        );
    }
}

#[derive(Debug, Clone)]
struct ControllerEnsureArgs {
    controller_id: Option<String>,
}

impl ControllerEnsureArgs {
    fn parse(args: &[String]) -> Result<Self, HelperError> {
        let mut controller_id = None;
        let mut index = 0;
        while index < args.len() {
            match args[index].as_str() {
                "--controller-id" => {
                    let value = args.get(index + 1).ok_or_else(|| {
                        HelperError::InvalidArgs("missing value for --controller-id".to_string())
                    })?;
                    controller_id = Some(value.clone());
                    index += 2;
                }
                "--json" => index += 1,
                other => {
                    return Err(HelperError::InvalidArgs(format!(
                        "unknown controller ensure arg: {other}"
                    )));
                }
            }
        }
        Ok(Self { controller_id })
    }
}

#[derive(Debug, Clone)]
struct CreateSessionArgs {
    session_id: String,
    cwd: String,
    command: Option<String>,
}

impl CreateSessionArgs {
    fn parse(args: &[String]) -> Result<Self, HelperError> {
        let mut session_id = None;
        let mut cwd = None;
        let mut command = None;
        let mut index = 0;
        while index < args.len() {
            match args[index].as_str() {
                "--session-id" => {
                    session_id = Some(next_arg(args, index, "--session-id")?.to_string());
                    index += 2;
                }
                "--cwd" => {
                    cwd = Some(next_arg(args, index, "--cwd")?.to_string());
                    index += 2;
                }
                "--command" => {
                    command = Some(next_arg(args, index, "--command")?.to_string());
                    index += 2;
                }
                "--json" => index += 1,
                other => {
                    return Err(HelperError::InvalidArgs(format!(
                        "unknown create-session arg: {other}"
                    )));
                }
            }
        }
        Ok(Self {
            session_id: session_id
                .ok_or_else(|| HelperError::InvalidArgs("missing --session-id".to_string()))?,
            cwd: cwd.ok_or_else(|| HelperError::InvalidArgs("missing --cwd".to_string()))?,
            command,
        })
    }
}

#[derive(Debug, Clone)]
struct SessionIdArgs {
    session_id: String,
}

impl SessionIdArgs {
    fn parse(args: &[String]) -> Result<Self, HelperError> {
        let mut session_id = None;
        let mut index = 0;
        while index < args.len() {
            match args[index].as_str() {
                "--session-id" => {
                    session_id = Some(next_arg(args, index, "--session-id")?.to_string());
                    index += 2;
                }
                "--json" => index += 1,
                other => {
                    return Err(HelperError::InvalidArgs(format!(
                        "unknown session arg: {other}"
                    )));
                }
            }
        }
        Ok(Self {
            session_id: session_id
                .ok_or_else(|| HelperError::InvalidArgs("missing --session-id".to_string()))?,
        })
    }
}

#[derive(Debug, Clone)]
struct SignalSessionArgs {
    session_id: String,
    signal: String,
}

impl SignalSessionArgs {
    fn parse(args: &[String]) -> Result<Self, HelperError> {
        let mut session_id = None;
        let mut signal = Some("INT".to_string());
        let mut index = 0;
        while index < args.len() {
            match args[index].as_str() {
                "--session-id" => {
                    session_id = Some(next_arg(args, index, "--session-id")?.to_string());
                    index += 2;
                }
                "--signal" => {
                    signal = Some(next_arg(args, index, "--signal")?.to_string());
                    index += 2;
                }
                "--json" => index += 1,
                other => {
                    return Err(HelperError::InvalidArgs(format!(
                        "unknown signal arg: {other}"
                    )));
                }
            }
        }
        Ok(Self {
            session_id: session_id
                .ok_or_else(|| HelperError::InvalidArgs("missing --session-id".to_string()))?,
            signal: signal.unwrap_or_else(|| "INT".to_string()),
        })
    }
}

#[derive(Debug, Clone)]
struct TailSessionArgs {
    session_id: String,
    limit: usize,
}

impl TailSessionArgs {
    fn parse(args: &[String]) -> Result<Self, HelperError> {
        let mut session_id = None;
        let mut limit = 65_536_usize;
        let mut index = 0;
        while index < args.len() {
            match args[index].as_str() {
                "--session-id" => {
                    session_id = Some(next_arg(args, index, "--session-id")?.to_string());
                    index += 2;
                }
                "--limit" => {
                    limit = next_arg(args, index, "--limit")?
                        .parse::<usize>()
                        .map_err(|_| {
                            HelperError::InvalidArgs("invalid value for --limit".to_string())
                        })?;
                    index += 2;
                }
                other => {
                    return Err(HelperError::InvalidArgs(format!(
                        "unknown tail arg: {other}"
                    )));
                }
            }
        }
        Ok(Self {
            session_id: session_id
                .ok_or_else(|| HelperError::InvalidArgs("missing --session-id".to_string()))?,
            limit,
        })
    }
}

struct AttachCleanup {
    attach_marker_path: PathBuf,
    attach_pid_path: PathBuf,
    active: bool,
}

impl AttachCleanup {
    fn new(attach_marker_path: PathBuf, attach_pid_path: PathBuf) -> Self {
        Self {
            attach_marker_path,
            attach_pid_path,
            active: true,
        }
    }

    fn finish(mut self) {
        self.active = false;
        let _ = remove_if_exists(&self.attach_marker_path);
        let _ = remove_if_exists(&self.attach_pid_path);
    }
}

impl Drop for AttachCleanup {
    fn drop(&mut self) {
        if self.active {
            let _ = remove_if_exists(&self.attach_marker_path);
            let _ = remove_if_exists(&self.attach_pid_path);
        }
    }
}

fn helper_version() -> String {
    format!("pnevma-remote-helper/{}", env!("CARGO_PKG_VERSION"))
}

fn default_state_root() -> Option<PathBuf> {
    if let Some(root) = env::var_os("XDG_STATE_HOME") {
        return Some(PathBuf::from(root).join("pnevma/remote"));
    }
    env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/state/pnevma/remote"))
}

fn next_arg<'a>(args: &'a [String], index: usize, flag: &str) -> Result<&'a str, HelperError> {
    args.get(index + 1)
        .map(String::as_str)
        .ok_or_else(|| HelperError::InvalidArgs(format!("missing value for {flag}")))
}

fn print_kv(key: &str, value: &str) {
    println!("{key}={value}");
}

fn ensure_dir(path: &Path) -> Result<(), HelperError> {
    fs::create_dir_all(path)?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    Ok(())
}

fn write_private_file(path: &Path, bytes: &[u8]) -> Result<(), HelperError> {
    if let Some(parent) = path.parent() {
        ensure_dir(parent)?;
    }
    fs::write(path, bytes)?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    Ok(())
}

fn touch_file(path: &Path) -> Result<(), HelperError> {
    if let Some(parent) = path.parent() {
        ensure_dir(parent)?;
    }
    let _ = OpenOptions::new().create(true).append(true).open(path)?;
    if path.is_file() {
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    }
    Ok(())
}

fn remove_if_exists(path: &Path) -> Result<(), HelperError> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(HelperError::Io(error)),
    }
}

fn read_trimmed_string(path: &Path) -> Result<Option<String>, HelperError> {
    match fs::read_to_string(path) {
        Ok(contents) => Ok(Some(contents.trim().to_string())),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(HelperError::Io(error)),
    }
}

fn read_install_metadata(path: &Path) -> Result<InstallMetadata, HelperError> {
    let Some(contents) = read_trimmed_string(path)? else {
        return Ok(InstallMetadata::default());
    };

    let mut metadata = InstallMetadata::default();
    for line in contents.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let Some((key, value)) = trimmed.split_once('=') else {
            continue;
        };
        let value = value.trim();
        if value.is_empty() {
            continue;
        }
        match key {
            "target_triple" => metadata.target_triple = Some(value.to_string()),
            "artifact_source" => metadata.artifact_source = Some(value.to_string()),
            "artifact_sha256" => metadata.artifact_sha256 = Some(value.to_string()),
            _ => {}
        }
    }
    Ok(metadata)
}

fn read_pid_file(path: &Path) -> Result<Option<u32>, HelperError> {
    Ok(read_trimmed_string(path)?.and_then(|value| value.parse::<u32>().ok()))
}

fn command_exists(name: &str) -> bool {
    Command::new("sh")
        .arg("-lc")
        .arg(format!("command -v {} >/dev/null 2>&1", shell_quote(name)))
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

fn missing_dependencies() -> Vec<String> {
    HELPER_DEPENDENCIES
        .iter()
        .copied()
        .filter(|dependency| !command_exists(dependency))
        .map(ToOwned::to_owned)
        .collect()
}

fn pid_alive(pid: u32) -> bool {
    Command::new("sh")
        .arg("-lc")
        .arg(format!("kill -0 {pid} >/dev/null 2>&1"))
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

fn cleanup_dead_pid_file(path: &Path) -> Result<(), HelperError> {
    if let Some(pid) = read_pid_file(path)? {
        if !pid_alive(pid) {
            remove_if_exists(path)?;
        }
    }
    Ok(())
}

fn ensure_fifo(path: &Path) -> Result<(), HelperError> {
    if let Ok(metadata) = fs::symlink_metadata(path) {
        if metadata.file_type().is_fifo() {
            return Ok(());
        }
        remove_if_exists(path)?;
    }
    if let Some(parent) = path.parent() {
        ensure_dir(parent)?;
    }
    let status = Command::new("mkfifo").arg(path).status()?;
    if !status.success() {
        return Err(HelperError::CommandFailed(format!(
            "mkfifo failed with status {status}"
        )));
    }
    Ok(())
}

fn write_launch_script(path: &Path, cwd: &str, command: &str) -> Result<(), HelperError> {
    let cwd = resolve_launch_cwd(cwd)?;
    let contents = format!(
        "#!/bin/sh\nset -eu\ncd -- {}\nexec /bin/sh -lc {}\n",
        shell_quote(&cwd),
        shell_quote(command)
    );
    write_private_file(path, contents.as_bytes())?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    Ok(())
}

fn resolve_launch_cwd(cwd: &str) -> Result<String, HelperError> {
    if cwd == "~" {
        return env::var("HOME")
            .map_err(|_| HelperError::Environment("HOME is not set".to_string()));
    }
    if let Some(relative) = cwd.strip_prefix("~/") {
        let home = env::var("HOME")
            .map_err(|_| HelperError::Environment("HOME is not set".to_string()))?;
        return Ok(PathBuf::from(home).join(relative).display().to_string());
    }
    Ok(cwd.to_string())
}

fn open_pty_pair() -> Result<(OwnedFd, OwnedFd), HelperError> {
    let mut master = -1;
    let mut slave = -1;
    let mut winsize = libc::winsize {
        ws_row: 24,
        ws_col: 80,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    let rc = unsafe {
        libc::openpty(
            &mut master,
            &mut slave,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            &mut winsize,
        )
    };
    if rc == -1 {
        return Err(HelperError::Io(io::Error::last_os_error()));
    }
    let master = unsafe { OwnedFd::from_raw_fd(master) };
    let slave = unsafe { OwnedFd::from_raw_fd(slave) };
    Ok((master, slave))
}

fn spawn_session_child(launch_path: &Path, slave_fd: OwnedFd) -> Result<Child, HelperError> {
    let slave = File::from(slave_fd);
    let stdin = slave.try_clone()?;
    let stdout = slave.try_clone()?;
    let stderr = slave;
    let tty_fd = stderr.as_raw_fd();
    let mut command = Command::new("sh");
    command.arg(launch_path);
    command.stdin(Stdio::from(stdin));
    command.stdout(Stdio::from(stdout));
    command.stderr(Stdio::from(stderr));
    unsafe {
        command.pre_exec(move || {
            if libc::setsid() == -1 {
                return Err(io::Error::last_os_error());
            }
            if libc::ioctl(tty_fd, libc::TIOCSCTTY as _, 0) == -1 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
    command.spawn().map_err(HelperError::Io)
}

fn copy_fifo_to_pty(
    mut fifo: File,
    mut pty_input: File,
    stop: Arc<AtomicBool>,
) -> Result<(), HelperError> {
    let mut buffer = [0_u8; 8192];
    loop {
        if stop.load(Ordering::Relaxed) {
            return Ok(());
        }
        match fifo.read(&mut buffer) {
            Ok(0) => thread::sleep(FIFO_POLL_INTERVAL),
            Ok(bytes_read) => {
                if let Err(error) = pty_input.write_all(&buffer[..bytes_read]) {
                    if matches!(
                        error.kind(),
                        io::ErrorKind::BrokenPipe | io::ErrorKind::UnexpectedEof
                    ) {
                        return Ok(());
                    }
                    return Err(HelperError::Io(error));
                }
                pty_input.flush()?;
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                thread::sleep(FIFO_POLL_INTERVAL);
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(HelperError::Io(error)),
        }
    }
}

fn copy_pty_to_log(mut pty_output: File, mut log: File) -> Result<(), HelperError> {
    let mut buffer = [0_u8; 8192];
    loop {
        match pty_output.read(&mut buffer) {
            Ok(0) => return Ok(()),
            Ok(bytes_read) => {
                log.write_all(&buffer[..bytes_read])?;
                log.flush()?;
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) if error.raw_os_error() == Some(libc::EIO) => return Ok(()),
            Err(error) => return Err(HelperError::Io(error)),
        }
    }
}

fn exit_status_code(status: std::process::ExitStatus) -> i32 {
    status
        .code()
        .or_else(|| status.signal().map(|signal| 128 + signal))
        .unwrap_or(1)
}

fn join_helper_thread(
    handle: thread::JoinHandle<Result<(), HelperError>>,
    label: &str,
) -> Result<(), HelperError> {
    handle
        .join()
        .map_err(|_| HelperError::CommandFailed(format!("{label} panicked")))?
}

fn spawn_detached_shell(command: &str) -> Result<u32, HelperError> {
    let bootstrap = format!(
        "nohup sh -lc {} >/dev/null 2>&1 & printf '%s\\n' \"$!\"",
        shell_quote(command)
    );
    let output = Command::new("sh").arg("-lc").arg(bootstrap).output()?;
    if !output.status.success() {
        return Err(HelperError::CommandFailed(
            String::from_utf8_lossy(&output.stderr).trim().to_string(),
        ));
    }
    let pid = String::from_utf8_lossy(&output.stdout)
        .trim()
        .parse::<u32>()
        .map_err(|_| HelperError::CommandFailed("failed to parse detached pid".to_string()))?;
    Ok(pid)
}

fn kill_pid(signal: &str, pid: u32) -> Result<(), HelperError> {
    let status = Command::new("kill")
        .arg(signal)
        .arg(pid.to_string())
        .status()?;
    if status.success() {
        Ok(())
    } else {
        Err(HelperError::CommandFailed(format!(
            "kill {signal} {pid} failed with status {status}"
        )))
    }
}

fn kill_process_group(signal: &str, pid: u32) -> Result<(), HelperError> {
    let status = Command::new("kill")
        .arg(signal)
        .arg("--")
        .arg(format!("-{pid}"))
        .status()?;
    if status.success() {
        Ok(())
    } else {
        Err(HelperError::CommandFailed(format!(
            "kill {signal} -- -{pid} failed with status {status}"
        )))
    }
}

fn file_len(path: &Path) -> Result<u64, HelperError> {
    match fs::metadata(path) {
        Ok(metadata) => Ok(metadata.len()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(0),
        Err(error) => Err(HelperError::Io(error)),
    }
}

fn file_mtime_epoch(path: &Path) -> Result<Option<i64>, HelperError> {
    match fs::metadata(path) {
        Ok(metadata) => Ok(metadata
            .modified()
            .ok()
            .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
            .map(|duration| duration.as_secs() as i64)),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(HelperError::Io(error)),
    }
}

fn copy_tail_bytes(path: &Path, limit: u64, writer: &mut impl Write) -> Result<(), HelperError> {
    touch_file(path)?;
    let mut file = File::open(path)?;
    let len = file.metadata()?.len();
    let offset = len.saturating_sub(limit);
    file.seek(SeekFrom::Start(offset))?;
    io::copy(&mut file, writer)?;
    Ok(())
}

fn copy_new_bytes(
    path: &Path,
    offset: &mut u64,
    writer: &mut impl Write,
) -> Result<(), HelperError> {
    touch_file(path)?;
    let len = file_len(path)?;
    if *offset > len {
        *offset = 0;
    }
    let mut file = File::open(path)?;
    file.seek(SeekFrom::Start(*offset))?;
    io::copy(&mut file, writer)?;
    *offset = len;
    Ok(())
}

fn shell_quote(value: &str) -> String {
    if value.is_empty() {
        return "''".to_string();
    }
    format!("'{}'", value.replace('\'', "'\\''"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::SystemTime;

    fn test_runtime() -> HelperRuntime {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("unix epoch")
            .as_nanos();
        let root = env::temp_dir().join(format!("pnevma-remote-helper-tests-{unique}"));
        HelperRuntime::new(HelperPaths::new(
            root.join("pnevma-remote-helper"),
            root.join("state"),
        ))
    }

    #[test]
    fn controller_ensure_persists_requested_id() {
        let runtime = test_runtime();
        let first = runtime
            .ensure_controller_id(Some("controller-1"))
            .expect("first controller id");
        let second = runtime
            .ensure_controller_id(Some("controller-2"))
            .expect("second controller id");
        assert_eq!(first, "controller-1");
        assert_eq!(second, "controller-1");
    }

    #[test]
    fn health_reports_binary_protocol_metadata() {
        let runtime = test_runtime();
        let health = runtime.health().expect("health");
        assert_eq!(health.helper_kind, HELPER_KIND);
        assert_eq!(health.protocol_version, PROTOCOL_VERSION);
        assert!(health.healthy);
        assert!(health.version.contains("pnevma-remote-helper/"));
        assert!(health.target_triple.is_none());
        assert!(health.artifact_source.is_none());
        assert!(health.artifact_sha256.is_none());
        assert!(health.missing_dependencies.is_empty());
    }

    #[test]
    fn health_reports_install_metadata_fields() {
        let runtime = test_runtime();
        write_private_file(
            &runtime.paths.install_metadata_path(),
            b"target_triple=x86_64-unknown-linux-musl\nartifact_source=bundle_relative\nartifact_sha256=abc123\n",
        )
        .expect("write install metadata");

        let health = runtime.health().expect("health");
        assert_eq!(
            health.target_triple.as_deref(),
            Some("x86_64-unknown-linux-musl")
        );
        assert_eq!(health.artifact_source.as_deref(), Some("bundle_relative"));
        assert_eq!(health.artifact_sha256.as_deref(), Some("abc123"));
    }

    #[test]
    fn session_status_returns_lost_for_missing_session() {
        let runtime = test_runtime();
        let status = runtime.session_status("missing").expect("status");
        assert_eq!(status.state, "lost");
        assert_eq!(status.session_id, "missing");
        assert_eq!(status.total_bytes, 0);
    }

    #[test]
    fn resolve_launch_cwd_expands_home_aliases() {
        let home = env::var("HOME").expect("HOME");
        assert_eq!(resolve_launch_cwd("~").expect("expand home"), home);
        assert_eq!(
            resolve_launch_cwd("~/nested/path").expect("expand nested home"),
            PathBuf::from(&home)
                .join("nested/path")
                .display()
                .to_string()
        );
    }

    #[test]
    fn session_runner_records_output_and_exit_code() {
        let runtime = test_runtime();
        let session_id = "runner-test";
        let session_dir = runtime.paths.session_dir(session_id);
        ensure_dir(&session_dir).expect("session dir");

        let fifo_path = session_dir.join("input.fifo");
        let log_path = session_dir.join("output.log");
        let launch_path = session_dir.join("launch.sh");
        let runner_pid_path = session_dir.join("runner.pid");
        let child_pid_path = session_dir.join("child.pid");
        let exit_code_path = session_dir.join("exit_code");

        ensure_fifo(&fifo_path).expect("fifo");
        touch_file(&log_path).expect("log");
        write_launch_script(
            &launch_path,
            env::temp_dir().to_str().expect("temp dir str"),
            "printf 'runner-ok\\n'",
        )
        .expect("launch script");
        write_private_file(&runner_pid_path, b"999999\n").expect("runner pid");

        runtime
            .run_session_runner(session_id)
            .expect("run session runner");

        let output = fs::read_to_string(&log_path).expect("read log");
        assert!(
            output.contains("runner-ok"),
            "expected runner output in log, got: {output:?}"
        );
        assert_eq!(
            read_trimmed_string(&exit_code_path).expect("exit code"),
            Some("0".to_string())
        );
        assert_eq!(
            read_trimmed_string(&runner_pid_path).expect("runner pid removed"),
            None
        );
        assert_eq!(
            read_trimmed_string(&child_pid_path).expect("child pid removed"),
            None
        );
    }

    #[test]
    fn session_status_clears_stale_attach_marker_when_attach_pid_is_dead() {
        let runtime = test_runtime();
        let session_id = "stale-attach-test";
        let session_dir = runtime.paths.session_dir(session_id);
        ensure_dir(&session_dir).expect("session dir");

        let log_path = session_dir.join("output.log");
        let runner_pid_path = session_dir.join("runner.pid");
        let attach_marker_path = session_dir.join("attached.lock");
        let attach_pid_path = session_dir.join("attach.pid");

        touch_file(&log_path).expect("log");
        write_private_file(
            &runner_pid_path,
            format!("{}\n", std::process::id()).as_bytes(),
        )
        .expect("runner pid");
        write_private_file(&attach_marker_path, b"attached\n").expect("attach marker");
        write_private_file(&attach_pid_path, b"999999\n").expect("attach pid");

        let status = runtime.session_status(session_id).expect("status");
        assert_eq!(status.state, "detached");
        assert!(
            !attach_marker_path.exists(),
            "stale attach marker should be removed"
        );
        assert!(
            !attach_pid_path.exists(),
            "stale attach pid should be removed"
        );
    }

    #[test]
    fn compatibility_aliases_parse_without_error() {
        let runtime = test_runtime();
        let result = runtime.run_command("signal", &["--session-id".into(), "missing".into()]);
        assert!(matches!(result, Err(HelperError::CommandFailed(_))));
    }
}
