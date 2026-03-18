use super::*;

#[test]
fn app_settings_view_uses_defaults_for_empty_optional_fields() {
    let view = app_settings_view_from_config(&GlobalConfig::default());
    assert_eq!(view.default_shell, "");
    assert!(!view.bottom_tool_bar_auto_hide);
    assert_eq!(view.focus_border_color, "accent");
    assert!(!view.keybindings.is_empty());
}

#[tokio::test]
async fn get_app_settings_defaults_bottom_tool_bar_auto_hide_to_false() {
    let temp = tempfile::tempdir().expect("tempdir");
    let _home = HomeOverride::new(temp.path()).await;

    save_global_config(&GlobalConfig::default()).expect("save initial config");

    let emitter: Arc<dyn EventEmitter> = Arc::new(NullEmitter);
    let state = AppState::new(emitter);

    let settings = get_app_settings(&state).await.expect("get app settings");
    assert!(!settings.bottom_tool_bar_auto_hide);
}

#[tokio::test]
async fn set_app_settings_round_trips_and_preserves_other_global_fields() {
    let temp = tempfile::tempdir().expect("tempdir");
    let _home = HomeOverride::new(temp.path()).await;

    let mut initial = GlobalConfig {
        default_provider: Some("claude-code".to_string()),
        theme: Some("solarized".to_string()),
        socket_auth_mode: Some("same-user".to_string()),
        ..GlobalConfig::default()
    };
    initial
        .keybindings
        .insert("menu.split_right".to_string(), "Cmd+Shift+R".to_string());
    save_global_config(&initial).expect("save initial config");

    let emitter: Arc<dyn EventEmitter> = Arc::new(NullEmitter);
    let state = AppState::new(emitter);
    let updated = set_app_settings(
        SetAppSettingsInput {
            auto_save_workspace_on_quit: false,
            restore_windows_on_launch: false,
            auto_update: false,
            default_shell: "/bin/bash".to_string(),
            terminal_font: "JetBrains Mono".to_string(),
            terminal_font_size: 14,
            scrollback_lines: 20_000,
            sidebar_background_offset: 0.1,
            bottom_tool_bar_auto_hide: true,
            focus_border_enabled: false,
            focus_border_opacity: 0.5,
            focus_border_width: 3.0,
            focus_border_color: "#336699".to_string(),
            telemetry_enabled: true,
            crash_reports: true,
            keybindings: None,
        },
        &state,
    )
    .await
    .expect("set app settings");

    assert_eq!(updated.default_shell, "/bin/bash");
    assert_eq!(updated.terminal_font, "JetBrains Mono");
    assert!(updated.bottom_tool_bar_auto_hide);
    assert_eq!(updated.focus_border_color, "#336699");
    assert!(updated.telemetry_enabled);
    assert!(updated.crash_reports);

    let reloaded = load_global_config().expect("reload config");
    assert_eq!(reloaded.default_provider.as_deref(), Some("claude-code"));
    assert_eq!(reloaded.theme.as_deref(), Some("solarized"));
    assert_eq!(reloaded.socket_auth_mode.as_deref(), Some("same-user"));
    assert_eq!(
        reloaded
            .keybindings
            .get("menu.split_right")
            .map(String::as_str),
        Some("Cmd+Shift+R")
    );
    assert_eq!(reloaded.default_shell.as_deref(), Some("/bin/bash"));
    assert_eq!(reloaded.terminal_font, "JetBrains Mono");
    assert_eq!(reloaded.terminal_font_size, 14);
    assert_eq!(reloaded.scrollback_lines, 20_000);
    assert_eq!(reloaded.sidebar_background_offset, 0.1);
    assert!(reloaded.bottom_tool_bar_auto_hide);
    assert!(!reloaded.focus_border_enabled);
    assert_eq!(reloaded.focus_border_opacity, 0.5);
    assert_eq!(reloaded.focus_border_width, 3.0);
    assert_eq!(reloaded.focus_border_color.as_deref(), Some("#336699"));
    assert!(reloaded.telemetry_opt_in);
    assert!(reloaded.crash_reports_opt_in);
}

#[tokio::test]
async fn set_app_settings_persists_keybinding_overrides() {
    let temp = tempfile::tempdir().expect("tempdir");
    let _home = HomeOverride::new(temp.path()).await;
    let initial = GlobalConfig::default();
    save_global_config(&initial).expect("save initial config");

    let emitter: Arc<dyn EventEmitter> = Arc::new(NullEmitter);
    let state = AppState::new(emitter);

    // Set an override
    let updated = set_app_settings(
        SetAppSettingsInput {
            auto_save_workspace_on_quit: true,
            restore_windows_on_launch: true,
            auto_update: true,
            default_shell: "".to_string(),
            terminal_font: "SF Mono".to_string(),
            terminal_font_size: 13,
            scrollback_lines: 10_000,
            sidebar_background_offset: 0.05,
            bottom_tool_bar_auto_hide: false,
            focus_border_enabled: true,
            focus_border_opacity: 0.4,
            focus_border_width: 2.0,
            focus_border_color: "accent".to_string(),
            telemetry_enabled: false,
            crash_reports: false,
            keybindings: Some(vec![KeybindingOverride {
                action: "menu.split_right".to_string(),
                shortcut: "Cmd+Shift+R".to_string(),
            }]),
        },
        &state,
    )
    .await
    .expect("set app settings with override");

    // Verify the override is reflected in the view
    let split_right = updated
        .keybindings
        .iter()
        .find(|k| k.action == "menu.split_right")
        .expect("menu.split_right should exist");
    assert_eq!(split_right.shortcut, "Cmd+Shift+R");
    assert!(!split_right.is_default);

    // Verify it persisted to disk
    let reloaded = load_global_config().expect("reload config");
    assert_eq!(
        reloaded
            .keybindings
            .get("menu.split_right")
            .map(String::as_str),
        Some("Cmd+Shift+R")
    );

    // Now clear all overrides by sending an empty array
    let cleared = set_app_settings(
        SetAppSettingsInput {
            auto_save_workspace_on_quit: true,
            restore_windows_on_launch: true,
            auto_update: true,
            default_shell: "".to_string(),
            terminal_font: "SF Mono".to_string(),
            terminal_font_size: 13,
            scrollback_lines: 10_000,
            sidebar_background_offset: 0.05,
            bottom_tool_bar_auto_hide: false,
            focus_border_enabled: true,
            focus_border_opacity: 0.4,
            focus_border_width: 2.0,
            focus_border_color: "accent".to_string(),
            telemetry_enabled: false,
            crash_reports: false,
            keybindings: Some(vec![]),
        },
        &state,
    )
    .await
    .expect("set app settings with empty overrides");

    // Verify it reverted to defaults
    let split_right = cleared
        .keybindings
        .iter()
        .find(|k| k.action == "menu.split_right")
        .expect("menu.split_right should exist");
    assert_eq!(split_right.shortcut, "Cmd+D");
    assert!(split_right.is_default);

    // Verify overrides cleared on disk
    let reloaded = load_global_config().expect("reload after clear");
    assert!(reloaded.keybindings.is_empty());
}

