// usage_local.rs — Scans local JSONL session files from Claude Code and Codex CLI.

use chrono::{DateTime, Datelike, Local, LocalResult, NaiveDate, TimeDelta, TimeZone};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::fs::{self, File};
use std::io::{BufRead, BufReader};
use std::path::PathBuf;

// ─── Public types ─────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProviderUsageSnapshot {
    pub provider: String,
    pub status: String,
    pub error_message: Option<String>,
    pub days: Vec<DailyTokenUsage>,
    pub totals: UsageSummary,
    pub top_models: Vec<ModelShare>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DailyTokenUsage {
    pub date: String,
    pub input_tokens: i64,
    pub output_tokens: i64,
    pub cache_read_tokens: i64,
    pub cache_write_tokens: i64,
    pub requests: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UsageSummary {
    pub total_input_tokens: i64,
    pub total_output_tokens: i64,
    pub total_cache_read_tokens: i64,
    pub total_cache_write_tokens: i64,
    pub total_requests: i64,
    pub avg_daily_tokens: i64,
    pub peak_day: Option<String>,
    pub peak_day_tokens: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelShare {
    pub model: String,
    pub tokens: i64,
    pub share_percent: f64,
}

// ─── Entry point ──────────────────────────────────────────────────────────────

/// Scans both Claude Code and Codex CLI local JSONL data and returns usage snapshots.
pub async fn get_local_usage(days: Option<i64>) -> Vec<ProviderUsageSnapshot> {
    let window = LocalUsageWindow::rolling(days.unwrap_or(30).clamp(1, 90) as u32);
    get_local_usage_window(window).await
}

/// Scans local usage for an explicit inclusive date range.
pub async fn get_local_usage_for_dates(
    from: Option<String>,
    to: Option<String>,
) -> Vec<ProviderUsageSnapshot> {
    let window = LocalUsageWindow::from_params(from, to);
    get_local_usage_window(window).await
}

async fn get_local_usage_window(window: LocalUsageWindow) -> Vec<ProviderUsageSnapshot> {
    tokio::task::spawn_blocking(move || vec![scan_claude_usage(&window), scan_codex_usage(&window)])
        .await
        .unwrap_or_else(|_| vec![])
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

#[derive(Debug, Clone)]
struct LocalUsageWindow {
    day_keys: Vec<String>,
    start_secs: i64,
    end_secs: i64,
}

impl LocalUsageWindow {
    fn rolling(days: u32) -> Self {
        let end = Local::now().date_naive();
        let start = end - TimeDelta::days(days as i64 - 1);
        Self::from_dates(start, end)
    }

    fn from_params(from: Option<String>, to: Option<String>) -> Self {
        let default = Self::rolling(30);
        let mut start = from
            .as_deref()
            .and_then(parse_local_usage_date)
            .unwrap_or_else(|| {
                parse_local_usage_date(&default.day_keys[0]).unwrap_or(Local::now().date_naive())
            });
        let mut end = to
            .as_deref()
            .and_then(parse_local_usage_date)
            .unwrap_or_else(|| {
                default
                    .day_keys
                    .last()
                    .and_then(|value| parse_local_usage_date(value))
                    .unwrap_or_else(|| Local::now().date_naive())
            });
        if start > end {
            std::mem::swap(&mut start, &mut end);
        }
        Self::from_dates(start, end)
    }

    fn from_dates(start: NaiveDate, end: NaiveDate) -> Self {
        Self {
            day_keys: make_day_keys_between(start, end),
            start_secs: local_day_boundary_secs(start, false),
            end_secs: local_day_boundary_secs(end, true),
        }
    }

    fn contains(&self, ts_secs: i64) -> bool {
        ts_secs >= self.start_secs && ts_secs <= self.end_secs
    }
}

/// Parse an ISO 8601 / RFC 3339 timestamp string into milliseconds since epoch.
fn read_timestamp_ms(ts: &str) -> Option<i64> {
    DateTime::parse_from_rfc3339(ts)
        .ok()
        .map(|dt| dt.timestamp_millis())
}

/// Convert a millisecond timestamp to a local YYYY-MM-DD date key.
fn day_key_for_timestamp(ts_ms: i64) -> String {
    let secs = ts_ms / 1_000;
    let nanos = ((ts_ms % 1_000) * 1_000_000) as u32;
    let utc = DateTime::from_timestamp(secs, nanos).unwrap_or_default();
    let local = utc.with_timezone(&Local);
    local.format("%Y-%m-%d").to_string()
}

fn parse_local_usage_date(value: &str) -> Option<NaiveDate> {
    NaiveDate::parse_from_str(value, "%Y-%m-%d").ok()
}

/// Build an ordered list of YYYY-MM-DD date keys for an inclusive local date range.
fn make_day_keys_between(start: NaiveDate, end: NaiveDate) -> Vec<String> {
    let span = (end - start).num_days().max(0);
    (0..=span)
        .map(|offset| {
            let date = start + TimeDelta::days(offset);
            date.format("%Y-%m-%d").to_string()
        })
        .collect()
}

/// Convert a YYYY-MM-DD key to the Codex sessions subdirectory path component (YYYY/MM/DD).
fn day_dir_for_key(key: &str) -> Option<String> {
    NaiveDate::parse_from_str(key, "%Y-%m-%d")
        .ok()
        .map(|d| format!("{}/{:02}/{:02}", d.year(), d.month(), d.day()))
}

fn local_day_boundary_secs(date: NaiveDate, end_of_day: bool) -> i64 {
    let time = if end_of_day {
        date.and_hms_milli_opt(23, 59, 59, 999).unwrap()
    } else {
        date.and_hms_opt(0, 0, 0).unwrap()
    };
    match Local.from_local_datetime(&time) {
        LocalResult::Single(dt) => dt.timestamp(),
        LocalResult::Ambiguous(first, second) => {
            if end_of_day {
                second.timestamp()
            } else {
                first.timestamp()
            }
        }
        LocalResult::None => 0,
    }
}

// ─── Shared accumulator types ─────────────────────────────────────────────────

#[derive(Default)]
struct DayAccum {
    input_tokens: i64,
    output_tokens: i64,
    cache_read_tokens: i64,
    cache_write_tokens: i64,
    requests: i64,
}

fn build_snapshot(
    provider: &str,
    day_keys: &[String],
    day_map: HashMap<String, DayAccum>,
    model_tokens: HashMap<String, i64>,
) -> ProviderUsageSnapshot {
    // Build ordered daily list
    let days: Vec<DailyTokenUsage> = day_keys
        .iter()
        .map(|key| {
            let a = day_map.get(key);
            DailyTokenUsage {
                date: key.clone(),
                input_tokens: a.map_or(0, |d| d.input_tokens),
                output_tokens: a.map_or(0, |d| d.output_tokens),
                cache_read_tokens: a.map_or(0, |d| d.cache_read_tokens),
                cache_write_tokens: a.map_or(0, |d| d.cache_write_tokens),
                requests: a.map_or(0, |d| d.requests),
            }
        })
        .collect();

    // Totals
    let total_input = days.iter().map(|d| d.input_tokens).sum::<i64>();
    let total_output = days.iter().map(|d| d.output_tokens).sum::<i64>();
    let total_cache_read = days.iter().map(|d| d.cache_read_tokens).sum::<i64>();
    let total_cache_write = days.iter().map(|d| d.cache_write_tokens).sum::<i64>();
    let total_requests = days.iter().map(|d| d.requests).sum::<i64>();

    let num_days = day_keys.len() as i64;
    let total_all = total_input + total_output;
    let avg_daily_tokens = if num_days > 0 {
        total_all / num_days
    } else {
        0
    };

    let (peak_day, peak_day_tokens) = days
        .iter()
        .map(|d| (d.date.clone(), d.input_tokens + d.output_tokens))
        .max_by_key(|(_, t)| *t)
        .map(|(date, tokens)| (Some(date), tokens))
        .unwrap_or((None, 0));

    // Top 5 models by total tokens
    let grand_total_model: i64 = model_tokens.values().sum();
    let mut model_list: Vec<(String, i64)> = model_tokens.into_iter().collect();
    model_list.sort_by(|a, b| b.1.cmp(&a.1));
    let top_models: Vec<ModelShare> = model_list
        .into_iter()
        .take(5)
        .map(|(model, tokens)| {
            let share_percent = if grand_total_model > 0 {
                (tokens as f64 / grand_total_model as f64) * 100.0
            } else {
                0.0
            };
            ModelShare {
                model,
                tokens,
                share_percent,
            }
        })
        .collect();

    let status = if total_requests == 0 {
        "no_data".to_string()
    } else {
        "ok".to_string()
    };

    ProviderUsageSnapshot {
        provider: provider.to_string(),
        status,
        error_message: None,
        days,
        totals: UsageSummary {
            total_input_tokens: total_input,
            total_output_tokens: total_output,
            total_cache_read_tokens: total_cache_read,
            total_cache_write_tokens: total_cache_write,
            total_requests,
            avg_daily_tokens,
            peak_day,
            peak_day_tokens,
        },
        top_models,
    }
}

fn error_snapshot(provider: &str, msg: impl Into<String>) -> ProviderUsageSnapshot {
    ProviderUsageSnapshot {
        provider: provider.to_string(),
        status: "error".to_string(),
        error_message: Some(msg.into()),
        days: vec![],
        totals: UsageSummary {
            total_input_tokens: 0,
            total_output_tokens: 0,
            total_cache_read_tokens: 0,
            total_cache_write_tokens: 0,
            total_requests: 0,
            avg_daily_tokens: 0,
            peak_day: None,
            peak_day_tokens: 0,
        },
        top_models: vec![],
    }
}

// ─── Claude Code scanner ──────────────────────────────────────────────────────

fn scan_claude_usage(window: &LocalUsageWindow) -> ProviderUsageSnapshot {
    let home = match std::env::var_os("HOME") {
        Some(h) => PathBuf::from(h),
        None => return error_snapshot("claude", "HOME env var not set"),
    };

    let projects_dir = home.join(".claude").join("projects");
    if !projects_dir.exists() {
        return ProviderUsageSnapshot {
            provider: "claude".to_string(),
            status: "no_data".to_string(),
            error_message: None,
            days: vec![],
            totals: UsageSummary {
                total_input_tokens: 0,
                total_output_tokens: 0,
                total_cache_read_tokens: 0,
                total_cache_write_tokens: 0,
                total_requests: 0,
                avg_daily_tokens: 0,
                peak_day: None,
                peak_day_tokens: 0,
            },
            top_models: vec![],
        };
    }

    let mut day_map: HashMap<String, DayAccum> = HashMap::new();
    let mut model_tokens: HashMap<String, i64> = HashMap::new();

    // Enumerate all <slug>/<session-id>.jsonl files
    let slug_iter = match fs::read_dir(&projects_dir) {
        Ok(it) => it,
        Err(e) => return error_snapshot("claude", e.to_string()),
    };

    for slug_entry in slug_iter.flatten() {
        let slug_path = slug_entry.path();
        if !slug_path.is_dir() {
            continue;
        }

        let file_iter = match fs::read_dir(&slug_path) {
            Ok(it) => it,
            Err(_) => continue,
        };

        for file_entry in file_iter.flatten() {
            let file_path = file_entry.path();
            let ext = file_path.extension().and_then(|e| e.to_str()).unwrap_or("");
            if ext != "jsonl" {
                continue;
            }

            // Skip files older than cutoff via mtime
            if let Ok(meta) = file_entry.metadata() {
                if let Ok(mtime) = meta.modified() {
                    let mtime_secs = mtime
                        .duration_since(std::time::UNIX_EPOCH)
                        .map(|d| d.as_secs() as i64)
                        .unwrap_or(0);
                    if mtime_secs < window.start_secs {
                        continue;
                    }
                }
            }

            parse_claude_file(&file_path, window, &mut day_map, &mut model_tokens);
        }
    }

    build_snapshot("claude", &window.day_keys, day_map, model_tokens)
}

fn parse_claude_file(
    path: &std::path::Path,
    window: &LocalUsageWindow,
    day_map: &mut HashMap<String, DayAccum>,
    model_tokens: &mut HashMap<String, i64>,
) {
    let file = match File::open(path) {
        Ok(f) => f,
        Err(_) => return,
    };
    let reader = BufReader::new(file);
    let day_set: HashSet<&str> = window.day_keys.iter().map(|s| s.as_str()).collect();

    for line in reader.lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => continue,
        };
        // Skip lines larger than 512 KB
        if line.len() > 512 * 1024 {
            continue;
        }
        if line.trim().is_empty() {
            continue;
        }

        let obj: Value = match serde_json::from_str(&line) {
            Ok(v) => v,
            Err(_) => continue,
        };

        // Only process "assistant" type entries
        if obj.get("type").and_then(|v| v.as_str()) != Some("assistant") {
            continue;
        }

        // Extract and validate timestamp
        let ts_str = match obj.get("timestamp").and_then(|v| v.as_str()) {
            Some(s) => s,
            None => continue,
        };
        let ts_ms = match read_timestamp_ms(ts_str) {
            Some(ms) => ms,
            None => continue,
        };
        let ts_secs = ts_ms / 1_000;
        if !window.contains(ts_secs) {
            continue;
        }

        let day_key = day_key_for_timestamp(ts_ms);
        if !day_set.contains(day_key.as_str()) {
            continue;
        }

        // Extract message object
        let message = match obj.get("message") {
            Some(m) => m,
            None => continue,
        };

        // Extract usage
        let usage = match message.get("usage") {
            Some(u) => u,
            None => continue,
        };

        let input_tokens = usage
            .get("input_tokens")
            .and_then(|v| v.as_i64())
            .unwrap_or(0);
        let cache_creation = usage
            .get("cache_creation_input_tokens")
            .and_then(|v| v.as_i64())
            .unwrap_or(0);
        let cache_read = usage
            .get("cache_read_input_tokens")
            .and_then(|v| v.as_i64())
            .unwrap_or(0);
        let output_tokens = usage
            .get("output_tokens")
            .and_then(|v| v.as_i64())
            .unwrap_or(0);

        // Extract model
        let model = message
            .get("model")
            .and_then(|v| v.as_str())
            .unwrap_or("unknown")
            .to_string();

        // Accumulate into day bucket
        let entry = day_map.entry(day_key).or_default();
        entry.input_tokens += input_tokens;
        entry.output_tokens += output_tokens;
        entry.cache_read_tokens += cache_read;
        entry.cache_write_tokens += cache_creation;
        entry.requests += 1;

        // Accumulate model tokens (input + output)
        let model_entry = model_tokens.entry(model).or_insert(0);
        *model_entry += input_tokens + output_tokens;
    }
}

// ─── Codex CLI scanner ────────────────────────────────────────────────────────

fn scan_codex_usage(window: &LocalUsageWindow) -> ProviderUsageSnapshot {
    let home = match std::env::var_os("HOME") {
        Some(h) => PathBuf::from(h),
        None => return error_snapshot("codex", "HOME env var not set"),
    };

    let sessions_dir = home.join(".codex").join("sessions");
    if !sessions_dir.exists() {
        return ProviderUsageSnapshot {
            provider: "codex".to_string(),
            status: "no_data".to_string(),
            error_message: None,
            days: vec![],
            totals: UsageSummary {
                total_input_tokens: 0,
                total_output_tokens: 0,
                total_cache_read_tokens: 0,
                total_cache_write_tokens: 0,
                total_requests: 0,
                avg_daily_tokens: 0,
                peak_day: None,
                peak_day_tokens: 0,
            },
            top_models: vec![],
        };
    }

    let mut day_map: HashMap<String, DayAccum> = HashMap::new();
    let mut model_tokens: HashMap<String, i64> = HashMap::new();

    for key in &window.day_keys {
        let dir_suffix = match day_dir_for_key(key) {
            Some(s) => s,
            None => continue,
        };
        let day_dir = sessions_dir.join(&dir_suffix);
        if !day_dir.is_dir() {
            continue;
        }

        let file_iter = match fs::read_dir(&day_dir) {
            Ok(it) => it,
            Err(_) => continue,
        };

        for file_entry in file_iter.flatten() {
            let file_path = file_entry.path();
            let ext = file_path.extension().and_then(|e| e.to_str()).unwrap_or("");
            if ext != "jsonl" {
                continue;
            }

            parse_codex_file(&file_path, window, key, &mut day_map, &mut model_tokens);
        }
    }

    build_snapshot("codex", &window.day_keys, day_map, model_tokens)
}

/// Per-session delta tracking state for Codex cumulative totals.
#[derive(Default)]
struct CodexSessionState {
    last_total_input: i64,
    last_total_cached_input: i64,
    last_total_output: i64,
}

fn parse_codex_file(
    path: &std::path::Path,
    window: &LocalUsageWindow,
    day_key: &str,
    day_map: &mut HashMap<String, DayAccum>,
    model_tokens: &mut HashMap<String, i64>,
) {
    let file = match File::open(path) {
        Ok(f) => f,
        Err(_) => return,
    };
    let reader = BufReader::new(file);

    // Delta-tracking state (cumulative totals are per session file)
    let mut session_state = CodexSessionState::default();
    let mut current_model: String = "unknown".to_string();

    for line in reader.lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => continue,
        };
        // Skip lines larger than 512 KB
        if line.len() > 512 * 1024 {
            continue;
        }
        if line.trim().is_empty() {
            continue;
        }

        let obj: Value = match serde_json::from_str(&line) {
            Ok(v) => v,
            Err(_) => continue,
        };

        // Validate timestamp
        let ts_str = match obj.get("timestamp").and_then(|v| v.as_str()) {
            Some(s) => s,
            None => continue,
        };
        let ts_ms = match read_timestamp_ms(ts_str) {
            Some(ms) => ms,
            None => continue,
        };
        if !window.contains(ts_ms / 1_000) {
            continue;
        }

        let event_type = obj.get("type").and_then(|v| v.as_str()).unwrap_or("");
        let payload = obj.get("payload");

        match event_type {
            "turn_context" => {
                // Extract current model for this session
                if let Some(model) = payload
                    .and_then(|p| p.get("model"))
                    .and_then(|v| v.as_str())
                {
                    current_model = model.to_string();
                }
            }
            "event_msg" => {
                let payload_type = payload
                    .and_then(|p| p.get("type"))
                    .and_then(|v| v.as_str())
                    .unwrap_or("");

                if payload_type == "token_count" {
                    let info = match payload.and_then(|p| p.get("info")) {
                        Some(i) => i,
                        None => continue,
                    };
                    let total_usage = match info.get("total_token_usage") {
                        Some(u) => u,
                        None => continue,
                    };

                    let new_total_input = total_usage
                        .get("input_tokens")
                        .and_then(|v| v.as_i64())
                        .unwrap_or(0);
                    let new_total_cached_input = total_usage
                        .get("cached_input_tokens")
                        .and_then(|v| v.as_i64())
                        .unwrap_or(0);
                    let new_total_output = total_usage
                        .get("output_tokens")
                        .and_then(|v| v.as_i64())
                        .unwrap_or(0);

                    // Compute deltas to avoid double-counting cumulative totals
                    let delta_input = (new_total_input - session_state.last_total_input).max(0);
                    let delta_cached_input =
                        (new_total_cached_input - session_state.last_total_cached_input).max(0);
                    let delta_output = (new_total_output - session_state.last_total_output).max(0);

                    // Update tracking state
                    session_state.last_total_input = new_total_input;
                    session_state.last_total_cached_input = new_total_cached_input;
                    session_state.last_total_output = new_total_output;

                    if delta_input == 0 && delta_cached_input == 0 && delta_output == 0 {
                        continue;
                    }

                    // Accumulate into day bucket
                    let entry = day_map.entry(day_key.to_string()).or_default();
                    // Non-cached input = total input minus cached input
                    let non_cached_input = delta_input.saturating_sub(delta_cached_input);
                    entry.input_tokens += non_cached_input;
                    entry.output_tokens += delta_output;
                    entry.cache_read_tokens += delta_cached_input;
                    // Codex does not expose a separate cache_write figure
                    // requests is counted from response_item assistant messages below

                    // Accumulate model tokens
                    let model_entry = model_tokens.entry(current_model.clone()).or_insert(0);
                    *model_entry += non_cached_input + delta_output;
                }
            }
            "response_item" => {
                // Some Codex versions emit response_item at the top level
                let role = payload
                    .and_then(|p| p.get("role"))
                    .and_then(|v| v.as_str())
                    .unwrap_or("");
                if role == "assistant" {
                    let entry = day_map.entry(day_key.to_string()).or_default();
                    entry.requests += 1;
                }
            }
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn explicit_window_swaps_dates_and_preserves_all_days() {
        let window = LocalUsageWindow::from_params(
            Some("2026-03-08".to_string()),
            Some("2026-03-01".to_string()),
        );

        assert_eq!(
            window.day_keys.first().map(String::as_str),
            Some("2026-03-01")
        );
        assert_eq!(
            window.day_keys.last().map(String::as_str),
            Some("2026-03-08")
        );
        assert_eq!(window.day_keys.len(), 8);
    }

    #[test]
    fn rolling_window_uses_requested_day_count() {
        let window = LocalUsageWindow::rolling(7);
        assert_eq!(window.day_keys.len(), 7);
    }
}
