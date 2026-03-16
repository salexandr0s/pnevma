use super::*;
use chrono::{DateTime, TimeZone, Utc};
use pnevma_core::config::UsageProviderConfig;
use pnevma_session::resolve_binary;
use reqwest::header::{HeaderMap, HeaderValue, AUTHORIZATION};
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::process::Command;
use std::sync::{Mutex as StdMutex, OnceLock};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

const PROVIDER_USAGE_KEYCHAIN_SERVICE: &str = "com.pnevma.usage-providers";
const CODEX_MANUAL_COOKIE_ACCOUNT: &str = "codex-manual-cookie";
const CLAUDE_MANUAL_COOKIE_ACCOUNT: &str = "claude-manual-cookie";
const PROVIDER_CACHE_TTL_SECS: i64 = 120;
const CLAUDE_LIVE_FALLBACK_TTL_SECS: i64 = 21_600;
const CODEX_RATE_LIMITS_GRACE_MS: u64 = 2_500;

/// Minimum seconds of remaining validity to consider a Claude OAuth token usable.
const CLAUDE_TOKEN_EXPIRY_MARGIN_SECS: i64 = 60;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProviderUsageOverviewInput {
    #[serde(default)]
    pub force_refresh: bool,
    #[serde(default = "default_local_usage_days")]
    pub local_usage_days: u32,
}

