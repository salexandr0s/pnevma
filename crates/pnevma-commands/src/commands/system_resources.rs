// system_resources.rs — Collects system resource metrics (CPU, memory, process tree).

use crate::state::AppState;
use serde::{Deserialize, Serialize};
use std::sync::{Mutex, OnceLock};
use sysinfo::{Pid, ProcessesToUpdate, System};

// ─── Public types ────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ResourceSnapshot {
    pub timestamp: String,
    pub host: HostInfo,
    pub app: AppResourceGroup,
    pub sessions: Vec<SessionResources>,
    pub totals: ResourceTotals,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HostInfo {
    pub hostname: String,
    pub os_version: String,
    pub cpu_cores: usize,
    pub total_memory_bytes: u64,
    pub uptime_seconds: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProcessMetrics {
    pub pid: u32,
    pub name: String,
    pub cpu_percent: f32,
    pub memory_bytes: u64,
    pub memory_percent: f32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppResourceGroup {
    pub main: ProcessMetrics,
    pub helpers: Vec<ProcessMetrics>,
    pub total_cpu_percent: f32,
    pub total_memory_bytes: u64,
    pub total_memory_percent: f32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionResources {
    pub session_id: String,
    pub session_name: String,
    pub status: String,
    pub process: Option<ProcessMetrics>,
    pub children: Vec<ProcessMetrics>,
    pub total_cpu_percent: f32,
    pub total_memory_bytes: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ResourceTotals {
    pub cpu_percent: f32,
    pub memory_bytes: u64,
    pub memory_percent: f32,
    pub process_count: usize,
}

// ─── Singleton ───────────────────────────────────────────────────────────────

static SYSTEM: OnceLock<Mutex<System>> = OnceLock::new();

fn get_system() -> &'static Mutex<System> {
    SYSTEM.get_or_init(|| Mutex::new(System::new()))
}

// ─── Entry point ─────────────────────────────────────────────────────────────

/// Collects a snapshot of system resource usage: host info, app process tree,
/// session processes, and aggregate totals.
pub async fn get_resource_snapshot(state: &AppState) -> Result<ResourceSnapshot, String> {
    // Gather session metadata (id, name, status, pid) before entering the blocking task.
    let session_meta = collect_session_meta(state).await;

    tokio::task::spawn_blocking(move || build_snapshot(session_meta))
        .await
        .map_err(|e| format!("spawn_blocking failed: {e}"))?
}

// ─── Session metadata ────────────────────────────────────────────────────────

#[derive(Clone)]
struct SessionMeta {
    id: String,
    name: String,
    status: String,
    pid: Option<u32>,
}

async fn collect_session_meta(state: &AppState) -> Vec<SessionMeta> {
    let current = state.current.lock().await;
    let ctx = match current.as_ref() {
        Some(c) => c,
        None => return Vec::new(),
    };

    let project_id = ctx.project_id.to_string();
    let rows = match ctx.db.list_sessions(&project_id).await {
        Ok(r) => r,
        Err(_) => return Vec::new(),
    };

    rows.into_iter()
        .map(|row| SessionMeta {
            id: row.id,
            name: row.name,
            status: row.status,
            pid: row.pid.and_then(|p| u32::try_from(p).ok()),
        })
        .collect()
}

// ─── Snapshot builder (runs on blocking thread) ──────────────────────────────

fn build_snapshot(session_meta: Vec<SessionMeta>) -> Result<ResourceSnapshot, String> {
    let mut sys = get_system()
        .lock()
        .map_err(|e| format!("system mutex poisoned: {e}"))?;

    sys.refresh_processes(ProcessesToUpdate::All, true);
    sys.refresh_memory();

    let total_mem = sys.total_memory();
    let own_pid = Pid::from_u32(std::process::id());

    // ── Host info ────────────────────────────────────────────────────────
    let host = HostInfo {
        hostname: System::host_name().unwrap_or_else(|| "unknown".to_string()),
        os_version: System::long_os_version().unwrap_or_else(|| "unknown".to_string()),
        cpu_cores: sys.cpus().len(),
        total_memory_bytes: total_mem,
        uptime_seconds: System::uptime(),
    };

    // ── App process group ────────────────────────────────────────────────
    let main_metrics = sys
        .process(own_pid)
        .map(|p| process_to_metrics(p, total_mem))
        .unwrap_or_else(|| placeholder_metrics(own_pid.as_u32()));

    let helpers: Vec<ProcessMetrics> = sys
        .processes()
        .values()
        .filter(|p| p.parent() == Some(own_pid))
        .map(|p| process_to_metrics(p, total_mem))
        .collect();

    let app_total_cpu = main_metrics.cpu_percent
        + helpers.iter().map(|h| h.cpu_percent).sum::<f32>();
    let app_total_mem = main_metrics.memory_bytes
        + helpers.iter().map(|h| h.memory_bytes).sum::<u64>();
    let app_total_mem_pct = if total_mem > 0 {
        (app_total_mem as f64 / total_mem as f64 * 100.0) as f32
    } else {
        0.0
    };

    let app = AppResourceGroup {
        main: main_metrics,
        helpers,
        total_cpu_percent: app_total_cpu,
        total_memory_bytes: app_total_mem,
        total_memory_percent: app_total_mem_pct,
    };

    // ── Session processes ────────────────────────────────────────────────
    let sessions: Vec<SessionResources> = session_meta
        .iter()
        .map(|meta| {
            let (process, children) = match meta.pid {
                Some(pid_val) => {
                    let spid = Pid::from_u32(pid_val);
                    let proc_metrics = sys.process(spid).map(|p| process_to_metrics(p, total_mem));
                    let child_metrics: Vec<ProcessMetrics> = sys
                        .processes()
                        .values()
                        .filter(|p| p.parent() == Some(spid))
                        .map(|p| process_to_metrics(p, total_mem))
                        .collect();
                    (proc_metrics, child_metrics)
                }
                None => (None, Vec::new()),
            };

            let total_cpu = process.as_ref().map_or(0.0, |p| p.cpu_percent)
                + children.iter().map(|c| c.cpu_percent).sum::<f32>();
            let total_mem_bytes = process.as_ref().map_or(0, |p| p.memory_bytes)
                + children.iter().map(|c| c.memory_bytes).sum::<u64>();

            SessionResources {
                session_id: meta.id.clone(),
                session_name: meta.name.clone(),
                status: meta.status.clone(),
                process,
                children,
                total_cpu_percent: total_cpu,
                total_memory_bytes: total_mem_bytes,
            }
        })
        .collect();

    // ── Totals ───────────────────────────────────────────────────────────
    let all_session_cpu: f32 = sessions.iter().map(|s| s.total_cpu_percent).sum();
    let all_session_mem: u64 = sessions.iter().map(|s| s.total_memory_bytes).sum();

    let total_cpu = app.total_cpu_percent + all_session_cpu;
    let total_memory = app.total_memory_bytes + all_session_mem;
    let total_memory_pct = if total_mem > 0 {
        (total_memory as f64 / total_mem as f64 * 100.0) as f32
    } else {
        0.0
    };
    let process_count =
        1 + app.helpers.len() + sessions.iter().map(|s| {
            (if s.process.is_some() { 1 } else { 0 }) + s.children.len()
        }).sum::<usize>();

    let totals = ResourceTotals {
        cpu_percent: total_cpu,
        memory_bytes: total_memory,
        memory_percent: total_memory_pct,
        process_count,
    };

    let timestamp = chrono::Utc::now().to_rfc3339();

    Ok(ResourceSnapshot {
        timestamp,
        host,
        app,
        sessions,
        totals,
    })
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

fn process_to_metrics(proc: &sysinfo::Process, total_mem: u64) -> ProcessMetrics {
    let mem = proc.memory();
    let mem_pct = if total_mem > 0 {
        (mem as f64 / total_mem as f64 * 100.0) as f32
    } else {
        0.0
    };
    ProcessMetrics {
        pid: proc.pid().as_u32(),
        name: proc.name().to_string_lossy().to_string(),
        cpu_percent: proc.cpu_usage(),
        memory_bytes: mem,
        memory_percent: mem_pct,
    }
}

fn placeholder_metrics(pid: u32) -> ProcessMetrics {
    ProcessMetrics {
        pid,
        name: "pnevma".to_string(),
        cpu_percent: 0.0,
        memory_bytes: 0,
        memory_percent: 0.0,
    }
}
