//! pnevma-session-proxy — terminal proxy for Ghostty
//!
//! Usage:
//!   pnevma-session-proxy attach --session <uuid> --socket <path>
//!   pnevma-session-proxy attach --session <uuid> --ssh-command <cmd>
//!
//! For local sessions: connects to the Unix socket and relays terminal I/O.
//! For remote sessions: execs the SSH command (replacing process).

use pnevma_session_protocol::frame::{
    decode_frame_header, encode_frame, BackendMessage, ProxyMessage,
};
use std::path::PathBuf;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;
use uuid::Uuid;

#[derive(Debug)]
struct Args {
    session_id: Uuid,
    socket_path: Option<PathBuf>,
    ssh_command: Option<String>,
}

fn parse_args() -> Result<Args, String> {
    let args: Vec<String> = std::env::args().collect();

    if args.len() < 2 || args[1] != "attach" {
        return Err("Usage: pnevma-session-proxy attach --session <uuid> --socket <path>".into());
    }

    let mut session_id = None;
    let mut socket_path = None;
    let mut ssh_command = None;
    let mut i = 2;

    while i < args.len() {
        match args[i].as_str() {
            "--session" => {
                i += 1;
                session_id = Some(
                    args.get(i)
                        .ok_or("--session requires a value")?
                        .parse::<Uuid>()
                        .map_err(|e| format!("invalid session UUID: {e}"))?,
                );
            }
            "--socket" => {
                i += 1;
                socket_path = Some(PathBuf::from(
                    args.get(i).ok_or("--socket requires a value")?,
                ));
            }
            "--ssh-command" => {
                i += 1;
                ssh_command = Some(args.get(i).ok_or("--ssh-command requires a value")?.clone());
            }
            other => return Err(format!("unknown argument: {other}")),
        }
        i += 1;
    }

    let session_id = session_id.ok_or("--session is required")?;

    if socket_path.is_none() && ssh_command.is_none() {
        return Err("either --socket or --ssh-command is required".into());
    }

    Ok(Args {
        session_id,
        socket_path,
        ssh_command,
    })
}

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let args = match parse_args() {
        Ok(args) => args,
        Err(e) => {
            eprintln!("error: {e}");
            std::process::exit(1);
        }
    };

    if let Some(ssh_command) = args.ssh_command {
        // Remote session: exec the SSH command (replaces this process)
        exec_ssh_command(&ssh_command);
    }

    if let Some(socket_path) = args.socket_path {
        let code = match run_local_proxy(args.session_id, &socket_path).await {
            Ok(code) => code.unwrap_or(0),
            Err(e) => {
                eprintln!("proxy error: {e}");
                1
            }
        };
        std::process::exit(code);
    }
}

async fn run_local_proxy(
    _session_id: Uuid,
    socket_path: &std::path::Path,
) -> Result<Option<i32>, Box<dyn std::error::Error>> {
    let stream = UnixStream::connect(socket_path)
        .await
        .map_err(|e| format!("connect to {}: {e}", socket_path.display()))?;
    let (mut socket_reader, mut socket_writer) = stream.into_split();

    // Set stdin to raw mode so input bytes pass through without
    // line-discipline processing (echo, canonical buffering, signal handling).
    //
    // When launched inside an embedded terminal (e.g. Ghostty libghostty),
    // the PTY slave may not be fully initialized at exec time. We retry
    // briefly with back-off to handle this race.
    let _raw_guard = enter_raw_mode_with_retry();

    let mut stdin = tokio::io::stdin();
    let mut stdout = tokio::io::stdout();

    // Register SIGWINCH handler
    let mut sigwinch =
        tokio::signal::unix::signal(tokio::signal::unix::SignalKind::window_change())?;

    // Send initial terminal size
    if let Some((cols, rows)) = get_terminal_size() {
        let msg = ProxyMessage::Resize { cols, rows };
        let payload = serde_json::to_vec(&msg)?;
        let frame = encode_frame(&payload).map_err(|e| e.to_string())?;
        socket_writer.write_all(&frame).await?;
    }

    let mut stdin_buf = [0u8; 4096];
    let exit_code: Option<i32>;

    loop {
        tokio::select! {
            // stdin → socket
            result = stdin.read(&mut stdin_buf) => {
                match result {
                    Ok(0) => {
                        // stdin closed, send detach
                        let msg = ProxyMessage::Detach;
                        let payload = serde_json::to_vec(&msg)?;
                        let frame = encode_frame(&payload).map_err(|e| e.to_string())?;
                        let _ = socket_writer.write_all(&frame).await;
                        exit_code = Some(0);
                        break;
                    }
                    Ok(n) => {
                        let msg = ProxyMessage::Input(stdin_buf[..n].to_vec());
                        let payload = serde_json::to_vec(&msg)?;
                        let frame = encode_frame(&payload).map_err(|e| e.to_string())?;
                        socket_writer.write_all(&frame).await?;
                    }
                    Err(e) => {
                        return Err(e.into());
                    }
                }
            }
            // socket → stdout (read framed BackendMessage)
            result = read_backend_message(&mut socket_reader) => {
                match result {
                    Ok(Some(BackendMessage::Output(data))) => {
                        stdout.write_all(&data).await?;
                        stdout.flush().await?;
                    }
                    Ok(Some(BackendMessage::Exited(code))) => {
                        exit_code = code;
                        break;
                    }
                    Ok(Some(BackendMessage::Pong)) => {}
                    Ok(Some(BackendMessage::Error(e))) => {
                        eprintln!("\r\nbackend error: {e}\r\n");
                        exit_code = Some(1);
                        break;
                    }
                    Ok(None) => {
                        // Socket closed
                        exit_code = None;
                        break;
                    }
                    Err(e) => {
                        return Err(e.into());
                    }
                }
            }
            // SIGWINCH → resize
            _ = sigwinch.recv() => {
                if let Some((cols, rows)) = get_terminal_size() {
                    let msg = ProxyMessage::Resize { cols, rows };
                    let payload = serde_json::to_vec(&msg)?;
                    let frame = encode_frame(&payload).map_err(|e| e.to_string())?;
                    socket_writer.write_all(&frame).await?;
                }
            }
        }
    }

    Ok(exit_code)
}

