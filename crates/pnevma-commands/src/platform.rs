/// Returns the effective user ID of the calling process.
#[allow(unsafe_code)]
pub fn current_euid() -> u32 {
    // SAFETY: geteuid() is a read-only system call with no preconditions.
    (unsafe { libc::geteuid() }) as u32
}

/// Check whether a process with the given PID is alive.
/// Sends signal 0 (no actual signal) to probe process existence.
#[allow(unsafe_code)]
pub fn process_alive(pid: libc::pid_t) -> bool {
    // SAFETY: kill(pid, 0) is a read-only probe with no side effects.
    let result = unsafe { libc::kill(pid, 0) };
    if result == 0 {
        return true;
    }
    matches!(
        std::io::Error::last_os_error().raw_os_error(),
        Some(libc::EPERM)
    )
}

/// Verify that `pid` still belongs to an expected pnevma-managed process
/// (tmux or pnevma binary) using `proc_pidpath`. Guards against PID
/// recycling races.
#[cfg(target_os = "macos")]
#[allow(unsafe_code)]
pub fn verify_pid_identity(pid: libc::pid_t) -> bool {
    extern "C" {
        fn proc_pidpath(
            pid: libc::c_int,
            buffer: *mut libc::c_char,
            buffersize: u32,
        ) -> libc::c_int;
    }
    let mut buf = [0u8; libc::PATH_MAX as usize];
    // SAFETY: proc_pidpath is a macOS system call that writes at most buffersize bytes.
    let ret = unsafe { proc_pidpath(pid, buf.as_mut_ptr() as *mut libc::c_char, buf.len() as u32) };
    if ret <= 0 {
        // Cannot determine path — treat as stale to be safe.
        return false;
    }
    let path = String::from_utf8_lossy(&buf[..ret as usize]);
    let binary_name = path.rsplit('/').next().unwrap_or("");
    let is_known = binary_name.starts_with("tmux") || binary_name.starts_with("pnevma");
    #[cfg(test)]
    let is_known = is_known
        || binary_name == "sleep"
        || binary_name == "cat"
        || binary_name == "sh"
        || binary_name == "bash"
        || binary_name == "zsh";
    is_known
}

/// Fallback for non-macOS: skip identity verification.
#[cfg(not(target_os = "macos"))]
pub fn verify_pid_identity(_pid: libc::pid_t) -> bool {
    true
}

/// Send SIGTERM to a process.
#[allow(unsafe_code)]
pub fn send_sigterm(pid: libc::pid_t) {
    // SAFETY: libc::kill with SIGTERM is a standard POSIX signal send.
    let _ = unsafe { libc::kill(pid, libc::SIGTERM) };
}

/// Send SIGKILL to a process.
#[allow(unsafe_code)]
pub fn send_sigkill(pid: libc::pid_t) {
    // SAFETY: libc::kill with SIGKILL is a standard POSIX signal send.
    let _ = unsafe { libc::kill(pid, libc::SIGKILL) };
}