fn default_local_usage_days() -> u32 {
    30
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProviderUsageOverviewView {
    pub generated_at: DateTime<Utc>,
    pub refresh_interval_seconds: u64,
    pub stale_after_seconds: u64,
    pub providers: Vec<ProviderUsageSnapshotView>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProviderUsageSnapshotView {
    pub provider: String,
    pub display_name: String,
    pub status: String,
    pub status_message: Option<String>,
    pub repair_hint: Option<String>,
    pub source: String,
    pub account_email: Option<String>,
    pub plan_label: Option<String>,
    pub last_refreshed_at: DateTime<Utc>,
    pub session_window: Option<ProviderQuotaWindowView>,
    pub weekly_window: Option<ProviderQuotaWindowView>,
    pub model_windows: Vec<ProviderQuotaWindowView>,
    pub credit: Option<ProviderCreditView>,
    pub local_usage: ProviderLocalUsageSummaryView,
    pub dashboard_extras: Option<ProviderDashboardExtrasView>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProviderQuotaWindowView {
    pub label: String,
    pub percent_used: Option<f64>,
    pub percent_remaining: Option<f64>,
    pub reset_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProviderCreditView {
    pub label: String,
    pub balance_display: Option<String>,
    pub is_unlimited: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProviderLocalUsageSummaryView {
    pub requests: i64,
    pub input_tokens: i64,
    pub output_tokens: i64,
    pub total_tokens: i64,
    pub top_model: Option<String>,
    pub peak_day: Option<String>,
    pub peak_day_tokens: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProviderDashboardExtrasView {
    pub warning: Option<String>,
    pub code_review_remaining_percent: Option<f64>,
    pub purchase_url: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProviderUsageSettingsView {
    pub refresh_interval_seconds: u64,
    pub codex: ProviderUsageProviderSettingsView,
    pub claude: ProviderUsageProviderSettingsView,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProviderUsageProviderSettingsView {
    pub source: String,
    pub web_extras_enabled: bool,
    pub keychain_prompt_policy: String,
    pub manual_cookie_configured: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SetProviderUsageSettingsInput {
    pub refresh_interval_seconds: u64,
    pub codex: SetProviderUsageProviderSettingsInput,
    pub claude: SetProviderUsageProviderSettingsInput,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SetProviderUsageProviderSettingsInput {
    pub source: String,
    pub web_extras_enabled: bool,
    pub keychain_prompt_policy: String,
    pub manual_cookie_value: Option<String>,
    #[serde(default)]
    pub clear_manual_cookie: bool,
}

#[derive(Debug, Clone)]
struct CachedSnapshot {
    cached_at: DateTime<Utc>,
    snapshot: ProviderUsageSnapshotView,
}

#[derive(Default)]
struct ProviderUsageCache {
    snapshots: HashMap<String, CachedSnapshot>,
}

static PROVIDER_USAGE_CACHE: OnceLock<StdMutex<ProviderUsageCache>> = OnceLock::new();

#[derive(Debug, Clone)]
struct ProviderProbeOutput {
    source: String,
    account_email: Option<String>,
    plan_label: Option<String>,
    status_message: Option<String>,
    repair_hint: Option<String>,
    session_window: Option<ProviderQuotaWindowView>,
    weekly_window: Option<ProviderQuotaWindowView>,
    model_windows: Vec<ProviderQuotaWindowView>,
    credit: Option<ProviderCreditView>,
}

pub async fn get_provider_usage_overview(
    input: ProviderUsageOverviewInput,
    state: &AppState,
) -> Result<ProviderUsageOverviewView, String> {
    let local_usage_days = input.local_usage_days.clamp(1, 90);
    let config = load_effective_global_config_for_providers(state).await?;
    let refresh_interval_seconds = config.usage_providers.refresh_interval_seconds;

    let codex_key = format!("codex:{local_usage_days}");
    let claude_key = format!("claude:{local_usage_days}");
    let now = Utc::now();

    let codex_cached = cached_snapshot(&codex_key, now, input.force_refresh);
    let claude_cached = cached_snapshot(&claude_key, now, input.force_refresh);

    let codex_future = async {
        if let Some(snapshot) = codex_cached {
            Ok(snapshot)
        } else {
            let snapshot = finalize_provider_snapshot(
                "codex",
                &codex_key,
                now,
                probe_provider_snapshot("codex", &config.usage_providers.codex, local_usage_days)
                    .await,
            );
            if snapshot.status == "ok" {
                cache_snapshot(&codex_key, snapshot.clone());
            }
            Ok::<_, String>(snapshot)
        }
    };
    let claude_future = async {
        if let Some(snapshot) = claude_cached {
            Ok(snapshot)
        } else {
            let snapshot = finalize_provider_snapshot(
                "claude",
                &claude_key,
                now,
                probe_provider_snapshot("claude", &config.usage_providers.claude, local_usage_days)
                    .await,
            );
            if snapshot.status == "ok" {
                cache_snapshot(&claude_key, snapshot.clone());
            }
            Ok::<_, String>(snapshot)
        }
    };

    let (codex, claude) = tokio::join!(codex_future, claude_future);
    let overview = ProviderUsageOverviewView {
        generated_at: now,
        refresh_interval_seconds,
        stale_after_seconds: PROVIDER_CACHE_TTL_SECS as u64,
        providers: vec![codex?, claude?],
    };
    state.emitter.emit(
        "provider_usage_updated",
        json!({
            "generated_at": overview.generated_at,
            "providers": overview.providers.iter().map(|item| {
                json!({
                    "provider": item.provider,
                    "status": item.status,
                    "source": item.source,
                })
            }).collect::<Vec<_>>()
        }),
    );
    Ok(overview)
}

pub async fn get_provider_usage_settings(
    state: &AppState,
) -> Result<ProviderUsageSettingsView, String> {
    let config = load_effective_global_config_for_providers(state).await?;
    Ok(provider_usage_settings_from_config(&config).await)
}

pub async fn set_provider_usage_settings(
    input: SetProviderUsageSettingsInput,
    state: &AppState,
) -> Result<ProviderUsageSettingsView, String> {
    if !(30..=900).contains(&input.refresh_interval_seconds) {
        return Err("refresh_interval_seconds must be between 30 and 900".to_string());
    }
    let mut config = load_effective_global_config_for_providers(state).await?;

    config.usage_providers.refresh_interval_seconds = input.refresh_interval_seconds;
    config.usage_providers.codex = map_usage_provider_input(&input.codex)?;
    config.usage_providers.claude = map_usage_provider_input(&input.claude)?;

    save_manual_cookie_value(CODEX_MANUAL_COOKIE_ACCOUNT, &input.codex).await?;
    save_manual_cookie_value(CLAUDE_MANUAL_COOKIE_ACCOUNT, &input.claude).await?;

    save_global_config(&config).map_err(|e| e.to_string())?;

    let mut current = state.current.lock().await;
    if let Some(ctx) = current.as_mut() {
        ctx.global_config = config.clone();
    }

    Ok(provider_usage_settings_from_config(&config).await)
}

async fn probe_provider_snapshot(
    provider: &str,
    config: &UsageProviderConfig,
    local_usage_days: u32,
) -> ProviderUsageSnapshotView {
    let local_usage = build_local_usage_summary(provider, local_usage_days).await;
    let now = Utc::now();
    let display_name = match provider {
        "codex" => "Codex",
        "claude" => "Claude",
        _ => provider,
    }
    .to_string();

    let live_result = match provider {
        "codex" => probe_codex(config).await,
        "claude" => probe_claude(config).await,
        _ => Err("unsupported provider".to_string()),
    };

    match live_result {
        Ok(output) => ProviderUsageSnapshotView {
            provider: provider.to_string(),
            display_name,
            status: if output.status_message.is_some() {
                "warning".to_string()
            } else {
                "ok".to_string()
            },
            status_message: output.status_message,
            repair_hint: output.repair_hint,
            source: output.source,
            account_email: output.account_email,
            plan_label: output.plan_label,
            last_refreshed_at: now,
            session_window: output.session_window,
            weekly_window: output.weekly_window,
            model_windows: output.model_windows,
            credit: output.credit,
            local_usage,
            dashboard_extras: None,
        },
        Err(message) => {
            let status = if local_usage.total_tokens > 0 || local_usage.requests > 0 {
                "warning"
            } else {
                "error"
            };
            ProviderUsageSnapshotView {
                provider: provider.to_string(),
                display_name,
                status: status.to_string(),
                status_message: Some(message.clone()),
                repair_hint: Some(repair_hint_for_provider(provider, &message)),
                source: "local".to_string(),
                account_email: None,
                plan_label: None,
                last_refreshed_at: now,
                session_window: None,
                weekly_window: None,
                model_windows: vec![],
                credit: None,
                local_usage,
                dashboard_extras: None,
            }
        }
    }
}

fn repair_hint_for_provider(provider: &str, message: &str) -> String {
    let lower = message.to_lowercase();
    if lower.contains("not found") || lower.contains("no such file") {
        return format!("Install or sign in to the {provider} CLI on this Mac.");
    }
    if lower.contains("401") || lower.contains("403") || lower.contains("unauthorized") {
        return format!("Refresh the {provider} credentials and try again.");
    }
    if lower.contains("429") || lower.contains("rate limit") {
        return format!(
            "The {provider} live usage endpoint is rate-limiting requests. Pnevma will retry later."
        );
    }
    if lower.contains("timeout") {
        return format!("The {provider} probe timed out. Open the CLI once, then retry.");
    }
    format!("Pnevma fell back to local {provider} session usage only.")
}

async fn probe_codex(config: &UsageProviderConfig) -> Result<ProviderProbeOutput, String> {
    if config.source == "local" {
        return Err("Codex source is set to local usage only.".to_string());
    }

    // Try direct OAuth probe first (no CLI spawn, no notification sounds)
    if config.source == "oauth" || config.source == "auto" {
        match probe_codex_oauth().await {
            Ok(output) => return Ok(output),
            Err(error) => {
                tracing::debug!("Codex OAuth probe failed, falling back to CLI: {error}");
                if config.source == "oauth" {
                    return Err(error);
                }
            }
        }
    }

    let output = probe_codex_cli_rpc().await?;
    let account_email = output.account.as_ref().and_then(|account| {
        extract_string_at_paths(
            account,
            &[
                &["email"],
                &["account", "email"],
                &["user", "email"],
                &["profile", "email"],
            ],
        )
    });
    let plan_label = output.account.as_ref().and_then(|account| {
        extract_string_at_paths(
            account,
            &[
                &["plan"],
                &["planType"],
                &["plan", "name"],
                &["billing", "plan"],
                &["subscription", "plan"],
                &["account", "planType"],
                &["account", "plan"],
            ],
        )
    });
    let codex_usage = output
        .rate_limits
        .as_ref()
        .map(normalize_codex_rate_limits)
        .unwrap_or_default();
    if account_email.is_none()
        && plan_label.is_none()
        && codex_usage.session_window.is_none()
        && codex_usage.weekly_window.is_none()
        && codex_usage.model_windows.is_empty()
        && codex_usage.credit.is_none()
    {
        if let Some(message) = output.error_message {
            return Err(message);
        }
        return Err("Codex CLI RPC returned no account or quota data".to_string());
    }

    let status_message = if codex_usage.has_quota_data() {
        None
    } else {
        Some("Codex CLI returned account details but no live quota snapshot.".to_string())
    };
    let repair_hint = if status_message.is_some() {
        Some(
            "Pnevma is showing local Codex session usage until the CLI returns live rate limits."
                .to_string(),
        )
    } else {
        None
    };
    Ok(ProviderProbeOutput {
        source: "cli-rpc".to_string(),
        account_email,
        plan_label: plan_label.or(codex_usage.plan_label),
        status_message,
        repair_hint,
        session_window: codex_usage.session_window,
        weekly_window: codex_usage.weekly_window,
        model_windows: codex_usage.model_windows,
        credit: codex_usage.credit,
    })
}

async fn probe_claude(config: &UsageProviderConfig) -> Result<ProviderProbeOutput, String> {
    if config.source == "local" {
        return Err("Claude source is set to local usage only.".to_string());
    }

    if config.source == "oauth" || config.source == "auto" {
        match probe_claude_oauth().await {
            Ok(output) => return Ok(output),
            Err(error) => {
                if let Some(message) = refine_claude_auth_message(&error).await {
                    return Err(message);
                }
                if is_transient_claude_live_error(&error) {
                    tracing::warn!("Claude OAuth usage probe failed (transient): {error}");
                    let cred_meta = read_claude_auth_from_credentials();
                    let (status_message, repair_hint) = transient_error_user_message(&error);
                    return Ok(ProviderProbeOutput {
                        source: "oauth".to_string(),
                        account_email: cred_meta.as_ref().and_then(|m| m.email.clone()),
                        plan_label: cred_meta.as_ref().and_then(|m| m.plan_label.clone()),
                        status_message: Some(status_message),
                        repair_hint: Some(repair_hint),
                        session_window: None,
                        weekly_window: None,
                        model_windows: vec![],
                        credit: None,
                    });
                }
                tracing::warn!("Claude OAuth usage probe failed: {error}");
                return Err(error);
            }
        }
    }

    Err("Claude source is configured for an unsupported live usage mode.".to_string())
}

#[derive(Debug)]
struct CodexCliRpcOutput {
    account: Option<Value>,
    rate_limits: Option<Value>,
    error_message: Option<String>,
}

#[derive(Debug, Default)]
struct CodexQuotaData {
    plan_label: Option<String>,
    session_window: Option<ProviderQuotaWindowView>,
    weekly_window: Option<ProviderQuotaWindowView>,
    model_windows: Vec<ProviderQuotaWindowView>,
    credit: Option<ProviderCreditView>,
}

impl CodexQuotaData {
    fn has_quota_data(&self) -> bool {
        self.session_window.is_some()
            || self.weekly_window.is_some()
            || !self.model_windows.is_empty()
            || self.credit.is_some()
    }
}

async fn probe_codex_cli_rpc() -> Result<CodexCliRpcOutput, String> {
    let mut command = provider_probe_command(resolve_binary("codex"));
    command
        .args(["app-server", "--listen", "stdio://"])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null());
    let mut child = command
        .spawn()
        .map_err(|e| format!("failed to launch codex CLI: {e}"))?;

    let mut stdin = child
        .stdin
        .take()
        .ok_or_else(|| "codex CLI stdin unavailable".to_string())?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| "codex CLI stdout unavailable".to_string())?;

    let requests = [
        json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "clientInfo": { "name": "pnevma", "version": env!("CARGO_PKG_VERSION") },
                "capabilities": {}
            }
        }),
        json!({"jsonrpc": "2.0", "method": "initialized"}),
        json!({"jsonrpc": "2.0", "id": 2, "method": "account/read", "params": {"refreshToken": false}}),
        json!({"jsonrpc": "2.0", "id": 3, "method": "account/rateLimits/read", "params": Value::Null}),
    ];

    for request in requests {
        stdin
            .write_all(request.to_string().as_bytes())
            .await
            .map_err(|e| format!("failed to write codex RPC request: {e}"))?;
        stdin
            .write_all(b"\n")
            .await
            .map_err(|e| format!("failed to finalize codex RPC request: {e}"))?;
    }
    stdin
        .flush()
        .await
        .map_err(|e| format!("failed to flush codex RPC request stream: {e}"))?;

    let mut reader = BufReader::new(stdout).lines();
    let mut responses: HashMap<i64, Value> = HashMap::new();
    let mut rate_limit_notification: Option<Value> = None;
    let read_result = timeout(Duration::from_secs(8), async {
        loop {
            let next_line = if responses.contains_key(&2)
                && !responses.contains_key(&3)
                && !responses.contains_key(&-3)
                && rate_limit_notification.is_none()
            {
                match timeout(
                    Duration::from_millis(CODEX_RATE_LIMITS_GRACE_MS),
                    reader.next_line(),
                )
                .await
                {
                    Ok(result) => result.map_err(|e| e.to_string())?,
                    Err(_) => break Ok::<(), String>(()),
                }
            } else {
                reader.next_line().await.map_err(|e| e.to_string())?
            };
            let Some(line) = next_line else {
                break Ok::<(), String>(());
            };
            let value: Value = match serde_json::from_str(&line) {
                Ok(value) => value,
                Err(_) => continue,
            };
            if let Some(id) = value.get("id").and_then(|value| value.as_i64()) {
                if let Some(result) = value.get("result") {
                    responses.insert(id, result.clone());
                } else if let Some(message) = value
                    .get("error")
                    .and_then(|error| error.get("message"))
                    .and_then(|message| message.as_str())
                {
                    responses.insert(-id, Value::String(message.to_string()));
                }
            } else if value.get("method").and_then(|value| value.as_str())
                == Some("account/rateLimits/updated")
            {
                if let Some(snapshot) = value
                    .get("params")
                    .and_then(|params| params.get("rateLimits"))
                {
                    rate_limit_notification = Some(json!({ "rateLimits": snapshot }));
                }
            }
            if responses.contains_key(&2)
                && (responses.contains_key(&3)
                    || responses.contains_key(&-3)
                    || rate_limit_notification.is_some())
            {
                break Ok(());
            }
        }
    })
    .await;

    drop(stdin);
    let _ = child.kill().await;
    let _ = child.wait().await;

    match read_result {
        Ok(Ok(())) => {}
        Ok(Err(message)) => return Err(message),
        Err(_) => return Err("codex CLI RPC probe timed out".to_string()),
    }

    if let std::collections::hash_map::Entry::Vacant(e) = responses.entry(3) {
        if let Some(rate_limits) = rate_limit_notification {
            e.insert(rate_limits);
        }
    }

    codex_cli_output_from_responses(responses)
}

async fn probe_claude_oauth() -> Result<ProviderProbeOutput, String> {
    let oauth = read_claude_oauth_token().await?;
    let value = fetch_claude_usage_value(&oauth.access_token).await?;
    let cred_meta = read_claude_auth_from_credentials();

    let account_email = extract_string_at_paths(
        &value,
        &[&["email"], &["user", "email"], &["account", "email"]],
    )
    .or_else(|| cred_meta.as_ref().and_then(|m| m.email.clone()));
    let plan_label = extract_string_at_paths(
        &value,
        &[&["rate_limit_tier"], &["plan"], &["subscriptionType"]],
    )
    .or_else(|| cred_meta.as_ref().and_then(|m| m.plan_label.clone()));
    let session_window = extract_named_window(&value, "five_hour", "Current session")
        .or_else(|| extract_named_window(&value, "current_session", "Current session"));
    let weekly_window = extract_named_window(&value, "seven_day", "All models")
        .or_else(|| extract_named_window(&value, "current_week", "All models"));
    let mut model_windows = Vec::new();
    if let Some(window) = extract_named_window(&value, "seven_day_sonnet", "Sonnet only") {
        model_windows.push(window);
    }
    if let Some(window) = extract_named_window(&value, "seven_day_opus", "Opus only") {
        model_windows.push(window);
    }
    let credit = extract_extra_usage_credit(&value);
    Ok(ProviderProbeOutput {
        source: "oauth".to_string(),
        account_email,
        plan_label,
        status_message: None,
        repair_hint: None,
        session_window,
        weekly_window,
        model_windows,
        credit,
    })
}

async fn fetch_claude_usage_value(token: &str) -> Result<Value, String> {
    match fetch_claude_usage_value_via_reqwest(token).await {
        Ok(value) => Ok(value),
        Err(reqwest_error) => match fetch_claude_usage_value_via_curl(token).await {
            Ok(value) => Ok(value),
            Err(curl_error) => Err(format!(
                "Claude OAuth usage fetch failed via reqwest ({reqwest_error}) and curl ({curl_error})"
            )),
        },
    }
}

async fn fetch_claude_usage_value_via_reqwest(token: &str) -> Result<Value, String> {
    let mut headers = HeaderMap::new();
    let auth = HeaderValue::from_str(&format!("Bearer {token}"))
        .map_err(|_| "invalid Claude OAuth token".to_string())?;
    headers.insert(AUTHORIZATION, auth);
    headers.insert(
        "anthropic-beta",
        HeaderValue::from_static("oauth-2025-04-20"),
    );
    let claude_ver = detect_claude_cli_version().unwrap_or_else(|| "2.1.0".to_string());
    if let Ok(ua) = HeaderValue::from_str(&format!("claude-code/{claude_ver}")) {
        headers.insert(reqwest::header::USER_AGENT, ua);
    }

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(8))
        .build()
        .map_err(|e| format!("failed to build Claude OAuth client: {e}"))?;
    let response = client
        .get("https://api.anthropic.com/api/oauth/usage")
        .headers(headers)
        .send()
        .await
        .map_err(|e| format!("request failed: {e}"))?;

    let status = response.status();
    if status == reqwest::StatusCode::UNAUTHORIZED {
        return Err(
            "Claude OAuth token is invalid or expired (401). Run `claude` to re-authenticate."
                .to_string(),
        );
    }
    if status == reqwest::StatusCode::FORBIDDEN {
        let body = response.text().await.unwrap_or_default();
        if body.contains("user:profile") {
            return Err(
                "Claude OAuth token missing 'user:profile' scope (403). Run `claude setup-token`."
                    .to_string(),
            );
        }
        return Err(format!(
            "Claude OAuth forbidden (403): {}",
            body.chars().take(200).collect::<String>()
        ));
    }
    if status == reqwest::StatusCode::TOO_MANY_REQUESTS {
        return Err("Claude OAuth endpoint returned 429 Too Many Requests".to_string());
    }
    if !status.is_success() {
        return Err(format!("request failed with {status}"));
    }

    response
        .json()
        .await
        .map_err(|e| format!("failed to decode response: {e}"))
}

fn detect_claude_cli_version() -> Option<String> {
    let output = std::process::Command::new(resolve_binary("claude"))
        .arg("--version")
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&output.stdout);
    text.split_whitespace()
        .find(|word| word.chars().next().is_some_and(|c| c.is_ascii_digit()))
        .map(|v| v.trim().to_string())
}

async fn fetch_claude_usage_value_via_curl(token: &str) -> Result<Value, String> {
    let claude_ver = detect_claude_cli_version().unwrap_or_else(|| "2.1.0".to_string());
    let user_agent = format!("claude-code/{claude_ver}");
    let mut command = provider_probe_command(resolve_binary("curl"));
    let output = command
        .args([
            "--silent",
            "--show-error",
            "--fail-with-body",
            "--connect-timeout",
            "8",
            "--max-time",
            "12",
            "-H",
            &format!("Authorization: Bearer {token}"),
            "-H",
            "anthropic-beta: oauth-2025-04-20",
            "-A",
            &user_agent,
            "https://api.anthropic.com/api/oauth/usage",
        ])
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .output()
        .await
        .map_err(|e| format!("failed to launch curl: {e}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
        let detail = if !stderr.is_empty() {
            stderr
        } else if !stdout.is_empty() {
            stdout
        } else {
            format!("curl exited with {}", output.status)
        };
        return Err(detail);
    }

    serde_json::from_slice::<Value>(&output.stdout)
        .map_err(|e| format!("failed to decode curl response: {e}"))
}

async fn refine_claude_auth_message(error: &str) -> Option<String> {
    let lower = error.to_lowercase();
    if lower.contains("expired") {
        return Some(
            "Claude OAuth token has expired. Run `claude` to refresh your session.".to_string(),
        );
    }
    if lower.contains("user:profile") || lower.contains("setup-token") {
        return Some(
            "Claude OAuth token missing 'user:profile' scope. Run `claude setup-token`."
                .to_string(),
        );
    }
    if lower.contains("401") && lower.contains("re-authenticate") {
        return Some(
            "Claude OAuth credentials are invalid. Run `claude` to re-authenticate.".to_string(),
        );
    }
    if !lower.contains("credentials not found") {
        return None;
    }

    // If no credential file contains a valid token, the user isn't signed in.
    match read_claude_oauth_token().await {
        Err(_) => {
            Some("Claude CLI is not signed in. Run `claude auth login` and retry.".to_string())
        }
        Ok(_) => None,
    }
}

/// Returns a user-facing (status_message, repair_hint) tuple that accurately
/// reflects the transient error category instead of blanket "rate-limiting".
fn transient_error_user_message(error: &str) -> (String, String) {
    let lower = error.to_lowercase();
    if lower.contains("429") || lower.contains("rate limit") {
        (
            "Claude OAuth usage endpoint is rate-limiting requests right now.".to_string(),
            "Pnevma will retry Claude live usage after the OAuth endpoint stops rate-limiting requests.".to_string(),
        )
    } else if lower.contains("timed out") || lower.contains("timeout") {
        (
            "Claude OAuth usage endpoint timed out.".to_string(),
            "Pnevma will retry Claude live usage automatically.".to_string(),
        )
    } else if lower.contains("connection reset") {
        (
            "Connection to Claude OAuth usage endpoint was reset.".to_string(),
            "Pnevma will retry Claude live usage automatically.".to_string(),
        )
    } else {
        (
            "Claude OAuth usage endpoint is temporarily unavailable.".to_string(),
            "Pnevma will retry Claude live usage automatically.".to_string(),
        )
    }
}

fn is_transient_claude_live_error(error: &str) -> bool {
    let lower = error.to_lowercase();
    if lower.contains("expired")
        || lower.contains("user:profile")
        || lower.contains("setup-token")
        || lower.contains("re-authenticate")
        || lower.contains("not signed in")
        || lower.contains("401")
    {
        return false;
    }
    lower.contains("429")
        || lower.contains("rate limit")
        || lower.contains("rate-limiting")
        || lower.contains("timed out")
        || lower.contains("timeout")
        || lower.contains("temporarily unavailable")
        || lower.contains("connection reset")
        || lower.contains("too many requests")
}

async fn build_local_usage_summary(provider: &str, days: u32) -> ProviderLocalUsageSummaryView {
    let snapshots = get_local_usage(Some(days as i64)).await;
    if let Some(snapshot) = snapshots
        .into_iter()
        .find(|snapshot| snapshot.provider == provider)
    {
        ProviderLocalUsageSummaryView {
            requests: snapshot.totals.total_requests,
            input_tokens: snapshot.totals.total_input_tokens,
            output_tokens: snapshot.totals.total_output_tokens,
            total_tokens: snapshot.totals.total_input_tokens + snapshot.totals.total_output_tokens,
            top_model: snapshot.top_models.first().map(|item| item.model.clone()),
            peak_day: snapshot.totals.peak_day,
            peak_day_tokens: snapshot.totals.peak_day_tokens,
        }
    } else {
        ProviderLocalUsageSummaryView {
            requests: 0,
            input_tokens: 0,
            output_tokens: 0,
            total_tokens: 0,
            top_model: None,
            peak_day: None,
            peak_day_tokens: 0,
        }
    }
}

fn extract_named_window(root: &Value, key: &str, label: &str) -> Option<ProviderQuotaWindowView> {
    let value = root.get(key)?;
    Some(window_from_value(label, value))
}

fn normalize_codex_rate_limits(value: &Value) -> CodexQuotaData {
    let fallback = value
        .get("rateLimits")
        .or_else(|| value.get("rate_limits"))
        .unwrap_or(value);
    let fallback_snapshot = fallback
        .is_object()
        .then_some(fallback)
        .and_then(extract_codex_snapshot);
    let buckets = value
        .get("rateLimitsByLimitId")
        .or_else(|| value.get("rate_limits_by_limit_id"))
        .and_then(Value::as_object)
        .map(|map| {
            map.iter()
                .filter_map(|(limit_id, snapshot)| {
                    extract_codex_snapshot(snapshot).map(|snapshot| (limit_id.clone(), snapshot))
                })
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();

    let preferred = buckets
        .iter()
        .find(|(limit_id, _)| limit_id == "codex")
        .or_else(|| buckets.first())
        .map(|(_, snapshot)| snapshot)
        .or(fallback_snapshot.as_ref())
        .cloned();

    let mut data = CodexQuotaData {
        plan_label: preferred
            .as_ref()
            .and_then(|snapshot| snapshot.plan_label.clone()),
        session_window: preferred.as_ref().and_then(|snapshot| {
            snapshot
                .primary
                .as_ref()
                .map(|window| codex_window_view("Current session", window))
        }),
        weekly_window: preferred.as_ref().and_then(|snapshot| {
            snapshot
                .secondary
                .as_ref()
                .map(|window| codex_window_view("Current week", window))
        }),
        model_windows: Vec::new(),
        credit: preferred
            .as_ref()
            .and_then(|snapshot| snapshot.credit.clone()),
    };

    for (limit_id, snapshot) in buckets {
        let is_preferred = preferred
            .as_ref()
            .map(|selected| {
                snapshot.limit_id == selected.limit_id && snapshot.limit_name == selected.limit_name
            })
            .unwrap_or(false);
        if is_preferred {
            continue;
        }
        if let Some(primary) = snapshot.primary.as_ref() {
            data.model_windows.push(codex_window_view(
                &snapshot.window_label(limit_id.as_str()),
                primary,
            ));
        }
    }

    if data.session_window.is_none()
        && data.weekly_window.is_none()
        && data.model_windows.is_empty()
        && data.credit.is_none()
    {
        let mut windows = collect_windows(fallback);
        data.session_window =
            take_matching_window(&mut windows, &["5h", "five_hour", "session", "primary"]);
        data.weekly_window =
            take_matching_window(&mut windows, &["weekly", "seven_day", "week", "secondary"]);
        data.model_windows = windows;
        data.credit = extract_credit_view(fallback, "Credits");
    }

    data
}

#[derive(Debug, Clone, Default)]
struct CodexRateLimitSnapshot {
    limit_id: Option<String>,
    limit_name: Option<String>,
    plan_label: Option<String>,
    primary: Option<CodexWindow>,
    secondary: Option<CodexWindow>,
    credit: Option<ProviderCreditView>,
}

impl CodexRateLimitSnapshot {
    fn window_label(&self, fallback: &str) -> String {
        self.limit_name
            .clone()
            .or_else(|| self.limit_id.clone())
            .unwrap_or_else(|| humanize_window_label(fallback))
    }
}

#[derive(Debug, Clone)]
struct CodexWindow {
    used_percent: f64,
    reset_at: Option<DateTime<Utc>>,
}

fn extract_codex_snapshot(value: &Value) -> Option<CodexRateLimitSnapshot> {
    let primary = value.get("primary").and_then(extract_codex_window);
    let secondary = value.get("secondary").and_then(extract_codex_window);
    let credit = extract_credit_view(value, "Credits");
    if primary.is_none() && secondary.is_none() && credit.is_none() {
        return None;
    }
    Some(CodexRateLimitSnapshot {
        limit_id: extract_string_at_paths(value, &[&["limitId"], &["limit_id"]]),
        limit_name: extract_string_at_paths(value, &[&["limitName"], &["limit_name"]]),
        plan_label: extract_string_at_paths(value, &[&["planType"], &["plan_type"]])
            .map(|value| humanize_plan_label(&value)),
        primary,
        secondary,
        credit,
    })
}

fn extract_codex_window(value: &Value) -> Option<CodexWindow> {
    let used_percent = extract_percent_used(value)?;
    Some(CodexWindow {
        used_percent,
        reset_at: extract_reset_at(value),
    })
}

fn codex_window_view(label: &str, window: &CodexWindow) -> ProviderQuotaWindowView {
    ProviderQuotaWindowView {
        label: label.to_string(),
        percent_used: Some(window.used_percent),
        percent_remaining: Some((100.0 - window.used_percent).clamp(0.0, 100.0)),
        reset_at: window.reset_at,
    }
}

fn codex_cli_output_from_responses(
    mut responses: HashMap<i64, Value>,
) -> Result<CodexCliRpcOutput, String> {
    let account = responses.remove(&2);
    let rate_limits = responses.remove(&3);
    let error_message = responses
        .remove(&-2)
        .and_then(|value| value.as_str().map(ToOwned::to_owned))
        .or_else(|| {
            responses
                .remove(&-3)
                .and_then(|value| value.as_str().map(ToOwned::to_owned))
        });
    if account.is_none() && rate_limits.is_none() && error_message.is_none() {
        return Err("codex CLI RPC returned no account or quota data".to_string());
    }
    Ok(CodexCliRpcOutput {
        account,
        rate_limits,
        error_message,
    })
}

struct CodexOAuthAuth {
    access_token: String,
    account_id: Option<String>,
}

fn codex_auth_path() -> Result<PathBuf, String> {
    if let Some(raw) = std::env::var_os("CODEX_HOME") {
        return Ok(PathBuf::from(raw).join("auth.json"));
    }
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or_else(|| "HOME env var not set".to_string())?;
    Ok(home.join(".codex").join("auth.json"))
}

fn read_codex_oauth_auth() -> Result<CodexOAuthAuth, String> {
    let path = codex_auth_path()?;
    if !path.is_file() {
        return Err("Codex auth file not found".to_string());
    }
    let raw = std::fs::read_to_string(&path)
        .map_err(|e| format!("failed to read Codex auth file: {e}"))?;
    let value: Value =
        serde_json::from_str(&raw).map_err(|e| format!("failed to parse Codex auth file: {e}"))?;
    let access_token = extract_string_at_paths(
        &value,
        &[
            &["tokens", "access_token"],
            &["tokens", "accessToken"],
            &["access_token"],
            &["accessToken"],
        ],
    )
    .ok_or_else(|| "Codex auth file contains no access token".to_string())?;
    let account_id = extract_string_at_paths(
        &value,
        &[
            &["tokens", "account_id"],
            &["tokens", "accountId"],
            &["account_id"],
            &["accountId"],
        ],
    );
    Ok(CodexOAuthAuth {
        access_token,
        account_id,
    })
}

async fn fetch_codex_usage_value(token: &str, account_id: Option<&str>) -> Result<Value, String> {
    let mut headers = HeaderMap::new();
    let auth = HeaderValue::from_str(&format!("Bearer {token}"))
        .map_err(|_| "invalid Codex OAuth token".to_string())?;
    headers.insert(AUTHORIZATION, auth);
    if let Some(id) = account_id {
        if let Ok(hv) = HeaderValue::from_str(id) {
            headers.insert("ChatGPT-Account-Id", hv);
        }
    }
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(8))
        .build()
        .map_err(|e| format!("failed to build Codex OAuth client: {e}"))?;
    let response = client
        .get("https://chatgpt.com/backend-api/wham/usage")
        .headers(headers)
        .send()
        .await
        .map_err(|e| format!("Codex usage request failed: {e}"))?;
    if !response.status().is_success() {
        return Err(format!(
            "Codex usage request failed with {}",
            response.status()
        ));
    }
    response
        .json()
        .await
        .map_err(|e| format!("failed to decode Codex usage response: {e}"))
}

async fn probe_codex_oauth() -> Result<ProviderProbeOutput, String> {
    let auth = read_codex_oauth_auth()?;
    let value = fetch_codex_usage_value(&auth.access_token, auth.account_id.as_deref()).await?;

    let plan_label = extract_string_at_paths(&value, &[&["plan_type"], &["planType"]])
        .map(|v| humanize_plan_label(&v));

    // Parse structured rate_limit (WHAM/CodexBar format)
    let rate_limit = value.get("rate_limit").or_else(|| value.get("rateLimit"));
    let session_window = rate_limit
        .and_then(|rl| rl.get("primary_window").or_else(|| rl.get("primaryWindow")))
        .and_then(|w| {
            let used = extract_percent_used(w)?;
            Some(ProviderQuotaWindowView {
                label: "Current session".to_string(),
                percent_used: Some(used),
                percent_remaining: Some((100.0 - used).clamp(0.0, 100.0)),
                reset_at: extract_reset_at(w),
            })
        });
    let weekly_window = rate_limit
        .and_then(|rl| {
            rl.get("secondary_window")
                .or_else(|| rl.get("secondaryWindow"))
        })
        .and_then(|w| {
            let used = extract_percent_used(w)?;
            Some(ProviderQuotaWindowView {
                label: "Current week".to_string(),
                percent_used: Some(used),
                percent_remaining: Some((100.0 - used).clamp(0.0, 100.0)),
                reset_at: extract_reset_at(w),
            })
        });
    let credit = extract_credit_view(&value, "Credits");

    // Fall back to generic normalizer for other response shapes
    if session_window.is_none() && weekly_window.is_none() && credit.is_none() {
        let codex_usage = normalize_codex_rate_limits(&value);
        return Ok(ProviderProbeOutput {
            source: "oauth".to_string(),
            account_email: None,
            plan_label: plan_label.or(codex_usage.plan_label),
            status_message: None,
            repair_hint: None,
            session_window: codex_usage.session_window,
            weekly_window: codex_usage.weekly_window,
            model_windows: codex_usage.model_windows,
            credit: codex_usage.credit,
        });
    }

    Ok(ProviderProbeOutput {
        source: "oauth".to_string(),
        account_email: None,
        plan_label,
        status_message: None,
        repair_hint: None,
        session_window,
        weekly_window,
        model_windows: vec![],
        credit,
    })
}

fn window_from_value(label: &str, value: &Value) -> ProviderQuotaWindowView {
    let percent_used = extract_percent_used(value);
    let percent_remaining = percent_used.map(|used| (100.0 - used).clamp(0.0, 100.0));
    ProviderQuotaWindowView {
        label: label.to_string(),
        percent_used,
        percent_remaining,
        reset_at: extract_reset_at(value),
    }
}

fn collect_windows(value: &Value) -> Vec<ProviderQuotaWindowView> {
    let mut collected = Vec::new();
    collect_windows_inner(value, "", &mut collected);
    collected
}

fn collect_windows_inner(value: &Value, path: &str, out: &mut Vec<ProviderQuotaWindowView>) {
    if extract_percent_used(value).is_some() {
        let label = path
            .split('.')
            .next_back()
            .filter(|part| !part.is_empty())
            .unwrap_or("Window");
        out.push(window_from_value(&humanize_window_label(label), value));
    }
    match value {
        Value::Object(map) => {
            for (key, child) in map {
                let next = if path.is_empty() {
                    key.clone()
                } else {
                    format!("{path}.{key}")
                };
                collect_windows_inner(child, &next, out);
            }
        }
        Value::Array(values) => {
            for (index, child) in values.iter().enumerate() {
                collect_windows_inner(child, &format!("{path}.{index}"), out);
            }
        }
        _ => {}
    }
}

fn humanize_window_label(label: &str) -> String {
    label
        .replace('_', " ")
        .split_whitespace()
        .map(|part| {
            let mut chars = part.chars();
            match chars.next() {
                Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
                None => String::new(),
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

fn take_matching_window(
    windows: &mut Vec<ProviderQuotaWindowView>,
    keywords: &[&str],
) -> Option<ProviderQuotaWindowView> {
    let index = windows.iter().position(|window| {
        let label = window.label.to_lowercase();
        keywords.iter().any(|keyword| label.contains(keyword))
    })?;
    Some(windows.remove(index))
}

fn extract_credit_view(value: &Value, label: &str) -> Option<ProviderCreditView> {
    let unlimited =
        extract_bool_at_paths(value, &[&["unlimited"], &["credits", "unlimited"]]).unwrap_or(false);
    let balance = extract_string_at_paths(
        value,
        &[
            &["credits", "balance"],
            &["balance"],
            &["credits_remaining"],
            &["remaining_credits"],
        ],
    )
    .or_else(|| {
        extract_f64_at_paths(
            value,
            &[
                &["credits", "balance"],
                &["balance"],
                &["credits_remaining"],
                &["remaining_credits"],
            ],
        )
        .map(|value| format!("{value:.2}"))
    });
    if !unlimited && balance.is_none() {
        return None;
    }
    Some(ProviderCreditView {
        label: label.to_string(),
        balance_display: balance,
        is_unlimited: unlimited,
    })
}

fn extract_extra_usage_credit(value: &Value) -> Option<ProviderCreditView> {
    let extra = value.get("extra_usage")?;
    let currency_spend = extract_f64_at_paths(
        extra,
        &[
            &["spend"],
            &["spent_usd"],
            &["cost_usd"],
            &["current_spend_usd"],
        ],
    );
    let currency_limit =
        extract_f64_at_paths(extra, &[&["limit"], &["limit_usd"], &["spend_limit_usd"]]);
    let balance_display = if let Some(spend) = currency_spend {
        Some(format!("${spend:.2}"))
    } else {
        extract_f64_at_paths(extra, &[&["used_credits"]]).map(format_usage_amount)
    };
    let limit = if let Some(limit) = currency_limit {
        Some(format!(" / ${limit:.2}"))
    } else {
        extract_f64_at_paths(extra, &[&["monthly_limit"]])
            .map(|limit| format!(" / {}", format_usage_amount(limit)))
    };
    Some(ProviderCreditView {
        label: "Extra usage".to_string(),
        balance_display: match (balance_display, limit) {
            (Some(spend), Some(limit)) => Some(format!("{spend}{limit}")),
            (Some(spend), None) => Some(spend),
            _ => None,
        },
        is_unlimited: false,
    })
}

fn extract_percent_used(value: &Value) -> Option<f64> {
    extract_f64_at_paths(
        value,
        &[
            &["used_percent"],
            &["usedPercent"],
            &["percent_used"],
            &["usage_percent"],
            &["percentage"],
            &["percent"],
            &["utilization"],
        ],
    )
    .or_else(|| {
        extract_f64_at_paths(
            value,
            &[
                &["remaining_percent"],
                &["percent_remaining"],
                &["remaining_percentage"],
            ],
        )
        .map(|remaining| (100.0 - remaining).clamp(0.0, 100.0))
    })
}

fn extract_reset_at(value: &Value) -> Option<DateTime<Utc>> {
    for path in [
        &["reset_at"][..],
        &["resets_at"][..],
        &["resetAt"][..],
        &["resetsAt"][..],
        &["window_reset_at"][..],
    ] {
        if let Some(raw) = extract_string_at_paths(value, &[path]) {
            if let Ok(parsed) = DateTime::parse_from_rfc3339(&raw) {
                return Some(parsed.with_timezone(&Utc));
            }
            if let Ok(ts) = raw.parse::<i64>() {
                if let Some(dt) = parse_unix_timestamp(ts) {
                    return Some(dt);
                }
            }
        }
    }

    if let Some(ts) = extract_i64_at_paths(value, &[&["reset_time"], &["reset_timestamp"]]) {
        return parse_unix_timestamp(ts);
    }

    None
}

fn parse_unix_timestamp(ts: i64) -> Option<DateTime<Utc>> {
    if ts.abs() >= 1_000_000_000_000 {
        let seconds = ts.div_euclid(1_000);
        let nanos = (ts.rem_euclid(1_000) as u32) * 1_000_000;
        return Utc.timestamp_opt(seconds, nanos).single();
    }
    Utc.timestamp_opt(ts, 0).single()
}

fn humanize_plan_label(value: &str) -> String {
    value
        .split(['_', '-', ' '])
        .filter(|segment| !segment.is_empty())
        .map(|segment| {
            let mut chars = segment.chars();
            match chars.next() {
                Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
                None => String::new(),
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

fn format_usage_amount(value: f64) -> String {
    if value.fract().abs() < f64::EPSILON {
        format!("{value:.0}")
    } else {
        format!("{value:.2}")
    }
}

fn extract_string_at_paths(value: &Value, paths: &[&[&str]]) -> Option<String> {
    for path in paths {
        if let Some(value) = value_at_path(value, path) {
            if let Some(string) = value.as_str() {
                let trimmed = string.trim();
                if !trimmed.is_empty() {
                    return Some(trimmed.to_string());
                }
            } else if value.is_number() || value.is_boolean() {
                return Some(value.to_string());
            }
        }
    }
    None
}

fn extract_i64_at_paths(value: &Value, paths: &[&[&str]]) -> Option<i64> {
    for path in paths {
        if let Some(value) = value_at_path(value, path) {
            if let Some(number) = value.as_i64() {
                return Some(number);
            }
            if let Some(string) = value.as_str() {
                if let Ok(number) = string.parse::<i64>() {
                    return Some(number);
                }
            }
        }
    }
    None
}

fn extract_f64_at_paths(value: &Value, paths: &[&[&str]]) -> Option<f64> {
    for path in paths {
        if let Some(value) = value_at_path(value, path) {
            if let Some(number) = value.as_f64() {
                return Some(number);
            }
            if let Some(number) = value.as_i64() {
                return Some(number as f64);
            }
            if let Some(string) = value.as_str() {
                let trimmed = string.trim().trim_end_matches('%').trim_start_matches('$');
                if let Ok(number) = trimmed.parse::<f64>() {
                    return Some(number);
                }
            }
        }
    }
    None
}

fn extract_bool_at_paths(value: &Value, paths: &[&[&str]]) -> Option<bool> {
    for path in paths {
        if let Some(value) = value_at_path(value, path) {
            if let Some(flag) = value.as_bool() {
                return Some(flag);
            }
        }
    }
    None
}

fn value_at_path<'a>(value: &'a Value, path: &[&str]) -> Option<&'a Value> {
    let mut current = value;
    for segment in path {
        current = current.get(*segment)?;
    }
    Some(current)
}

fn provider_probe_command(program: PathBuf) -> TokioCommand {
    let mut command = TokioCommand::new(program);
    command.env("PATH", provider_probe_path());
    // Suppress notification sounds from CLI tools (Claude Code, Codex) that
    // detect a non-interactive / CI environment and skip audio cues.
    command.env("TERM", "dumb");
    command.env("CI", "true");
    command.env_remove("TERM_PROGRAM");
    command
}

fn provider_probe_path() -> String {
    compose_provider_probe_path(std::env::var_os("PATH"))
}

fn compose_provider_probe_path(current_path: Option<std::ffi::OsString>) -> String {
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

    let mut seen = HashSet::new();
    segments
        .into_iter()
        .filter(|segment| seen.insert(segment.clone()))
        .collect::<Vec<_>>()
        .join(":")
}

struct ClaudeCredentialsMetadata {
    email: Option<String>,
    plan_label: Option<String>,
}

/// Read account metadata (email, plan) from Claude credential files
/// without spawning the CLI.
fn read_claude_auth_from_credentials() -> Option<ClaudeCredentialsMetadata> {
    let paths = claude_oauth_candidate_paths().ok()?;
    for path in paths {
        if !path.is_file() {
            continue;
        }
        let raw = std::fs::read_to_string(&path).ok()?;
        let value: Value = serde_json::from_str(&raw).ok()?;
        let email = extract_string_at_paths(
            &value,
            &[&["email"], &["account", "email"], &["user", "email"]],
        );
        let plan_label = extract_string_at_paths(
            &value,
            &[
                &["subscription_type"],
                &["subscriptionType"],
                &["plan"],
                &["rate_limit_tier"],
            ],
        )
        .map(|v| humanize_plan_label(&v));
        if email.is_some() || plan_label.is_some() {
            return Some(ClaudeCredentialsMetadata { email, plan_label });
        }
    }
    None
}

#[derive(Debug)]
struct ClaudeOAuthToken {
    access_token: String,
    #[allow(dead_code)]
    scopes: Vec<String>,
}

async fn read_claude_oauth_token() -> Result<ClaudeOAuthToken, String> {
    let paths = claude_oauth_candidate_paths()?;
    let now_ms = chrono::Utc::now().timestamp_millis();
    let mut found_expired = false;
    let mut found_missing_scope = false;
    for path in paths {
        if !path.is_file() {
            continue;
        }
        let raw = std::fs::read_to_string(&path)
            .map_err(|e| format!("failed to read Claude credentials: {e}"))?;
        let value: Value = serde_json::from_str(&raw)
            .map_err(|e| format!("failed to parse Claude credentials: {e}"))?;
        if let Some(parsed) = extract_claude_oauth_credential(&value) {
            if let Some(expires_at_ms) = parsed.expires_at_ms {
                let remaining_secs = (expires_at_ms - now_ms) / 1_000;
                if remaining_secs < CLAUDE_TOKEN_EXPIRY_MARGIN_SECS {
                    tracing::warn!(
                        remaining_secs,
                        "Claude OAuth token expired or expiring soon"
                    );
                    found_expired = true;
                    continue;
                }
            }
            if !parsed.scopes.is_empty() && !parsed.scopes.contains(&"user:profile".to_string()) {
                tracing::warn!(scopes = ?parsed.scopes, "Claude OAuth token missing user:profile scope");
                found_missing_scope = true;
                continue;
            }
            return Ok(ClaudeOAuthToken {
                access_token: parsed.access_token,
                scopes: parsed.scopes,
            });
        }
    }
    if found_expired {
        return Err("Claude OAuth token expired. Run `claude` to refresh credentials.".to_string());
    }
    if found_missing_scope {
        return Err(
            "Claude OAuth token missing 'user:profile' scope. Run `claude setup-token`."
                .to_string(),
        );
    }
    Err("Claude OAuth credentials not found".to_string())
}

struct ParsedClaudeOAuthCredential {
    access_token: String,
    expires_at_ms: Option<i64>,
    scopes: Vec<String>,
}

fn extract_claude_oauth_credential(value: &Value) -> Option<ParsedClaudeOAuthCredential> {
    if let Some(oauth) = value.get("claudeAiOauth") {
        let token = extract_string_at_paths(oauth, &[&["accessToken"], &["access_token"]])?;
        let expires_at_ms = extract_i64_at_paths(oauth, &[&["expiresAt"], &["expires_at"]]);
        let scopes = oauth
            .get("scopes")
            .and_then(|v| v.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|v| v.as_str().map(String::from))
                    .collect()
            })
            .unwrap_or_default();
        return Some(ParsedClaudeOAuthCredential {
            access_token: token,
            expires_at_ms,
            scopes,
        });
    }
    let token = extract_string_at_paths(
        value,
        &[
            &["access_token"],
            &["accessToken"],
            &["tokens", "access_token"],
            &["tokens", "accessToken"],
            &["oauth", "access_token"],
            &["oauth", "accessToken"],
        ],
    )?;
    let expires_at_ms = extract_i64_at_paths(
        value,
        &[
            &["expiresAt"],
            &["expires_at"],
            &["oauth", "expiresAt"],
            &["oauth", "expires_at"],
            &["tokens", "expiresAt"],
            &["tokens", "expires_at"],
        ],
    );
    Some(ParsedClaudeOAuthCredential {
        access_token: token,
        expires_at_ms,
        scopes: vec![],
    })
}

fn claude_oauth_candidate_paths() -> Result<Vec<PathBuf>, String> {
    let mut paths = Vec::new();
    if let Some(raw) = std::env::var_os("CLAUDE_CONFIG_DIR") {
        for part in raw.to_string_lossy().split(',') {
            let trimmed = part.trim();
            if !trimmed.is_empty() {
                paths.push(PathBuf::from(trimmed).join(".credentials.json"));
            }
        }
    }
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or_else(|| "HOME env var not set".to_string())?;
    paths.push(home.join(".claude").join(".credentials.json"));
    paths.push(
        home.join(".config")
            .join("claude")
            .join(".credentials.json"),
    );
    Ok(paths)
}

async fn provider_usage_settings_from_config(config: &GlobalConfig) -> ProviderUsageSettingsView {
    ProviderUsageSettingsView {
        refresh_interval_seconds: config.usage_providers.refresh_interval_seconds,
        codex: ProviderUsageProviderSettingsView {
            source: config.usage_providers.codex.source.clone(),
            web_extras_enabled: config.usage_providers.codex.web_extras_enabled,
            keychain_prompt_policy: config.usage_providers.codex.keychain_prompt_policy.clone(),
            manual_cookie_configured: read_manual_cookie_configured(CODEX_MANUAL_COOKIE_ACCOUNT)
                .await,
        },
        claude: ProviderUsageProviderSettingsView {
            source: config.usage_providers.claude.source.clone(),
            web_extras_enabled: config.usage_providers.claude.web_extras_enabled,
            keychain_prompt_policy: config.usage_providers.claude.keychain_prompt_policy.clone(),
            manual_cookie_configured: read_manual_cookie_configured(CLAUDE_MANUAL_COOKIE_ACCOUNT)
                .await,
        },
    }
}

fn map_usage_provider_input(
    input: &SetProviderUsageProviderSettingsInput,
) -> Result<UsageProviderConfig, String> {
    let source = input.source.trim().to_string();
    let keychain_prompt_policy = input.keychain_prompt_policy.trim().to_string();

    if source != "auto" && source != "cli" && source != "oauth" && source != "local" {
        return Err("provider source must be one of auto, cli, oauth, or local".to_string());
    }
    if keychain_prompt_policy != "never"
        && keychain_prompt_policy != "user_action"
        && keychain_prompt_policy != "always"
    {
        return Err(
            "keychain prompt policy must be one of never, user_action, or always".to_string(),
        );
    }

    Ok(UsageProviderConfig {
        source,
        web_extras_enabled: input.web_extras_enabled,
        keychain_prompt_policy,
    })
}

async fn save_manual_cookie_value(
    account: &str,
    input: &SetProviderUsageProviderSettingsInput,
) -> Result<(), String> {
    if input.clear_manual_cookie {
        delete_keychain_secret(PROVIDER_USAGE_KEYCHAIN_SERVICE, account).await?;
        return Ok(());
    }
    if let Some(value) = &input.manual_cookie_value {
        let trimmed = value.trim();
        if trimmed.is_empty() {
            delete_keychain_secret(PROVIDER_USAGE_KEYCHAIN_SERVICE, account).await?;
        } else {
            store_keychain_secret(PROVIDER_USAGE_KEYCHAIN_SERVICE, account, trimmed).await?;
        }
    }
    Ok(())
}

async fn read_manual_cookie_configured(account: &str) -> bool {
    read_keychain_secret(PROVIDER_USAGE_KEYCHAIN_SERVICE, account)
        .await
        .map(|value| !value.trim().is_empty())
        .unwrap_or(false)
}

async fn store_keychain_secret(service: &str, account: &str, value: &str) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        use security_framework::passwords::set_generic_password;
        set_generic_password(service, account, value.as_bytes()).map_err(|e| e.to_string())
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (service, account, value);
        Err("keychain not supported on this platform".to_string())
    }
}

async fn read_keychain_secret(service: &str, account: &str) -> Result<String, String> {
    #[cfg(target_os = "macos")]
    {
        use security_framework::passwords::get_generic_password;

        let bytes = get_generic_password(service, account).map_err(|e| e.to_string())?;
        String::from_utf8(bytes).map_err(|e| e.to_string())
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (service, account);
        Err("keychain not supported on this platform".to_string())
    }
}

async fn delete_keychain_secret(service: &str, account: &str) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        let status = Command::new("security")
            .args(["delete-generic-password", "-s", service, "-a", account])
            .status()
            .map_err(|e| format!("failed to delete Keychain item {service}/{account}: {e}"))?;
        if status.success() || status.code() == Some(44) {
            Ok(())
        } else {
            Err(format!(
                "failed to delete Keychain item {service}/{account}"
            ))
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (service, account);
        Err("keychain not supported on this platform".to_string())
    }
}

async fn load_effective_global_config_for_providers(
    state: &AppState,
) -> Result<GlobalConfig, String> {
    let current = state.current.lock().await;
    if let Some(ctx) = current.as_ref() {
        Ok(ctx.global_config.clone())
    } else {
        load_global_config().map_err(|e| e.to_string())
    }
}

fn cached_snapshot(
    key: &str,
    now: DateTime<Utc>,
    force_refresh: bool,
) -> Option<ProviderUsageSnapshotView> {
    if force_refresh {
        return None;
    }
    cached_snapshot_with_max_age(key, now, PROVIDER_CACHE_TTL_SECS)
}

fn cached_snapshot_with_max_age(
    key: &str,
    now: DateTime<Utc>,
    max_age_seconds: i64,
) -> Option<ProviderUsageSnapshotView> {
    let cache = PROVIDER_USAGE_CACHE
        .get_or_init(|| StdMutex::new(ProviderUsageCache::default()))
        .lock()
        .ok()?;
    let cached = cache.snapshots.get(key)?;
    if (now - cached.cached_at).num_seconds() > max_age_seconds {
        return None;
    }
    Some(cached.snapshot.clone())
}

fn cache_snapshot(key: &str, snapshot: ProviderUsageSnapshotView) {
    if let Ok(mut cache) = PROVIDER_USAGE_CACHE
        .get_or_init(|| StdMutex::new(ProviderUsageCache::default()))
        .lock()
    {
        cache.snapshots.insert(
            key.to_string(),
            CachedSnapshot {
                cached_at: Utc::now(),
                snapshot,
            },
        );
    }
}

fn finalize_provider_snapshot(
    provider: &str,
    cache_key: &str,
    now: DateTime<Utc>,
    snapshot: ProviderUsageSnapshotView,
) -> ProviderUsageSnapshotView {
    let cached_live = cached_snapshot_with_max_age(cache_key, now, CLAUDE_LIVE_FALLBACK_TTL_SECS);
    fallback_snapshot_from_cached_live(provider, snapshot, cached_live)
}

fn fallback_snapshot_from_cached_live(
    provider: &str,
    current: ProviderUsageSnapshotView,
    cached_live: Option<ProviderUsageSnapshotView>,
) -> ProviderUsageSnapshotView {
    if provider != "claude" || current.status == "ok" {
        return current;
    }
    let Some(message) = current.status_message.as_deref() else {
        return current;
    };
    if !is_transient_claude_live_error(message) {
        return current;
    }
    let Some(cached_live) = cached_live else {
        return current;
    };
    if cached_live.source == "local"
        || (cached_live.session_window.is_none()
            && cached_live.weekly_window.is_none()
            && cached_live.model_windows.is_empty()
            && cached_live.credit.is_none())
    {
        return current;
    }

    let current_account_email = current.account_email.clone();
    let current_plan_label = current.plan_label.clone();
    let current_local_usage = current.local_usage.clone();
    let mut fallback = cached_live;
    fallback.status = "warning".to_string();
    let reason = current
        .status_message
        .as_deref()
        .unwrap_or("the endpoint is unavailable");
    fallback.status_message = Some(format!("Showing cached live Claude usage — {reason}"));
    fallback.repair_hint = current.repair_hint.or(Some(
        "Pnevma will retry Claude live usage automatically.".to_string(),
    ));
    fallback.local_usage = current_local_usage;
    fallback.account_email = current_account_email.or(fallback.account_email);
    fallback.plan_label = current_plan_label.or(fallback.plan_label);
    fallback
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Debug, Deserialize)]
    struct ClaudeAuthStatusResponse {
        #[serde(rename = "loggedIn")]
        logged_in: bool,
        #[serde(rename = "authMethod")]
        auth_method: Option<String>,
        email: Option<String>,
        #[serde(rename = "subscriptionType")]
        subscription_type: Option<String>,
    }

    #[test]
    fn percent_used_from_remaining_fields_is_supported() {
        let value = json!({"remaining_percent": 82.5});
        assert_eq!(extract_percent_used(&value), Some(17.5));
    }

    #[test]
    fn percent_used_from_utilization_is_supported() {
        let value = json!({"utilization": 97.0});
        assert_eq!(extract_percent_used(&value), Some(97.0));
    }

    #[test]
    fn collect_windows_finds_nested_rate_limit_windows() {
        let value = json!({
            "five_hour": { "used_percent": 24.0, "reset_at": "2026-03-11T12:00:00Z" },
            "nested": {
                "seven_day": { "remaining_percent": 90.0 }
            }
        });
        let mut windows = collect_windows(&value);
        let session = take_matching_window(&mut windows, &["five"]);
        let week = take_matching_window(&mut windows, &["seven"]);
        assert_eq!(
            session.as_ref().and_then(|item| item.percent_used),
            Some(24.0)
        );
        assert_eq!(week.as_ref().and_then(|item| item.percent_used), Some(10.0));
    }

    #[test]
    fn window_from_value_extracts_reset_at() {
        let value = json!({"used_percent": 50.0, "reset_at": "2026-03-11T12:00:00Z"});
        let window = window_from_value("Test", &value);
        assert_eq!(window.percent_remaining, Some(50.0));
        assert!(window.reset_at.is_some());
    }

    #[test]
    fn window_from_value_extracts_camel_case_reset_at_in_millis() {
        let value = json!({"usedPercent": 50.0, "resetsAt": 1_741_658_800_123_i64});
        let window = window_from_value("Test", &value);
        assert_eq!(window.percent_remaining, Some(50.0));
        assert!(window.reset_at.is_some());
    }

    #[test]
    fn normalize_codex_rate_limits_supports_modern_snapshot_shape() {
        let value = json!({
            "rateLimits": {
                "planType": "pro",
                "primary": { "usedPercent": 12, "resetsAt": 1_741_658_800_i64 },
                "secondary": { "usedPercent": 97, "resetsAt": 1_741_700_000_i64 },
                "credits": { "balance": "12.50", "unlimited": false, "hasCredits": true }
            }
        });

        let output = normalize_codex_rate_limits(&value);
        assert_eq!(output.plan_label.as_deref(), Some("Pro"));
        assert_eq!(
            output
                .session_window
                .as_ref()
                .and_then(|window| window.percent_used),
            Some(12.0)
        );
        assert_eq!(
            output
                .weekly_window
                .as_ref()
                .and_then(|window| window.percent_used),
            Some(97.0)
        );
        assert_eq!(
            output
                .credit
                .as_ref()
                .and_then(|credit| credit.balance_display.as_deref()),
            Some("12.50")
        );
    }

    #[test]
    fn normalize_codex_rate_limits_supports_multi_bucket_shape() {
        let value = json!({
            "rateLimitsByLimitId": {
                "codex": {
                    "limitId": "codex",
                    "limitName": "Codex",
                    "primary": { "usedPercent": 18, "resetsAt": 1_741_658_800_i64 }
                },
                "gpt5": {
                    "limitId": "gpt5",
                    "limitName": "GPT-5",
                    "primary": { "usedPercent": 22, "resetsAt": 1_741_658_900_i64 }
                }
            }
        });

        let output = normalize_codex_rate_limits(&value);
        assert_eq!(
            output
                .session_window
                .as_ref()
                .and_then(|window| window.percent_used),
            Some(18.0)
        );
        assert_eq!(output.model_windows.len(), 1);
        assert_eq!(output.model_windows[0].label, "GPT-5");
    }

    #[test]
    fn extract_extra_usage_credit_supports_credit_shapes() {
        let value = json!({
            "extra_usage": {
                "used_credits": 12.0,
                "monthly_limit": 36000
            }
        });

        let credit = extract_extra_usage_credit(&value).expect("extra usage credit");
        assert_eq!(credit.balance_display.as_deref(), Some("12 / 36000"));
    }

    #[test]
    fn humanize_plan_label_normalizes_snake_case() {
        assert_eq!(humanize_plan_label("max_plan"), "Max Plan");
    }

    #[test]
    fn codex_cli_output_accepts_account_without_rate_limits() {
        let mut responses = HashMap::new();
        responses.insert(
            2,
            json!({
                "account": {
                    "email": "user@example.com",
                    "planType": "pro"
                }
            }),
        );

        let output = codex_cli_output_from_responses(responses).expect("codex output");
        let account = output.account.expect("account payload");
        assert!(output.rate_limits.is_none());
        assert_eq!(
            extract_string_at_paths(&account, &[&["account", "planType"]]),
            Some("pro".to_string())
        );
    }

    #[test]
    fn codex_cli_output_accepts_rate_limits_without_account() {
        let mut responses = HashMap::new();
        responses.insert(
            3,
            json!({
                "five_hour": {
                    "used_percent": 18.0
                }
            }),
        );

        let output = codex_cli_output_from_responses(responses).expect("codex output");
        assert!(output.account.is_none());
        assert_eq!(
            output
                .rate_limits
                .as_ref()
                .and_then(|value| extract_percent_used(&value["five_hour"])),
            Some(18.0)
        );
    }

    #[test]
    fn codex_cli_output_rejects_completely_empty_response() {
        let error = codex_cli_output_from_responses(HashMap::new()).expect_err("missing payload");
        assert_eq!(error, "codex CLI RPC returned no account or quota data");
    }

    #[test]
    fn codex_cli_output_surfaces_rpc_error_message() {
        let mut responses = HashMap::new();
        responses.insert(-2, Value::String("authentication required".to_string()));

        let output = codex_cli_output_from_responses(responses).expect("codex output");
        assert_eq!(
            output.error_message.as_deref(),
            Some("authentication required")
        );
        assert!(output.account.is_none());
        assert!(output.rate_limits.is_none());
    }

    #[test]
    fn compose_provider_probe_path_prepends_common_cli_dirs_once() {
        let path = compose_provider_probe_path(Some(std::ffi::OsString::from(
            "/usr/bin:/custom/bin:/opt/homebrew/bin",
        )));

        let segments: Vec<_> = path.split(':').collect();
        assert_eq!(segments.first().copied(), Some("/opt/homebrew/bin"));
        assert!(segments.contains(&"/custom/bin"));
        assert_eq!(
            segments
                .iter()
                .filter(|segment| **segment == "/opt/homebrew/bin")
                .count(),
            1
        );
        assert_eq!(
            segments
                .iter()
                .filter(|segment| **segment == "/usr/bin")
                .count(),
            1
        );
    }

    #[test]
    fn parse_claude_auth_status_response_reads_logged_in_flag() {
        let status: ClaudeAuthStatusResponse = serde_json::from_str(
            r#"{"loggedIn":false,"authMethod":"none","apiProvider":"firstParty"}"#,
        )
        .expect("claude auth status");

        assert!(!status.logged_in);
        assert_eq!(status.auth_method.as_deref(), Some("none"));
    }

    #[test]
    fn extract_claude_oauth_credential_supports_current_claude_ai_shape() {
        let value = json!({
            "claudeAiOauth": {
                "accessToken": "test-token"
            }
        });

        let parsed = extract_claude_oauth_credential(&value).expect("credential");
        assert_eq!(parsed.access_token, "test-token");
    }

    #[test]
    fn parse_claude_auth_status_response_reads_subscription_type() {
        let status: ClaudeAuthStatusResponse = serde_json::from_str(
            r#"{"loggedIn":true,"authMethod":"claude.ai","email":"user@example.com","subscriptionType":"max"}"#,
        )
        .expect("claude auth status");

        assert_eq!(status.email.as_deref(), Some("user@example.com"));
        assert_eq!(status.subscription_type.as_deref(), Some("max"));
    }

    #[test]
    fn transient_error_user_message_differentiates_error_types() {
        let (msg, _) = transient_error_user_message(
            "Claude OAuth usage fetch failed via reqwest (request failed with 429 Too Many Requests)",
        );
        assert_eq!(
            msg,
            "Claude OAuth usage endpoint is rate-limiting requests right now."
        );

        let (msg, _) = transient_error_user_message(
            "Claude OAuth usage fetch failed via reqwest (request failed: timed out) and curl (Operation timed out)",
        );
        assert_eq!(msg, "Claude OAuth usage endpoint timed out.");

        let (msg, _) = transient_error_user_message("connection reset by peer");
        assert_eq!(msg, "Connection to Claude OAuth usage endpoint was reset.");

        let (msg, _) = transient_error_user_message("some other transient error");
        assert_eq!(
            msg,
            "Claude OAuth usage endpoint is temporarily unavailable."
        );
    }

    #[test]
    fn fallback_snapshot_from_cached_live_reuses_live_claude_windows_on_transient_failure() {
        let cached = ProviderUsageSnapshotView {
            provider: "claude".to_string(),
            display_name: "Claude".to_string(),
            status: "ok".to_string(),
            status_message: None,
            repair_hint: None,
            source: "oauth".to_string(),
            account_email: Some("user@example.com".to_string()),
            plan_label: Some("Max".to_string()),
            last_refreshed_at: Utc.timestamp_opt(1_741_658_800, 0).single().unwrap(),
            session_window: Some(ProviderQuotaWindowView {
                label: "Current session".to_string(),
                percent_used: Some(6.0),
                percent_remaining: Some(94.0),
                reset_at: None,
            }),
            weekly_window: Some(ProviderQuotaWindowView {
                label: "All models".to_string(),
                percent_used: Some(97.0),
                percent_remaining: Some(3.0),
                reset_at: None,
            }),
            model_windows: vec![ProviderQuotaWindowView {
                label: "Sonnet only".to_string(),
                percent_used: Some(25.0),
                percent_remaining: Some(75.0),
                reset_at: None,
            }],
            credit: None,
            local_usage: ProviderLocalUsageSummaryView {
                requests: 1,
                input_tokens: 10,
                output_tokens: 20,
                total_tokens: 30,
                top_model: Some("claude-opus-4-6".to_string()),
                peak_day: Some("2026-03-07".to_string()),
                peak_day_tokens: 30,
            },
            dashboard_extras: None,
        };
        let current = ProviderUsageSnapshotView {
            provider: "claude".to_string(),
            display_name: "Claude".to_string(),
            status: "warning".to_string(),
            status_message: Some(
                "Claude OAuth usage endpoint is rate-limiting requests right now.".to_string(),
            ),
            repair_hint: Some("retry later".to_string()),
            source: "oauth".to_string(),
            account_email: Some("user@example.com".to_string()),
            plan_label: Some("Max".to_string()),
            last_refreshed_at: Utc.timestamp_opt(1_741_659_000, 0).single().unwrap(),
            session_window: None,
            weekly_window: None,
            model_windows: vec![],
            credit: None,
            local_usage: ProviderLocalUsageSummaryView {
                requests: 9,
                input_tokens: 90,
                output_tokens: 180,
                total_tokens: 270,
                top_model: Some("claude-sonnet".to_string()),
                peak_day: Some("2026-03-09".to_string()),
                peak_day_tokens: 270,
            },
            dashboard_extras: None,
        };

        let fallback = fallback_snapshot_from_cached_live("claude", current, Some(cached));
        assert_eq!(fallback.status, "warning");
        assert_eq!(fallback.source, "oauth");
        assert_eq!(
            fallback
                .session_window
                .as_ref()
                .and_then(|window| window.percent_used),
            Some(6.0)
        );
        assert_eq!(
            fallback
                .weekly_window
                .as_ref()
                .and_then(|window| window.percent_used),
            Some(97.0)
        );
        assert_eq!(fallback.model_windows.len(), 1);
        assert_eq!(fallback.local_usage.requests, 9);
        assert_eq!(
            fallback.status_message.as_deref(),
            Some(
                "Showing cached live Claude usage \u{2014} Claude OAuth usage endpoint is rate-limiting requests right now."
            )
        );
    }
}
