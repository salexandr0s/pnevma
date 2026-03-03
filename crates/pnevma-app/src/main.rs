use pnevma_app::auto_dispatch;
use pnevma_app::cost_aggregation;
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
        .plugin(tauri_plugin_updater::Builder::new().build())
        .plugin(tauri_plugin_dialog::init())
        .manage(AppState::default())
        .invoke_handler(tauri::generate_handler![
            open_project,
            close_project,
            list_recent_projects,
            trust_workspace,
            revoke_workspace_trust,
            list_trusted_workspaces,
            create_session,
            list_sessions,
            reattach_session,
            restart_session,
            send_session_input,
            resize_session,
            get_scrollback,
            restore_sessions,
            list_panes,
            upsert_pane,
            remove_pane,
            list_pane_layout_templates,
            save_pane_layout_template,
            apply_pane_layout_template,
            query_events,
            search_project,
            list_rules,
            upsert_rule,
            toggle_rule,
            delete_rule,
            list_conventions,
            upsert_convention,
            toggle_convention,
            delete_convention,
            list_rule_usage,
            get_session_timeline,
            get_session_recovery_options,
            recover_session,
            project_status,
            get_daily_brief,
            list_project_files,
            open_file_target,
            create_notification,
            list_notifications,
            mark_notification_read,
            clear_notifications,
            create_task,
            get_task,
            update_task,
            delete_task,
            list_tasks,
            run_task_checks,
            get_task_check_results,
            get_review_pack,
            approve_review,
            reject_review,
            get_task_diff,
            capture_knowledge,
            list_artifacts,
            list_merge_queue,
            move_merge_queue_item,
            merge_queue_execute,
            list_conflicts,
            resolve_conflicts_manual,
            redispatch_with_conflict_context,
            secrets_set_ref,
            secrets_list,
            checkpoint_create,
            checkpoint_list,
            checkpoint_restore,
            dispatch_task,
            list_worktrees,
            cleanup_worktree,
            get_task_cost,
            get_project_cost,
            draft_task_contract,
            list_keybindings,
            set_keybinding,
            reset_keybindings,
            get_environment_readiness,
            initialize_global_config,
            initialize_project_scaffold,
            get_onboarding_state,
            advance_onboarding_step,
            reset_onboarding,
            get_telemetry_status,
            set_telemetry_opt_in,
            export_telemetry_bundle,
            clear_telemetry,
            submit_feedback,
            partner_metrics_report,
            pool_state,
            list_workflow_defs,
            instantiate_workflow,
            list_workflow_instances,
            list_workflows,
            get_workflow,
            create_workflow,
            update_workflow,
            delete_workflow,
            dispatch_workflow,
            list_registered_commands,
            execute_registered_command,
            list_ssh_profiles,
            upsert_ssh_profile,
            delete_ssh_profile,
            import_ssh_config,
            discover_tailscale,
            connect_ssh,
            list_ssh_keys,
            generate_ssh_key,
            get_usage_breakdown,
            get_usage_by_model,
            get_usage_daily_trend,
            list_error_signatures,
            get_error_signature,
            get_error_trend,
            check_action_risk,
            list_task_stories,
            create_stories_for_task,
            update_story_status,
            get_task_story_progress,
            list_agent_profiles,
            get_dispatch_recommendation,
            override_task_profile,
            get_agent_team
        ])
        .setup(|app| {
            let window = app.get_webview_window("main").expect("main window");
            window.emit("app_ready", serde_json::json!({ "ok": true }))?;
            auto_dispatch::start_auto_dispatch(app.handle().clone());
            cost_aggregation::start_cost_aggregation(app.handle().clone());
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("tauri app failed");
}