async fn read_backend_message(
    reader: &mut tokio::net::unix::OwnedReadHalf,
) -> Result<Option<BackendMessage>, std::io::Error> {
    let mut header = [0u8; 4];
    match reader.read_exact(&mut header).await {
        Ok(_) => {}
        Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(e) => return Err(e),
    }

    let len =
        decode_frame_header(&header).map_err(|e| std::io::Error::other(e.to_string()))? as usize;
    let mut payload = vec![0u8; len];
    reader.read_exact(&mut payload).await?;

    let msg: BackendMessage = serde_json::from_slice(&payload)
        .map_err(|e| std::io::Error::other(format!("deserialize: {e}")))?;
    Ok(Some(msg))
}

fn exec_ssh_command(command: &str) -> ! {
    use std::os::unix::process::CommandExt;
    let err = std::process::Command::new("/bin/sh")
        .arg("-c")
        .arg(command)
        .exec();
    eprintln!("exec failed: {err}");
    std::process::exit(1);
}

/// Check whether fd 0 (stdin) refers to a terminal device.
fn stdin_is_tty() -> bool {
    #[allow(unsafe_code)]
    unsafe {
        libc::isatty(libc::STDIN_FILENO) == 1
    }
}

/// Try to enter raw mode, retrying a few times if stdin is a TTY that
/// isn't ready yet (common in embedded terminal contexts).
fn enter_raw_mode_with_retry() -> Option<RawModeGuard> {
    if !stdin_is_tty() {
        eprintln!("proxy: stdin is not a TTY, skipping raw mode");
        return None;
    }

    const MAX_ATTEMPTS: u32 = 10;
    const RETRY_DELAY_MS: u64 = 15;

    for attempt in 1..=MAX_ATTEMPTS {
        match RawModeGuard::enter() {
            Ok(guard) => return Some(guard),
            Err(e) if attempt < MAX_ATTEMPTS => {
                eprintln!(
                    "proxy: raw mode attempt {attempt}/{MAX_ATTEMPTS} failed: {e}, retrying in {RETRY_DELAY_MS}ms"
                );
                std::thread::sleep(std::time::Duration::from_millis(RETRY_DELAY_MS));
            }
            Err(e) => {
                eprintln!(
                    "proxy: could not set raw mode after {MAX_ATTEMPTS} attempts ({e}), continuing without it"
                );
            }
        }
    }
    None
}

fn get_terminal_size() -> Option<(u16, u16)> {
    // SAFETY: ioctl TIOCGWINSZ on stdout fd
    #[allow(unsafe_code)]
    unsafe {
        let mut winsize = libc::winsize {
            ws_row: 0,
            ws_col: 0,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        if libc::ioctl(libc::STDOUT_FILENO, libc::TIOCGWINSZ, &mut winsize) == 0 {
            Some((winsize.ws_col, winsize.ws_row))
        } else {
            None
        }
    }
}

/// Global storage for original terminal state, used by the panic hook
/// to restore the terminal even if the RAII guard can't run.
static ORIGINAL_TERMIOS: std::sync::Mutex<Option<libc::termios>> = std::sync::Mutex::new(None);

/// Restore terminal from the global backup. Safe to call from a panic hook.
fn restore_terminal_from_global() {
    #[allow(unsafe_code)]
    if let Ok(guard) = ORIGINAL_TERMIOS.lock() {
        if let Some(original) = guard.as_ref() {
            unsafe {
                libc::tcsetattr(libc::STDIN_FILENO, libc::TCSANOW, original);
            }
        }
    }
}

/// RAII guard that sets the terminal to raw mode and restores on drop.
struct RawModeGuard {
    original: libc::termios,
}

impl RawModeGuard {
    fn enter() -> Result<Self, std::io::Error> {
        #[allow(unsafe_code)]
        unsafe {
            let mut original: libc::termios = std::mem::zeroed();
            if libc::tcgetattr(libc::STDIN_FILENO, &mut original) != 0 {
                return Err(std::io::Error::last_os_error());
            }

            // Save globally for the panic hook
            if let Ok(mut global) = ORIGINAL_TERMIOS.lock() {
                *global = Some(original);
            }

            // Install panic hook to restore terminal
            let default_hook = std::panic::take_hook();
            std::panic::set_hook(Box::new(move |info| {
                restore_terminal_from_global();
                default_hook(info);
            }));

            let mut raw = original;
            libc::cfmakeraw(&mut raw);
            // Keep ISIG so Ctrl-C goes to the child
            raw.c_lflag |= libc::ISIG;

            if libc::tcsetattr(libc::STDIN_FILENO, libc::TCSANOW, &raw) != 0 {
                return Err(std::io::Error::last_os_error());
            }

            Ok(Self { original })
        }
    }
}

impl Drop for RawModeGuard {
    fn drop(&mut self) {
        #[allow(unsafe_code)]
        unsafe {
            libc::tcsetattr(libc::STDIN_FILENO, libc::TCSANOW, &self.original);
        }
        // Clear global backup
        if let Ok(mut global) = ORIGINAL_TERMIOS.lock() {
            *global = None;
        }
    }
}
