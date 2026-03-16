// usage_local.rs — Scans local JSONL session files from Claude Code and Codex CLI.

use chrono::{DateTime, Datelike, Local, LocalResult, NaiveDate, TimeDelta, TimeZone};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::fs::{self, File};
use std::io::{BufRead, BufReader};
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};

// ─── Public types ─────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProviderUsageSnapshot {
    pub provider: String,
    pub status: String,
    pub error_message: Option<String>,
    pub days: Vec<DailyTokenUsage>,
    pub totals: UsageSummary,
    pub top_models: Vec<ModelShare>,
    #[serde(default)]
    pub total_estimated_cost_usd: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DailyTokenUsage {
    pub date: String,
    pub input_tokens: i64,
    pub output_tokens: i64,
    pub cache_read_tokens: i64,
    pub cache_write_tokens: i64,
    pub requests: i64,
    #[serde(default)]
    pub estimated_cost_usd: f64,
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
    #[serde(default)]
    pub estimated_cost_usd: f64,
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

#[derive(Default, Clone)]
struct DayAccum {
    input_tokens: i64,
    output_tokens: i64,
    cache_read_tokens: i64,
    cache_write_tokens: i64,
    requests: i64,
    estimated_cost_usd: f64,
}

// ─── Incremental scan cache ──────────────────────────────────────────────────

#[derive(Clone)]
struct CachedFileResult {
    mtime_secs: i64,
    size: u64,
    day_contributions: HashMap<String, DayAccum>,
    model_token_contributions: HashMap<String, i64>,
    model_cost_contributions: HashMap<String, f64>,
}

struct ScanCache {
    files: HashMap<String, CachedFileResult>,
}

static SCAN_CACHE: OnceLock<Mutex<ScanCache>> = OnceLock::new();

fn file_mtime_and_size(path: &std::path::Path) -> Option<(i64, u64)> {
    let meta = path.metadata().ok()?;
    let mtime = meta
        .modified()
        .ok()?
        .duration_since(std::time::UNIX_EPOCH)
        .ok()?
        .as_secs() as i64;
    Some((mtime, meta.len()))
}

fn lookup_cached_file(path: &str, mtime: i64, size: u64) -> Option<CachedFileResult> {
    let cache = SCAN_CACHE.get_or_init(|| {
        Mutex::new(ScanCache {
            files: HashMap::new(),
        })
    });
    let guard = cache.lock().ok()?;
    let entry = guard.files.get(path)?;
    if entry.mtime_secs == mtime && entry.size == size {
        Some(entry.clone())
    } else {
        None
    }
}

fn store_cached_file(
    path: String,
    mtime: i64,
    size: u64,
    days: HashMap<String, DayAccum>,
    tokens: HashMap<String, i64>,
    costs: HashMap<String, f64>,
) {
    if let Some(cache) = SCAN_CACHE.get() {
        if let Ok(mut guard) = cache.lock() {
            guard.files.insert(
                path,
                CachedFileResult {
                    mtime_secs: mtime,
                    size,
                    day_contributions: days,
                    model_token_contributions: tokens,
                    model_cost_contributions: costs,
                },
            );
        }
    }
}

fn merge_cached_contributions(
    cached: &CachedFileResult,
    day_map: &mut HashMap<String, DayAccum>,
    model_tokens: &mut HashMap<String, i64>,
    model_costs: &mut HashMap<String, f64>,
    day_keys: &[String],
) {
    let day_set: HashSet<&str> = day_keys.iter().map(|s| s.as_str()).collect();
    for (key, accum) in &cached.day_contributions {
        if !day_set.contains(key.as_str()) {
            continue;
        }
        let entry = day_map.entry(key.clone()).or_default();
        entry.input_tokens += accum.input_tokens;
        entry.output_tokens += accum.output_tokens;
        entry.cache_read_tokens += accum.cache_read_tokens;
        entry.cache_write_tokens += accum.cache_write_tokens;
        entry.requests += accum.requests;
        entry.estimated_cost_usd += accum.estimated_cost_usd;
    }
    merge_i64_maps(&cached.model_token_contributions, model_tokens);
    merge_f64_maps(&cached.model_cost_contributions, model_costs);
}

fn merge_day_maps(src: &HashMap<String, DayAccum>, dst: &mut HashMap<String, DayAccum>) {
    for (key, accum) in src {
        let entry = dst.entry(key.clone()).or_default();
        entry.input_tokens += accum.input_tokens;
        entry.output_tokens += accum.output_tokens;
        entry.cache_read_tokens += accum.cache_read_tokens;
        entry.cache_write_tokens += accum.cache_write_tokens;
        entry.requests += accum.requests;
        entry.estimated_cost_usd += accum.estimated_cost_usd;
    }
}

fn merge_i64_maps(src: &HashMap<String, i64>, dst: &mut HashMap<String, i64>) {
    for (key, val) in src {
        *dst.entry(key.clone()).or_insert(0) += val;
    }
}

fn merge_f64_maps(src: &HashMap<String, f64>, dst: &mut HashMap<String, f64>) {
    for (key, val) in src {
        *dst.entry(key.clone()).or_insert(0.0) += val;
    }
}

// ─── Pricing helpers ─────────────────────────────────────────────────────────

/// Claude model pricing: (input, output, cache_create, cache_read) $/token.
/// Prices from codexbar v0.18 / Anthropic public pricing.
fn claude_pricing(model: &str) -> Option<(f64, f64, f64, f64)> {
    match model {
        "claude-opus-4-6" | "claude-opus-4-5" => Some((5e-6, 2.5e-5, 6.25e-6, 5e-7)),
        "claude-opus-4-1" => Some((1.5e-5, 7.5e-5, 1.875e-5, 1.5e-6)),
        "claude-sonnet-4-5" | "claude-sonnet-4-6" => Some((3e-6, 1.5e-5, 3.75e-6, 3e-7)),
        "claude-haiku-4-5" => Some((1e-6, 5e-6, 1.25e-6, 1e-7)),
        _ => None,
    }
}

/// Codex/OpenAI model pricing: (input, output, cache_read) $/token.
/// Prices from codexbar v0.18 GPT-5.x pricing tables.
fn codex_pricing(model: &str) -> Option<(f64, f64, f64)> {
    match model {
        "gpt-5" | "gpt-5-codex" | "gpt-5.1" | "gpt-5.1-codex" | "gpt-5.1-codex-max" => {
            Some((1.25e-6, 1e-5, 1.25e-7))
        }
        "gpt-5-mini" | "gpt-5.1-codex-mini" => Some((2.5e-7, 2e-6, 2.5e-8)),
        "gpt-5-nano" => Some((5e-8, 4e-7, 5e-9)),
        "gpt-5-pro" => Some((1.5e-5, 1.2e-4, 1.5e-5)),
        "gpt-5.2" | "gpt-5.2-codex" | "gpt-5.3-codex" => Some((1.75e-6, 1.4e-5, 1.75e-7)),
        "gpt-5.2-pro" => Some((2.1e-5, 1.68e-4, 2.1e-5)),
        "gpt-5.4" => Some((2.5e-6, 1.5e-5, 2.5e-7)),
        "gpt-5.4-pro" => Some((3e-5, 1.8e-4, 3e-5)),
        "gpt-5.3-codex-spark" => Some((0.0, 0.0, 0.0)),
        _ => None,
    }
}

/// Normalize Claude model name: strip vendor prefix, version/date suffixes.
fn normalize_claude_model(model: &str) -> String {
    let mut s = model.trim().to_string();
    if let Some(rest) = s.strip_prefix("anthropic.") {
        s = rest.to_string();
    }
    // Strip ":N" version suffix
    if let Some(idx) = s.rfind(':') {
        if s[idx + 1..].chars().all(|c| c.is_ascii_digit()) {
            s.truncate(idx);
        }
    }
    // Strip YYYYMMDD date suffix if base is a known model
    if let Some(idx) = s.rfind('-') {
        let tail = &s[idx + 1..];
        if tail.len() == 8
            && tail.chars().all(|c| c.is_ascii_digit())
            && claude_pricing(&s[..idx]).is_some()
        {
            return s[..idx].to_string();
        }
    }
    s
}

/// Normalize Codex model name: strip openai/ prefix and YYYY-MM-DD date suffix.
fn normalize_codex_model(model: &str) -> String {
    let mut s = model.trim().to_string();
    if let Some(rest) = s.strip_prefix("openai/") {
        s = rest.to_string();
    }
    // Strip -YYYY-MM-DD date suffix if base is a known model
    if s.len() > 11 {
        let tail = &s[s.len() - 10..];
        if tail.as_bytes().get(4) == Some(&b'-')
            && tail.as_bytes().get(7) == Some(&b'-')
            && tail
                .bytes()
                .filter(|b| *b != b'-')
                .all(|b| b.is_ascii_digit())
            && codex_pricing(&s[..s.len() - 11]).is_some()
        {
            return s[..s.len() - 11].to_string();
        }
    }
    s
}

/// Calculate Claude cost in USD from token deltas.
fn claude_cost_usd(
    model: &str,
    input_tokens: i64,
    output_tokens: i64,
    cache_read_tokens: i64,
    cache_creation_tokens: i64,
) -> f64 {
    let key = normalize_claude_model(model);
    let Some((ir, or, cwr, crr)) = claude_pricing(&key) else {
        return 0.0;
    };
    input_tokens.max(0) as f64 * ir
        + output_tokens.max(0) as f64 * or
        + cache_read_tokens.max(0) as f64 * crr
        + cache_creation_tokens.max(0) as f64 * cwr
}

/// Calculate Codex cost in USD from token deltas.
fn codex_cost_usd(
    model: &str,
    input_tokens: i64,
    output_tokens: i64,
    cached_input_tokens: i64,
) -> f64 {
    let key = normalize_codex_model(model);
    let Some((ir, or, crr)) = codex_pricing(&key) else {
        return 0.0;
    };
    let non_cached = (input_tokens - cached_input_tokens).max(0);
    non_cached as f64 * ir
        + cached_input_tokens.max(0) as f64 * crr
        + output_tokens.max(0) as f64 * or
}

fn build_snapshot(
    provider: &str,
    day_keys: &[String],
    day_map: HashMap<String, DayAccum>,
    model_tokens: HashMap<String, i64>,
    model_costs: HashMap<String, f64>,
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
                estimated_cost_usd: a.map_or(0.0, |d| d.estimated_cost_usd),
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
            let estimated_cost_usd = model_costs.get(&model).copied().unwrap_or(0.0);
            ModelShare {
                model,
                tokens,
                share_percent,
                estimated_cost_usd,
            }
        })
        .collect();

    let status = if total_requests == 0 {
        "no_data".to_string()
    } else {
        "ok".to_string()
    };

    let total_estimated_cost_usd: f64 = days.iter().map(|d| d.estimated_cost_usd).sum();

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
        total_estimated_cost_usd,
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
        total_estimated_cost_usd: 0.0,
    }
}

