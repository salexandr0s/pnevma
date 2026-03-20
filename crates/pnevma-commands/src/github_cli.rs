use std::{
    ffi::{OsStr, OsString},
    path::PathBuf,
};

use tokio::process::Command as TokioCommand;

const GH_FALLBACK_PATHS: &[&str] = &["/opt/homebrew/bin/gh", "/usr/local/bin/gh"];

pub(crate) fn command() -> TokioCommand {
    let mut command = TokioCommand::new(resolve_github_cli_binary());
    command.env("PATH", github_cli_path());
    command
}

fn resolve_github_cli_binary() -> PathBuf {
    #[cfg(test)]
    if let Some(path) = test_github_cli_binary_override() {
        return path;
    }

    resolve_github_cli_binary_from(
        std::env::var_os("PATH"),
        GH_FALLBACK_PATHS.iter().map(PathBuf::from),
    )
}

fn resolve_github_cli_binary_from<I>(path_var: Option<OsString>, fallback_candidates: I) -> PathBuf
where
    I: IntoIterator<Item = PathBuf>,
{
    if let Some(path) = find_binary_on_path("gh", path_var.as_deref()) {
        return path;
    }

    fallback_candidates
        .into_iter()
        .find(|path| path.is_file())
        .unwrap_or_else(|| PathBuf::from("gh"))
}

fn find_binary_on_path(binary: &str, path_var: Option<&OsStr>) -> Option<PathBuf> {
    let path_var = path_var?;
    std::env::split_paths(path_var)
        .map(|dir| dir.join(binary))
        .find(|candidate| candidate.is_file())
}

fn github_cli_path() -> String {
    compose_github_cli_path(std::env::var_os("PATH"))
}

fn compose_github_cli_path(current_path: Option<OsString>) -> String {
    let mut segments = vec![
        "/opt/homebrew/bin".to_string(),
        "/usr/local/bin".to_string(),
        "/usr/bin".to_string(),
        "/bin".to_string(),
        "/usr/sbin".to_string(),
        "/sbin".to_string(),
    ];
    if let Some(current_path) = current_path {
        segments.extend(std::env::split_paths(&current_path).filter_map(|path| {
            let text = path.to_string_lossy().trim().to_string();
            (!text.is_empty()).then_some(text)
        }));
    }

    let mut seen = std::collections::HashSet::new();
    segments
        .into_iter()
        .filter(|segment| seen.insert(segment.clone()))
        .collect::<Vec<_>>()
        .join(":")
}

#[cfg(test)]
fn test_github_cli_binary_override() -> Option<PathBuf> {
    test_github_cli_binary_override_cell()
        .read()
        .expect("read github cli test override")
        .clone()
}

#[cfg(test)]
fn test_github_cli_binary_override_cell() -> &'static std::sync::RwLock<Option<PathBuf>> {
    static OVERRIDE: std::sync::OnceLock<std::sync::RwLock<Option<PathBuf>>> =
        std::sync::OnceLock::new();
    OVERRIDE.get_or_init(|| std::sync::RwLock::new(None))
}

#[cfg(test)]
fn test_github_cli_override_lock() -> &'static std::sync::Mutex<()> {
    static LOCK: std::sync::OnceLock<std::sync::Mutex<()>> = std::sync::OnceLock::new();
    LOCK.get_or_init(|| std::sync::Mutex::new(()))
}

#[cfg(test)]
pub(crate) struct TestGithubCliBinaryOverride {
    previous: Option<PathBuf>,
    _guard: std::sync::MutexGuard<'static, ()>,
}

#[cfg(test)]
impl TestGithubCliBinaryOverride {
    pub(crate) fn new(path: PathBuf) -> Self {
        let guard = test_github_cli_override_lock()
            .lock()
            .expect("lock github cli test override");
        let previous = test_github_cli_binary_override_cell()
            .write()
            .expect("write github cli test override")
            .replace(path);
        Self {
            previous,
            _guard: guard,
        }
    }
}

#[cfg(test)]
impl Drop for TestGithubCliBinaryOverride {
    fn drop(&mut self) {
        *test_github_cli_binary_override_cell()
            .write()
            .expect("restore github cli test override") = self.previous.take();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{fs, os::unix::fs::PermissionsExt, path::Path};
    use tempfile::tempdir;

    fn create_fake_binary(dir: &Path, name: &str) -> PathBuf {
        let path = dir.join(name);
        fs::write(&path, b"#!/bin/sh\nexit 0\n").unwrap();
        let mut permissions = fs::metadata(&path).unwrap().permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&path, permissions).unwrap();
        path
    }

    #[test]
    fn resolve_github_cli_binary_prefers_path_entry() {
        let temp = tempdir().unwrap();
        let gh = create_fake_binary(temp.path(), "gh");
        let resolved = resolve_github_cli_binary_from(
            Some(std::env::join_paths([temp.path()]).unwrap()),
            std::iter::empty(),
        );
        assert_eq!(resolved, gh);
    }

    #[test]
    fn resolve_github_cli_binary_uses_fallback_candidate() {
        let temp = tempdir().unwrap();
        let gh = create_fake_binary(temp.path(), "gh");
        let resolved = resolve_github_cli_binary_from(None, std::iter::once(gh.clone()));
        assert_eq!(resolved, gh);
    }

    #[test]
    fn compose_github_cli_path_includes_homebrew_once() {
        let path = compose_github_cli_path(Some(OsString::from("/usr/bin:/opt/homebrew/bin:/bin")));
        let segments: Vec<&str> = path.split(':').collect();
        assert_eq!(
            segments
                .iter()
                .filter(|segment| **segment == "/opt/homebrew/bin")
                .count(),
            1
        );
        assert!(segments.contains(&"/usr/bin"));
        assert!(segments.contains(&"/bin"));
    }
}
