use super::*;
use chrono::{DateTime, TimeZone, Utc};
use pnevma_core::config::UsageProviderConfig;
use pnevma_session::resolve_binary;
use reqwest::header::{HeaderMap, HeaderValue, AUTHORIZATION};
use serde_json::Value;
use std::collections::HashMap;
use std::path::PathBuf;
use std::process::Command;
use std::sync::{Mutex as StdMutex, OnceLock};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

const PROVIDER_USAGE_KEYCHAIN_SERVICE: &str = "com.pnevma.usage-providers";
const CODEX_MANUAL_COOKIE_ACCOUNT: &str = "codex-manual-cookie";
const CLAUDE_MANUAL_COOKIE_ACCOUNT: &str = "claude-manual-cookie";
const PROVIDER_CACHE_TTL_SECS: i64 = 120;

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
            let snapshot =
                probe_provider_snapshot("codex", &config.usage_providers.codex, local_usage_days)
                    .await;
            if snapshot.status != "error" || snapshot.local_usage.total_tokens > 0 {
                cache_snapshot(&codex_key, snapshot.clone());
            }
            Ok::<_, String>(snapshot)
        }
    };
    let claude_future = async {
        if let Some(snapshot) = claude_cached {
            Ok(snapshot)
        } else {
            let snapshot =
                probe_provider_snapshot("claude", &config.usage_providers.claude, local_usage_days)
                    .await;
            if snapshot.status != "error" || snapshot.local_usage.total_tokens > 0 {
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
            status: "ok".to_string(),
            status_message: None,
            repair_hint: None,
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
    if lower.contains("timeout") {
        return format!("The {provider} probe timed out. Open the CLI once, then retry.");
    }
    format!("Pnevma fell back to local {provider} session usage only.")
}

async fn probe_codex(config: &UsageProviderConfig) -> Result<ProviderProbeOutput, String> {
    if config.source == "local" {
        return Err("Codex source is set to local usage only.".to_string());
    }

    let output = probe_codex_cli_rpc().await?;
    let account_email = extract_string_at_paths(
        &output.account,
        &[
            &["email"],
            &["account", "email"],
            &["user", "email"],
            &["profile", "email"],
        ],
    );
    let plan_label = extract_string_at_paths(
        &output.account,
        &[
            &["plan"],
            &["planType"],
            &["plan", "name"],
            &["billing", "plan"],
            &["subscription", "plan"],
            &["account", "planType"],
            &["account", "plan"],
        ],
    );
    let mut windows = output
        .rate_limits
        .as_ref()
        .map(collect_windows)
        .unwrap_or_default();
    let session_window =
        take_matching_window(&mut windows, &["5h", "five_hour", "session", "primary"]);
    let weekly_window =
        take_matching_window(&mut windows, &["weekly", "seven_day", "week", "secondary"]);
    let credit = output
        .rate_limits
        .as_ref()
        .and_then(|value| extract_credit_view(value, "Credits"));
    Ok(ProviderProbeOutput {
        source: "cli-rpc".to_string(),
        account_email,
        plan_label,
        session_window,
        weekly_window,
        model_windows: windows,
        credit,
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
            }
        }
    }

    Err(
        "Claude OAuth usage is unavailable; only local usage data is currently available."
            .to_string(),
    )
}

struct CodexCliRpcOutput {
    account: Value,
    rate_limits: Option<Value>,
}

async fn probe_codex_cli_rpc() -> Result<CodexCliRpcOutput, String> {
    let mut child = TokioCommand::new(resolve_binary("codex"))
        .args(["-s", "read-only", "-a", "untrusted", "app-server"])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
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
                "clientInfo": { "name": "pnevma", "version": env!("CARGO_PKG_VERSION") }
            }
        }),
        json!({"jsonrpc": "2.0", "id": 2, "method": "account/read", "params": {}}),
        json!({"jsonrpc": "2.0", "id": 3, "method": "account/rateLimits/read", "params": {}}),
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
    drop(stdin);

    let mut reader = BufReader::new(stdout).lines();
    let mut responses: HashMap<i64, Value> = HashMap::new();
    let read_result = timeout(Duration::from_secs(8), async {
        loop {
            let next_line = if responses.contains_key(&2) && !responses.contains_key(&3) {
                match timeout(Duration::from_millis(750), reader.next_line()).await {
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
                }
            }
            if responses.contains_key(&2) && responses.contains_key(&3) {
                break Ok(());
            }
        }
    })
    .await;

    let _ = child.kill().await;
    let _ = child.wait().await;

    match read_result {
        Ok(Ok(())) => {}
        Ok(Err(message)) => return Err(message),
        Err(_) => return Err("codex CLI RPC probe timed out".to_string()),
    }

    codex_cli_output_from_responses(responses)
}