// ─── Claude Code scanner ──────────────────────────────────────────────────────

fn scan_claude_usage(window: &LocalUsageWindow) -> ProviderUsageSnapshot {
    let project_roots = match claude_project_roots() {
        Ok(roots) => roots,
        Err(message) => return error_snapshot("claude", message),
    };

    if project_roots.is_empty() {
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
            total_estimated_cost_usd: 0.0,
        };
    }

    let mut day_map: HashMap<String, DayAccum> = HashMap::new();
    let mut model_tokens: HashMap<String, i64> = HashMap::new();
    let mut model_costs: HashMap<String, f64> = HashMap::new();

    for projects_dir in project_roots {
        let slug_iter = match fs::read_dir(&projects_dir) {
            Ok(it) => it,
            Err(_) => continue,
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

                parse_claude_file(
                    &file_path,
                    window,
                    &mut day_map,
                    &mut model_tokens,
                    &mut model_costs,
                );
            }
        }
    }

    build_snapshot(
        "claude",
        &window.day_keys,
        day_map,
        model_tokens,
        model_costs,
    )
}

fn parse_claude_file(
    path: &std::path::Path,
    window: &LocalUsageWindow,
    day_map: &mut HashMap<String, DayAccum>,
    model_tokens: &mut HashMap<String, i64>,
    model_costs: &mut HashMap<String, f64>,
) {
    let (mtime_secs, file_size) = match file_mtime_and_size(path) {
        Some(v) => v,
        None => return,
    };
    let path_str = path.to_string_lossy().to_string();

    // Check cache — if file unchanged, merge cached contributions and skip parsing
    if let Some(cached) = lookup_cached_file(&path_str, mtime_secs, file_size) {
        merge_cached_contributions(
            &cached,
            day_map,
            model_tokens,
            model_costs,
            &window.day_keys,
        );
        return;
    }

    let file = match File::open(path) {
        Ok(f) => f,
        Err(_) => return,
    };
    let reader = BufReader::new(file);
    let day_set: HashSet<&str> = window.day_keys.iter().map(|s| s.as_str()).collect();
    let mut dedupe_state: HashMap<String, (i64, i64, i64, i64)> = HashMap::new();

    // Parse into local maps so we can cache the per-file contributions
    let mut local_days: HashMap<String, DayAccum> = HashMap::new();
    let mut local_model_tokens: HashMap<String, i64> = HashMap::new();
    let mut local_model_costs: HashMap<String, f64> = HashMap::new();

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

        let request_id = obj
            .get("requestId")
            .or_else(|| obj.get("request_id"))
            .and_then(|v| v.as_str())
            .unwrap_or("");
        let message_id = message.get("id").and_then(|v| v.as_str()).unwrap_or("");
        let dedupe_key = if !message_id.is_empty() || !request_id.is_empty() {
            format!("{message_id}:{request_id}")
        } else {
            format!("timestamp:{ts_ms}")
        };
        let previous = dedupe_state
            .get(&dedupe_key)
            .copied()
            .unwrap_or((0, 0, 0, 0));
        dedupe_state.insert(
            dedupe_key,
            (input_tokens, output_tokens, cache_read, cache_creation),
        );
        let delta_input_tokens = (input_tokens - previous.0).max(0);
        let delta_output_tokens = (output_tokens - previous.1).max(0);
        let delta_cache_read = (cache_read - previous.2).max(0);
        let delta_cache_creation = (cache_creation - previous.3).max(0);
        if delta_input_tokens == 0
            && delta_output_tokens == 0
            && delta_cache_read == 0
            && delta_cache_creation == 0
        {
            continue;
        }

        // Extract model
        let model = message
            .get("model")
            .and_then(|v| v.as_str())
            .unwrap_or("unknown")
            .to_string();

        // Compute cost for this delta
        let cost = claude_cost_usd(
            &model,
            delta_input_tokens,
            delta_output_tokens,
            delta_cache_read,
            delta_cache_creation,
        );

        // Accumulate into local day bucket
        let entry = local_days.entry(day_key).or_default();
        entry.input_tokens += delta_input_tokens;
        entry.output_tokens += delta_output_tokens;
        entry.cache_read_tokens += delta_cache_read;
        entry.cache_write_tokens += delta_cache_creation;
        entry.requests += 1;
        entry.estimated_cost_usd += cost;

        // Accumulate local model tokens (input + output) and cost
        *local_model_tokens.entry(model.clone()).or_insert(0) +=
            delta_input_tokens + delta_output_tokens;
        *local_model_costs.entry(model).or_insert(0.0) += cost;
    }

    // Merge local into caller maps
    merge_day_maps(&local_days, day_map);
    merge_i64_maps(&local_model_tokens, model_tokens);
    merge_f64_maps(&local_model_costs, model_costs);

    // Store in cache for future scans
    store_cached_file(
        path_str,
        mtime_secs,
        file_size,
        local_days,
        local_model_tokens,
        local_model_costs,
    );
}