#[tokio::test]
async fn set_app_settings_persists_bottom_tool_bar_auto_hide() {
    let temp = tempfile::tempdir().expect("tempdir");
    let _home = HomeOverride::new(temp.path()).await;
    save_global_config(&GlobalConfig::default()).expect("save initial config");

    let emitter: Arc<dyn EventEmitter> = Arc::new(NullEmitter);
    let state = AppState::new(emitter);

    let updated = set_app_settings(
        SetAppSettingsInput {
            auto_save_workspace_on_quit: true,
            restore_windows_on_launch: true,
            auto_update: true,
            default_shell: "".to_string(),
            terminal_font: "SF Mono".to_string(),
            terminal_font_size: 13,
            scrollback_lines: 10_000,
            sidebar_background_offset: 0.05,
            bottom_tool_bar_auto_hide: true,
            focus_border_enabled: true,
            focus_border_opacity: 0.4,
            focus_border_width: 2.0,
            focus_border_color: "accent".to_string(),
            telemetry_enabled: false,
            crash_reports: false,
            keybindings: None,
        },
        &state,
    )
    .await
    .expect("set app settings");

    assert!(updated.bottom_tool_bar_auto_hide);

    let reloaded = load_global_config().expect("reload config");
    assert!(reloaded.bottom_tool_bar_auto_hide);
}

#[tokio::test]
async fn set_app_settings_rejects_protected_keybinding_overrides() {
    let temp = tempfile::tempdir().expect("tempdir");
    let _home = HomeOverride::new(temp.path()).await;
    let initial = GlobalConfig::default();
    save_global_config(&initial).expect("save initial config");

    let emitter: Arc<dyn EventEmitter> = Arc::new(NullEmitter);
    let state = AppState::new(emitter);

    let _ = set_app_settings(
        SetAppSettingsInput {
            auto_save_workspace_on_quit: true,
            restore_windows_on_launch: true,
            auto_update: true,
            default_shell: "".to_string(),
            terminal_font: "SF Mono".to_string(),
            terminal_font_size: 13,
            scrollback_lines: 10_000,
            sidebar_background_offset: 0.05,
            bottom_tool_bar_auto_hide: false,
            focus_border_enabled: true,
            focus_border_opacity: 0.4,
            focus_border_width: 2.0,
            focus_border_color: "accent".to_string(),
            telemetry_enabled: false,
            crash_reports: false,
            keybindings: Some(vec![KeybindingOverride {
                action: "menu.quit".to_string(),
                shortcut: "Cmd+Shift+Q".to_string(),
            }]),
        },
        &state,
    )
    .await
    .expect("set protected keybinding");

    // Protected action should NOT be persisted
    let reloaded = load_global_config().expect("reload config");
    assert!(!reloaded.keybindings.contains_key("menu.quit"));
}

#[test]
fn default_keybindings_have_no_unexpected_shortcut_conflicts() {
    // pane.focus_next/prev share shortcuts with menu.next_pane/previous_pane
    // intentionally — they're the same action exposed at two layers.
    let allowed_pairs: HashSet<(&str, &str)> = HashSet::from([
        ("pane.focus_next", "menu.next_pane"),
        ("menu.next_pane", "pane.focus_next"),
        ("pane.focus_prev", "menu.previous_pane"),
        ("menu.previous_pane", "pane.focus_prev"),
    ]);

    let defaults = default_keybindings();
    let mut shortcut_to_actions: HashMap<String, Vec<String>> = HashMap::new();
    for (action, shortcut) in defaults.iter() {
        let normalized = normalize_shortcut(shortcut);
        shortcut_to_actions
            .entry(normalized)
            .or_default()
            .push(action.clone());
    }
    for (shortcut, actions) in &shortcut_to_actions {
        if actions.len() <= 1 {
            continue;
        }
        let all_allowed = actions.iter().all(|a| {
            actions
                .iter()
                .filter(|b| *b != a)
                .all(|b| allowed_pairs.contains(&(a.as_str(), b.as_str())))
        });
        assert!(
            all_allowed,
            "Unexpected default shortcut conflict: {shortcut} is used by: {actions:?}"
        );
    }
}
