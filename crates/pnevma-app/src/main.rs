use pnevma_app::commands::*;
use pnevma_app::state::AppState;
use tauri::{Emitter, Manager};
use tracing_subscriber::layer::SubscriberExt;
use tracing_subscriber::util::SubscriberInitExt;

static LOG_GUARD: std::sync::OnceLock<tracing_appender::non_blocking::WorkerGuard> =
    std::sync::OnceLock::new();

fn init_tracing() {
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
    let log_dir = std::path::PathBuf::from(home).join(".local/share/pnevma/logs");
    let _ = std::fs::create_dir_all(&log_dir);
    let appender = tracing_appender::rolling::daily(log_dir, "pnevma.json.log");
    let (non_blocking, guard) = tracing_appender::non_blocking(appender);
    let _ = LOG_GUARD.set(guard);

    let env = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("pnevma_app=info,pnevma_core=info"));
    let file_layer = tracing_subscriber::fmt::layer()
        .json()
        .with_writer(non_blocking);
    let console_layer = tracing_subscriber::fmt::layer();
    tracing_subscriber::registry()
        .with(env)
        .with(file_layer)
        .with(console_layer)
        .init();
}

fn main() {
    init_tracing();

    tauri::Builder::default()
        .manage(AppState::default())
        .invoke_handler(tauri::generate_handler![
            open_project,
            close_project,
            list_recent_projects,
            create_session,
            list_sessions,
            reattach_session,
            restart_session,
            send_session_input,
            get_scrollback,
            restore_sessions,
            list_panes,
            upsert_pane,
            remove_pane,
            query_events,
            project_status,
            create_notification,
            create_task,
            get_task,
            update_task,
            delete_task,
            list_tasks,
            dispatch_task,
            list_worktrees,
            cleanup_worktree,
            get_task_cost,
            get_project_cost,
            pool_state,
            list_registered_commands,
            execute_registered_command
        ])
        .setup(|app| {
            let window = app.get_webview_window("main").expect("main window");
            window.emit("app_ready", serde_json::json!({ "ok": true }))?;
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("tauri app failed");
}