// ─── Codex CLI scanner ────────────────────────────────────────────────────────

fn scan_codex_usage(window: &LocalUsageWindow) -> ProviderUsageSnapshot {
    let codex_home = match codex_home_dir() {
        Some(path) => path,
        None => return error_snapshot("codex", "HOME env var not set"),
    };

    let sessions_dir = codex_home.join("sessions");
    let archived_dir = codex_home.join("archived_sessions");
    if !sessions_dir.exists() && !archived_dir.exists() {
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
            total_estimated_cost_usd: 0.0,
        };
    }

    let mut day_map: HashMap<String, DayAccum> = HashMap::new();
    let mut model_tokens: HashMap<String, i64> = HashMap::new();
    let mut model_costs: HashMap<String, f64> = HashMap::new();

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

            parse_codex_file(
                &file_path,
                window,
                key,
                &mut day_map,
                &mut model_tokens,
                &mut model_costs,
            );
        }
    }

    if archived_dir.is_dir() {
        if let Ok(file_iter) = fs::read_dir(&archived_dir) {
            for file_entry in file_iter.flatten() {
                let file_path = file_entry.path();
                let ext = file_path.extension().and_then(|e| e.to_str()).unwrap_or("");
                if ext != "jsonl" {
                    continue;
                }
                parse_codex_file(
                    &file_path,
                    window,
                    "",
                    &mut day_map,
                    &mut model_tokens,
                    &mut model_costs,
                );
            }
        }
    }

    build_snapshot(
        "codex",
        &window.day_keys,
        day_map,
        model_tokens,
        model_costs,
    )
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
    model_costs: &mut HashMap<String, f64>,
) {
    let (mtime_secs, file_size) = match file_mtime_and_size(path) {
        Some(v) => v,
        None => return,
    };
    let path_str = path.to_string_lossy().to_string();

    // Check cache — if file unchanged, merge cached contributions and skip parsing
    if let Some(cached) = lookup_cached_file(&path_str, mtime_secs, file_size) {
        merge_cached_contributions(
            &cached,
            day_map,
            model_tokens,
            model_costs,
            &window.day_keys,
        );
        return;
    }

    let file = match File::open(path) {
        Ok(f) => f,
        Err(_) => return,
    };
    let reader = BufReader::new(file);

    // Parse into local maps so we can cache the per-file contributions
    let mut local_days: HashMap<String, DayAccum> = HashMap::new();
    let mut local_model_tokens: HashMap<String, i64> = HashMap::new();
    let mut local_model_costs: HashMap<String, f64> = HashMap::new();

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
        let resolved_day_key = if day_key.is_empty() {
            day_key_for_timestamp(ts_ms)
        } else {
            day_key.to_string()
        };

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

                    // Non-cached input = total input minus cached input
                    let non_cached_input = delta_input.saturating_sub(delta_cached_input);

                    // Compute cost for this delta (pass full input delta;
                    // codex_cost_usd handles the cache split internally)
                    let cost = codex_cost_usd(
                        &current_model,
                        delta_input,
                        delta_output,
                        delta_cached_input,
                    );

                    // Accumulate into local day bucket
                    let entry = local_days.entry(resolved_day_key.clone()).or_default();
                    entry.input_tokens += non_cached_input;
                    entry.output_tokens += delta_output;
                    entry.cache_read_tokens += delta_cached_input;
                    entry.estimated_cost_usd += cost;
                    // Codex does not expose a separate cache_write figure
                    // requests is counted from response_item assistant messages below

                    // Accumulate local model tokens and cost
                    *local_model_tokens.entry(current_model.clone()).or_insert(0) +=
                        non_cached_input + delta_output;
                    *local_model_costs
                        .entry(current_model.clone())
                        .or_insert(0.0) += cost;
                }
            }
            "response_item" => {
                // Some Codex versions emit response_item at the top level
                let role = payload
                    .and_then(|p| p.get("role"))
                    .and_then(|v| v.as_str())
                    .unwrap_or("");
                if role == "assistant" {
                    let entry = local_days.entry(resolved_day_key).or_default();
                    entry.requests += 1;
                }
            }
            _ => {}
        }
    }

    // Merge local into caller maps
    merge_day_maps(&local_days, day_map);
    merge_i64_maps(&local_model_tokens, model_tokens);
    merge_f64_maps(&local_model_costs, model_costs);

    // Store in cache for future scans
    store_cached_file(
        path_str,
        mtime_secs,
        file_size,
        local_days,
        local_model_tokens,
        local_model_costs,
    );
}

fn claude_project_roots() -> Result<Vec<PathBuf>, String> {
    let mut roots = Vec::new();
    if let Some(raw) = std::env::var_os("CLAUDE_CONFIG_DIR") {
        for part in raw.to_string_lossy().split(',') {
            let trimmed = part.trim();
            if !trimmed.is_empty() {
                roots.push(PathBuf::from(trimmed).join("projects"));
            }
        }
    }

    let home = match std::env::var_os("HOME") {
        Some(h) => PathBuf::from(h),
        None => return Err("HOME env var not set".to_string()),
    };
    roots.push(home.join(".config").join("claude").join("projects"));
    roots.push(home.join(".claude").join("projects"));
    roots.retain(|path| path.is_dir());
    roots.sort();
    roots.dedup();
    Ok(roots)
}

fn codex_home_dir() -> Option<PathBuf> {
    if let Some(path) = std::env::var_os("CODEX_HOME") {
        let path = PathBuf::from(path);
        if !path.as_os_str().is_empty() {
            return Some(path);
        }
    }

    std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".codex"))
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
