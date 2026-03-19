//! Service wrapping `gh run` CLI for CI pipeline operations.

use crate::github_cli;
use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GhRunInfo {
    pub id: i64,
    pub name: String,
    pub status: String,
    pub conclusion: String,
    pub head_sha: String,
    pub html_url: String,
    pub run_number: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GhRunJob {
    pub id: i64,
    pub name: String,
    pub status: String,
    pub conclusion: String,
    pub started_at: String,
    pub completed_at: String,
}

pub struct CiService;

impl CiService {
    /// List recent workflow runs via `gh run list`.
    pub async fn list_runs(cwd: &Path, limit: usize) -> Result<Vec<GhRunInfo>, String> {
        let output = github_cli::command()
            .args([
                "run",
                "list",
                "--limit",
                &limit.to_string(),
                "--json",
                "databaseId,name,status,conclusion,headSha,url,number",
            ])
            .current_dir(cwd)
            .output()
            .await
            .map_err(|e| format!("failed to run gh: {e}"))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(format!("gh run list failed: {stderr}"));
        }

        let stdout = String::from_utf8_lossy(&output.stdout);
        let items: Vec<serde_json::Value> =
            serde_json::from_str(&stdout).map_err(|e| format!("failed to parse gh json: {e}"))?;

        Ok(items
            .iter()
            .map(|v| GhRunInfo {
                id: v["databaseId"].as_i64().unwrap_or(0),
                name: v["name"].as_str().unwrap_or("").to_string(),
                status: v["status"].as_str().unwrap_or("").to_string(),
                conclusion: v["conclusion"].as_str().unwrap_or("").to_string(),
                head_sha: v["headSha"].as_str().unwrap_or("").to_string(),
                html_url: v["url"].as_str().unwrap_or("").to_string(),
                run_number: v["number"].as_i64().unwrap_or(0),
            })
            .collect())
    }

    /// Get details of a specific run via `gh run view`.
    pub async fn get_run(cwd: &Path, run_id: i64) -> Result<GhRunInfo, String> {
        let output = github_cli::command()
            .args([
                "run",
                "view",
                &run_id.to_string(),
                "--json",
                "databaseId,name,status,conclusion,headSha,url,number",
            ])
            .current_dir(cwd)
            .output()
            .await
            .map_err(|e| format!("failed to run gh: {e}"))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(format!("gh run view failed: {stderr}"));
        }

        let stdout = String::from_utf8_lossy(&output.stdout);
        let v: serde_json::Value =
            serde_json::from_str(&stdout).map_err(|e| format!("failed to parse gh json: {e}"))?;

        Ok(GhRunInfo {
            id: v["databaseId"].as_i64().unwrap_or(0),
            name: v["name"].as_str().unwrap_or("").to_string(),
            status: v["status"].as_str().unwrap_or("").to_string(),
            conclusion: v["conclusion"].as_str().unwrap_or("").to_string(),
            head_sha: v["headSha"].as_str().unwrap_or("").to_string(),
            html_url: v["url"].as_str().unwrap_or("").to_string(),
            run_number: v["number"].as_i64().unwrap_or(0),
        })
    }

    /// List jobs for a given run via `gh run view --json jobs`.
    pub async fn list_jobs(cwd: &Path, run_id: i64) -> Result<Vec<GhRunJob>, String> {
        let output = github_cli::command()
            .args(["run", "view", &run_id.to_string(), "--json", "jobs"])
            .current_dir(cwd)
            .output()
            .await
            .map_err(|e| format!("failed to run gh: {e}"))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(format!("gh run view --json jobs failed: {stderr}"));
        }

        let stdout = String::from_utf8_lossy(&output.stdout);
        let v: serde_json::Value =
            serde_json::from_str(&stdout).map_err(|e| format!("failed to parse gh json: {e}"))?;

        let jobs = v["jobs"].as_array().cloned().unwrap_or_default();
        Ok(jobs
            .iter()
            .map(|j| GhRunJob {
                id: j["databaseId"].as_i64().unwrap_or(0),
                name: j["name"].as_str().unwrap_or("").to_string(),
                status: j["status"].as_str().unwrap_or("").to_string(),
                conclusion: j["conclusion"].as_str().unwrap_or("").to_string(),
                started_at: j["startedAt"].as_str().unwrap_or("").to_string(),
                completed_at: j["completedAt"].as_str().unwrap_or("").to_string(),
            })
            .collect())
    }
}
