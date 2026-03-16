//! Service wrapping `gh pr` CLI for pull request operations.

use serde::{Deserialize, Serialize};
use std::path::Path;
use tokio::process::Command as TokioCommand;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GhPrInfo {
    pub number: i64,
    pub title: String,
    pub state: String,
    pub head_ref: String,
    pub base_ref: String,
    pub url: String,
    pub mergeable: String,
    pub head_sha: String,
}

pub struct PrService;

impl PrService {
    /// Create a new pull request via `gh pr create`.
    pub async fn create(
        cwd: &Path,
        title: &str,
        body: &str,
        head: &str,
        base: &str,
    ) -> Result<GhPrInfo, String> {
        let output = TokioCommand::new("gh")
            .args([
                "pr",
                "create",
                "--title",
                title,
                "--body",
                body,
                "--head",
                head,
                "--base",
                base,
                "--json",
                "number,title,state,headRefName,baseRefName,url,mergeable,headRefOid",
            ])
            .current_dir(cwd)
            .output()
            .await
            .map_err(|e| format!("failed to run gh: {e}"))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(format!("gh pr create failed: {stderr}"));
        }

        let stdout = String::from_utf8_lossy(&output.stdout);
        parse_gh_pr_json(&stdout)
    }

    /// Get PR info via `gh pr view`.
    pub async fn get(cwd: &Path, number: i64) -> Result<GhPrInfo, String> {
        let output = TokioCommand::new("gh")
            .args([
                "pr",
                "view",
                &number.to_string(),
                "--json",
                "number,title,state,headRefName,baseRefName,url,mergeable,headRefOid",
            ])
            .current_dir(cwd)
            .output()
            .await
            .map_err(|e| format!("failed to run gh: {e}"))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(format!("gh pr view failed: {stderr}"));
        }

        let stdout = String::from_utf8_lossy(&output.stdout);
        parse_gh_pr_json(&stdout)
    }

    /// Merge a PR via `gh pr merge`.
    pub async fn merge(cwd: &Path, number: i64, method: &str) -> Result<(), String> {
        let merge_flag = match method {
            "squash" => "--squash",
            "rebase" => "--rebase",
            _ => "--merge",
        };

        let output = TokioCommand::new("gh")
            .args(["pr", "merge", &number.to_string(), merge_flag, "--auto"])
            .current_dir(cwd)
            .output()
            .await
            .map_err(|e| format!("failed to run gh: {e}"))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(format!("gh pr merge failed: {stderr}"));
        }
        Ok(())
    }

    /// Close a PR via `gh pr close`.
    pub async fn close(cwd: &Path, number: i64) -> Result<(), String> {
        let output = TokioCommand::new("gh")
            .args(["pr", "close", &number.to_string()])
            .current_dir(cwd)
            .output()
            .await
            .map_err(|e| format!("failed to run gh: {e}"))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(format!("gh pr close failed: {stderr}"));
        }
        Ok(())
    }
}

fn parse_gh_pr_json(json_str: &str) -> Result<GhPrInfo, String> {
    let v: serde_json::Value =
        serde_json::from_str(json_str).map_err(|e| format!("failed to parse gh json: {e}"))?;

    Ok(GhPrInfo {
        number: v["number"].as_i64().unwrap_or(0),
        title: v["title"].as_str().unwrap_or("").to_string(),
        state: v["state"].as_str().unwrap_or("UNKNOWN").to_string(),
        head_ref: v["headRefName"].as_str().unwrap_or("").to_string(),
        base_ref: v["baseRefName"].as_str().unwrap_or("").to_string(),
        url: v["url"].as_str().unwrap_or("").to_string(),
        mergeable: v["mergeable"].as_str().unwrap_or("UNKNOWN").to_string(),
        head_sha: v["headRefOid"].as_str().unwrap_or("").to_string(),
    })
}