async fn probe_claude_oauth() -> Result<ProviderProbeOutput, String> {
    let token = read_claude_oauth_token().await?;
    let mut headers = HeaderMap::new();
    let auth = HeaderValue::from_str(&format!("Bearer {token}"))
        .map_err(|_| "invalid Claude OAuth token".to_string())?;
    headers.insert(AUTHORIZATION, auth);
    headers.insert(
        "anthropic-beta",
        HeaderValue::from_static("oauth-2025-04-20"),
    );

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(8))
        .build()
        .map_err(|e| format!("failed to build Claude OAuth client: {e}"))?;
    let response = client
        .get("https://api.anthropic.com/api/oauth/usage")
        .headers(headers)
        .send()
        .await
        .map_err(|e| format!("Claude OAuth request failed: {e}"))?;

    if !response.status().is_success() {
        return Err(format!(
            "Claude OAuth request failed with {}",
            response.status()
        ));
    }

    let value: Value = response
        .json()
        .await
        .map_err(|e| format!("failed to decode Claude OAuth response: {e}"))?;

    let account_email = extract_string_at_paths(
        &value,
        &[&["email"], &["user", "email"], &["account", "email"]],
    );
    let plan_label = extract_string_at_paths(&value, &[&["rate_limit_tier"], &["plan"]]);
    let session_window = extract_named_window(&value, "five_hour", "Current Session")
        .or_else(|| extract_named_window(&value, "current_session", "Current Session"));
    let weekly_window = extract_named_window(&value, "seven_day", "Current Week")
        .or_else(|| extract_named_window(&value, "current_week", "Current Week"));
    let mut model_windows = Vec::new();
    if let Some(window) = extract_named_window(&value, "seven_day_sonnet", "Weekly Sonnet") {
        model_windows.push(window);
    }
    if let Some(window) = extract_named_window(&value, "seven_day_opus", "Weekly Opus") {
        model_windows.push(window);
    }
    let credit = extract_extra_usage_credit(&value);
    Ok(ProviderProbeOutput {
        source: "oauth".to_string(),
        account_email,
        plan_label,
        session_window,
        weekly_window,
        model_windows,
        credit,
    })
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
struct ClaudeAuthStatusResponse {
    #[serde(rename = "loggedIn")]
    logged_in: bool,
    #[serde(rename = "authMethod")]
    auth_method: Option<String>,
}

async fn refine_claude_auth_message(error: &str) -> Option<String> {
    if !error.to_lowercase().contains("credentials not found") {
        return None;
    }

    match probe_claude_auth_status().await {
        Ok(status) if !status.logged_in => {
            Some("Claude CLI is not signed in. Run `claude auth login` and retry.".to_string())
        }
        _ => None,
    }
}

async fn probe_claude_auth_status() -> Result<ClaudeAuthStatusResponse, String> {
    let output = TokioCommand::new(resolve_binary("claude"))
        .args(["auth", "status"])
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .output()
        .await
        .map_err(|e| format!("failed to launch claude CLI: {e}"))?;

    let stdout = String::from_utf8(output.stdout)
        .map_err(|e| format!("failed to decode claude auth status output: {e}"))?;

    serde_json::from_str::<ClaudeAuthStatusResponse>(&stdout)
        .map_err(|e| format!("failed to parse claude auth status output: {e}"))
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

fn codex_cli_output_from_responses(
    mut responses: HashMap<i64, Value>,
) -> Result<CodexCliRpcOutput, String> {
    let account = responses
        .remove(&2)
        .ok_or_else(|| "codex account/read returned no result".to_string())?;
    let rate_limits = responses.remove(&3);
    Ok(CodexCliRpcOutput {
        account,
        rate_limits,
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
    let balance_display = extract_f64_at_paths(
        extra,
        &[
            &["spend"],
            &["spent_usd"],
            &["cost_usd"],
            &["current_spend_usd"],
        ],
    )
    .map(|amount| format!("${amount:.2}"));
    let limit = extract_f64_at_paths(extra, &[&["limit"], &["limit_usd"], &["spend_limit_usd"]])
        .map(|amount| format!(" / ${amount:.2}"));
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
            &["percent_used"],
            &["usage_percent"],
            &["percentage"],
            &["percent"],
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
        &["window_reset_at"][..],
    ] {
        if let Some(raw) = extract_string_at_paths(value, &[path]) {
            if let Ok(parsed) = DateTime::parse_from_rfc3339(&raw) {
                return Some(parsed.with_timezone(&Utc));
            }
            if let Ok(ts) = raw.parse::<i64>() {
                if let Some(dt) = Utc.timestamp_opt(ts, 0).single() {
                    return Some(dt);
                }
            }
        }
    }

    if let Some(ts) = extract_i64_at_paths(value, &[&["reset_time"], &["reset_timestamp"]]) {
        return Utc.timestamp_opt(ts, 0).single();
    }

    None
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

async fn read_claude_oauth_token() -> Result<String, String> {
    let paths = claude_oauth_candidate_paths()?;
    for path in paths {
        if !path.is_file() {
            continue;
        }
        let raw = std::fs::read_to_string(&path)
            .map_err(|e| format!("failed to read Claude credentials: {e}"))?;
        let value: Value = serde_json::from_str(&raw)
            .map_err(|e| format!("failed to parse Claude credentials: {e}"))?;
        if let Some(token) = extract_string_at_paths(
            &value,
            &[
                &["access_token"],
                &["tokens", "access_token"],
                &["oauth", "access_token"],
            ],
        ) {
            return Ok(token);
        }
    }
    Err("Claude OAuth credentials not found".to_string())
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
    let cache = PROVIDER_USAGE_CACHE
        .get_or_init(|| StdMutex::new(ProviderUsageCache::default()))
        .lock()
        .ok()?;
    let cached = cache.snapshots.get(key)?;
    if (now - cached.cached_at).num_seconds() > PROVIDER_CACHE_TTL_SECS {
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn percent_used_from_remaining_fields_is_supported() {
        let value = json!({"remaining_percent": 82.5});
        assert_eq!(extract_percent_used(&value), Some(17.5));
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
    fn codex_cli_output_requires_account_but_not_rate_limits() {
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
        assert!(output.rate_limits.is_none());
        assert_eq!(
            extract_string_at_paths(&output.account, &[&["account", "planType"]]),
            Some("pro".to_string())
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
}
