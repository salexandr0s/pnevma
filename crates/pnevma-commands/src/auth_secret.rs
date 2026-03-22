use std::path::{Path, PathBuf};

use secrecy::SecretString;

pub(crate) const REMOTE_KEYCHAIN_SERVICE: &str = "com.pnevma.remote-access";
pub(crate) const REMOTE_KEYCHAIN_ACCOUNT: &str = "shared-password";
pub(crate) const SOCKET_KEYCHAIN_SERVICE: &str = "com.pnevma.control-plane";
pub(crate) const SOCKET_KEYCHAIN_ACCOUNT: &str = "shared-password";

#[derive(Debug)]
enum PasswordFileError {
    NotFound,
    Insecure(String),
    Io(String),
}

impl std::fmt::Display for PasswordFileError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotFound => write!(f, "password file not found"),
            Self::Insecure(msg) | Self::Io(msg) => write!(f, "{msg}"),
        }
    }
}

pub(crate) fn remote_password_file_path() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
    PathBuf::from(home).join(".config/pnevma/remote-password")
}

pub(crate) fn load_remote_password() -> Result<Option<SecretString>, String> {
    load_password(
        "PNEVMA_REMOTE_PASSWORD",
        REMOTE_KEYCHAIN_SERVICE,
        REMOTE_KEYCHAIN_ACCOUNT,
        Some(remote_password_file_path()),
    )
}

pub(crate) fn load_socket_password(
    password_file: Option<&str>,
) -> Result<Option<SecretString>, String> {
    load_password(
        "PNEVMA_SOCKET_PASSWORD",
        SOCKET_KEYCHAIN_SERVICE,
        SOCKET_KEYCHAIN_ACCOUNT,
        password_file.map(PathBuf::from),
    )
}

fn load_password(
    env_var: &str,
    keychain_service: &str,
    keychain_account: &str,
    password_file: Option<PathBuf>,
) -> Result<Option<SecretString>, String> {
    if let Some(password) = env_password(env_var) {
        return Ok(Some(SecretString::from(password)));
    }

    if let Some(password) = read_keychain_password(keychain_service, keychain_account)? {
        return Ok(Some(SecretString::from(password)));
    }

    let Some(path) = password_file else {
        return Ok(None);
    };

    match read_password_file_secure(&path) {
        Ok(password) => Ok(Some(SecretString::from(password))),
        Err(PasswordFileError::NotFound) => Ok(None),
        Err(err) => Err(err.to_string()),
    }
}

fn env_password(name: &str) -> Option<String> {
    std::env::var(name)
        .ok()
        .map(|raw| raw.trim().to_string())
        .filter(|raw| !raw.is_empty())
}

fn read_keychain_password(service: &str, account: &str) -> Result<Option<String>, String> {
    #[cfg(target_os = "macos")]
    {
        use security_framework::passwords::get_generic_password;
        const ERR_SEC_ITEM_NOT_FOUND: i32 = -25300;

        match get_generic_password(service, account) {
            Ok(value) => {
                let value = String::from_utf8(value.to_vec()).map_err(|_| {
                    format!("Keychain item {service}/{account} contains invalid UTF-8")
                })?;
                let value = value.trim().to_string();
                if value.is_empty() {
                    return Err(format!("Keychain item {service}/{account} is empty"));
                }
                Ok(Some(value))
            }
            Err(err) if err.code() == ERR_SEC_ITEM_NOT_FOUND => Ok(None),
            Err(err) => Err(format!(
                "failed to read Keychain item {service}/{account}: {err}"
            )),
        }
    }

    #[cfg(not(target_os = "macos"))]
    {
        let _ = (service, account);
        Ok(None)
    }
}

fn read_password_file_secure(path: &Path) -> Result<String, PasswordFileError> {
    #[cfg(unix)]
    let value = {
        use std::io::Read;
        use std::os::unix::fs::OpenOptionsExt;

        let mut file = match std::fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(path)
        {
            Ok(file) => file,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
                return Err(PasswordFileError::NotFound);
            }
            Err(err) if err.raw_os_error() == Some(libc::ELOOP) => {
                return Err(PasswordFileError::Insecure(format!(
                    "password file {} must not be a symlink",
                    path.display()
                )));
            }
            Err(err) => {
                return Err(PasswordFileError::Io(format!(
                    "failed to open password file {}: {err}",
                    path.display()
                )));
            }
        };

        let meta = file.metadata().map_err(|err| {
            PasswordFileError::Io(format!(
                "failed to stat password file {}: {err}",
                path.display()
            ))
        })?;
        validate_password_file_metadata(&meta, path)?;

        let mut value = String::new();
        file.read_to_string(&mut value).map_err(|err| {
            PasswordFileError::Io(format!(
                "failed to read password file {}: {err}",
                path.display()
            ))
        })?;
        value
    };

    #[cfg(not(unix))]
    let value = {
        let meta = match std::fs::metadata(path) {
            Ok(meta) => meta,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
                return Err(PasswordFileError::NotFound);
            }
            Err(err) => {
                return Err(PasswordFileError::Io(format!(
                    "failed to stat password file {}: {err}",
                    path.display()
                )));
            }
        };
        validate_password_file_metadata(&meta, path)?;
        std::fs::read_to_string(path).map_err(|err| {
            PasswordFileError::Io(format!(
                "failed to read password file {}: {err}",
                path.display()
            ))
        })?
    };

    let value = value.trim().to_string();
    if value.is_empty() {
        return Err(PasswordFileError::Insecure(format!(
            "password file {} is empty",
            path.display()
        )));
    }
    Ok(value)
}

