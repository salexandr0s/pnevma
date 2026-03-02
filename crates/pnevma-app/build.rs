fn main() {
    if cfg!(target_os = "macos") {
        let tmp = std::env::var("TMPDIR")
            .ok()
            .filter(|v| !v.trim().is_empty())
            .or_else(|| {
                std::env::var("DARWIN_USER_TEMP_DIR")
                    .ok()
                    .filter(|v| !v.trim().is_empty())
            })
            .unwrap_or_else(|| "/tmp".to_string());

        if std::env::var_os("TMPDIR").is_none() {
            std::env::set_var("TMPDIR", &tmp);
        }
        if std::env::var_os("DARWIN_USER_TEMP_DIR").is_none() {
            std::env::set_var("DARWIN_USER_TEMP_DIR", &tmp);
        }
    }

    tauri_build::build()
}