fn validate_password_file_metadata(
    meta: &std::fs::Metadata,
    path: &Path,
) -> Result<(), PasswordFileError> {
    if !meta.is_file() {
        return Err(PasswordFileError::Insecure(format!(
            "password file {} must be a regular file",
            path.display()
        )));
    }

    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};

        let mode = meta.permissions().mode() & 0o777;
        if mode & 0o077 != 0 {
            return Err(PasswordFileError::Insecure(format!(
                "password file {} must not be readable by group or others (current mode {:o})",
                path.display(),
                mode
            )));
        }

        let owner = meta.uid();
        let current_uid = crate::platform::current_euid();
        if owner != current_uid {
            return Err(PasswordFileError::Insecure(format!(
                "password file {} must be owned by uid {}",
                path.display(),
                current_uid
            )));
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    use std::os::unix::fs::{symlink, PermissionsExt};

    #[cfg(unix)]
    fn write_password_file(mode: u32) -> (tempfile::TempDir, PathBuf) {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("password.txt");
        std::fs::write(&path, "secret\n").expect("write password");
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(mode)).expect("set mode");
        (dir, path)
    }

    #[cfg(unix)]
    #[test]
    fn secure_password_file_is_accepted() {
        let (_dir, path) = write_password_file(0o600);
        let password = read_password_file_secure(&path).expect("password");
        assert_eq!(password, "secret");
    }

    #[cfg(unix)]
    #[test]
    fn group_readable_password_file_is_rejected() {
        let (_dir, path) = write_password_file(0o640);
        let err = read_password_file_secure(&path).expect_err("must reject");
        assert!(err.to_string().contains("group or others"));
    }

    #[cfg(unix)]
    #[test]
    fn symlink_password_file_is_rejected() {
        let dir = tempfile::tempdir().expect("tempdir");
        let target = dir.path().join("target.txt");
        let link = dir.path().join("link.txt");
        std::fs::write(&target, "secret\n").expect("write target");
        symlink(&target, &link).expect("symlink");
        let err = read_password_file_secure(&link).expect_err("must reject symlink");
        assert!(err.to_string().contains("must not be a symlink"));
    }

    #[cfg(unix)]
    #[test]
    fn missing_password_file_returns_not_found() {
        let dir = tempfile::tempdir().expect("tempdir");
        let err =
            read_password_file_secure(&dir.path().join("missing.txt")).expect_err("missing file");
        assert!(matches!(err, PasswordFileError::NotFound));
    }

    #[test]
    #[allow(unsafe_code)]
    fn env_password_trims_whitespace() {
        let key = "PNEVMA_TEST_ENV_PASSWORD";
        // Safety: test-only, single-threaded test, unique env var name
        unsafe { std::env::set_var(key, "  secret  ") };
        let password = env_password(key).expect("env password");
        unsafe { std::env::remove_var(key) };
        assert_eq!(password, "secret");
    }

    #[cfg(unix)]
    #[test]
    fn world_readable_password_file_is_rejected() {
        let (_dir, path) = write_password_file(0o604);
        let err = read_password_file_secure(&path).expect_err("must reject world-readable");
        assert!(err.to_string().contains("group or others"));
    }

    #[cfg(unix)]
    #[test]
    fn empty_password_file_returns_error() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("empty.txt");
        std::fs::write(&path, "").expect("write");
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).expect("chmod");
        let err = read_password_file_secure(&path).expect_err("must reject empty");
        assert!(err.to_string().contains("empty"));
    }

    #[cfg(unix)]
    #[test]
    fn directory_path_is_rejected() {
        let dir = tempfile::tempdir().expect("tempdir");
        let subdir = dir.path().join("not-a-file");
        std::fs::create_dir(&subdir).expect("mkdir");
        std::fs::set_permissions(&subdir, std::fs::Permissions::from_mode(0o700)).expect("chmod");
        let err = read_password_file_secure(&subdir).expect_err("must reject directory");
        assert!(err.to_string().contains("regular file"));
    }

    #[test]
    fn debug_impl_redacts_password() {
        use crate::control::ControlAuthMode;
        use secrecy::SecretString;
        let mode = ControlAuthMode::Password {
            password: SecretString::from("super-secret-password"),
        };
        let debug_output = format!("{:?}", mode);
        assert!(
            debug_output.contains("[REDACTED]"),
            "debug output must contain [REDACTED], got: {debug_output}"
        );
        assert!(
            !debug_output.contains("super-secret-password"),
            "debug output must NOT contain the actual password"
        );
    }

    #[test]
    fn password_not_in_debug_output_env_sourced() {
        use crate::control::ControlAuthMode;
        use secrecy::SecretString;
        let env_password_value = "env-sourced-secret-42";
        let mode = ControlAuthMode::Password {
            password: SecretString::from(env_password_value),
        };
        let debug_output = format!("{:?}", mode);
        assert!(
            !debug_output.contains(env_password_value),
            "debug output must NOT contain the env-sourced password"
        );
    }
}
