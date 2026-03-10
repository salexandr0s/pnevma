use pnevma_agents::DynamicToolDef;
use pnevma_tracker::{ExternalState, StateTransition, TrackerAdapter, TrackerFilter};
use serde_json::{json, Value};
use std::sync::Arc;
use tracing::{debug, warn};

/// Dynamic tool definitions to register with the agent.
pub fn tracker_tool_defs() -> Vec<DynamicToolDef> {
    vec![
        DynamicToolDef {
            name: "tracker.query".to_string(),
            description: "Query the external issue tracker for issues matching filters. Returns a list of issues with their current state.".to_string(),
            parameters_schema: json!({
                "type": "object",
                "properties": {
                    "team_id": { "type": "string", "description": "Filter by team ID" },
                    "project_id": { "type": "string", "description": "Filter by project ID" },
                    "labels": { "type": "array", "items": { "type": "string" }, "description": "Filter by labels" },
                    "states": { "type": "array", "items": { "type": "string" }, "description": "Filter by states (Todo, InProgress, Done, etc.)" },
                    "limit": { "type": "integer", "description": "Max results to return" }
                }
            }),
        },
        DynamicToolDef {
            name: "tracker.update_state".to_string(),
            description: "Update the state of an issue in the external tracker. Can also add a comment.".to_string(),
            parameters_schema: json!({
                "type": "object",
                "properties": {
                    "external_id": { "type": "string", "description": "The external issue ID" },
                    "to_state": { "type": "string", "description": "Target state: Todo, InProgress, InReview, Done, Cancelled" },
                    "comment": { "type": "string", "description": "Optional comment to add to the issue" }
                },
                "required": ["external_id", "to_state"]
            }),
        },
    ]
}

/// Handle a dynamic tool call from the agent.
///
/// Routes to the appropriate handler based on tool_name.
/// Returns a JSON value to send back to the agent as the tool result.
pub async fn handle_dynamic_tool_call(
    call_id: &str,
    tool_name: &str,
    params: &Value,
    tracker: &Arc<dyn TrackerAdapter>,
    task_id: &str,
    project_id: &str,
    redaction_secrets: &[String],
) -> Value {
    debug!(
        call_id = %call_id,
        tool_name = %tool_name,
        task_id = %task_id,
        project_id = %project_id,
        "handling dynamic tool call"
    );

    let result = match tool_name {
        "tracker.query" => handle_tracker_query(params, tracker).await,
        "tracker.update_state" => handle_tracker_update(params, tracker, task_id).await,
        _ => {
            json!({
                "error": format!("unknown tool: {}", tool_name),
                "success": false
            })
        }
    };

    // Redact secrets from the result
    redact_value(&result, redaction_secrets)
}

async fn handle_tracker_query(params: &Value, tracker: &Arc<dyn TrackerAdapter>) -> Value {
    let filter = TrackerFilter {
        team_id: params
            .get("team_id")
            .and_then(|v| v.as_str())
            .map(String::from),
        project_id: params
            .get("project_id")
            .and_then(|v| v.as_str())
            .map(String::from),
        labels: params
            .get("labels")
            .and_then(|v| v.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|v| v.as_str().map(String::from))
                    .collect()
            })
            .unwrap_or_default(),
        states: params
            .get("states")
            .and_then(|v| v.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|v| v.as_str().map(parse_external_state))
                    .collect()
            })
            .unwrap_or_default(),
        updated_since: None,
        limit: params
            .get("limit")
            .and_then(|v| v.as_u64())
            .map(|n| n as usize),
    };

    match tracker.poll_candidates(&filter).await {
        Ok(items) => {
            let results: Vec<Value> = items
                .iter()
                .map(|item| {
                    json!({
                        "external_id": item.external_id,
                        "identifier": item.identifier,
                        "title": item.title,
                        "state": format!("{:?}", item.state),
                        "url": item.url,
                        "priority": item.priority,
                        "labels": item.labels,
                        "assignee": item.assignee,
                    })
                })
                .collect();

            json!({
                "success": true,
                "count": results.len(),
                "issues": results
            })
        }
        Err(e) => {
            warn!(error = %e, "tracker query failed");
            json!({
                "success": false,
                "error": e.to_string()
            })
        }
    }
}

async fn handle_tracker_update(
    params: &Value,
    tracker: &Arc<dyn TrackerAdapter>,
    task_id: &str,
) -> Value {
    let external_id = match params.get("external_id").and_then(|v| v.as_str()) {
        Some(id) => id.to_string(),
        None => return json!({ "success": false, "error": "missing external_id" }),
    };

    let to_state_str = match params.get("to_state").and_then(|v| v.as_str()) {
        Some(s) => s,
        None => return json!({ "success": false, "error": "missing to_state" }),
    };

    let to_state = parse_external_state(to_state_str);
    let comment = params
        .get("comment")
        .and_then(|v| v.as_str())
        .map(|s| format!("[Pnevma task {}] {}", task_id, s));

    let transition = StateTransition {
        external_id: external_id.clone(),
        kind: "linear".to_string(),
        team_id: params
            .get("team_id")
            .and_then(|v| v.as_str())
            .map(String::from),
        from_state: ExternalState::Custom("unknown".to_string()),
        to_state,
        comment,
    };

    match tracker.transition_item(&transition).await {
        Ok(()) => {
            json!({
                "success": true,
                "external_id": external_id,
                "new_state": to_state_str
            })
        }
        Err(e) => {
            warn!(external_id = %external_id, error = %e, "tracker update failed");
            json!({
                "success": false,
                "error": e.to_string()
            })
        }
    }
}

fn parse_external_state(s: &str) -> ExternalState {
    match s.to_lowercase().as_str() {
        "triage" => ExternalState::Triage,
        "backlog" => ExternalState::Backlog,
        "todo" => ExternalState::Todo,
        "inprogress" | "in_progress" | "in progress" => ExternalState::InProgress,
        "inreview" | "in_review" | "in review" => ExternalState::InReview,
        "done" => ExternalState::Done,
        "cancelled" | "canceled" => ExternalState::Cancelled,
        other => ExternalState::Custom(other.to_string()),
    }
}

/// Redact secrets from a JSON value (shallow string replacement).
fn redact_value(value: &Value, secrets: &[String]) -> Value {
    let mut text = value.to_string();
    for secret in secrets {
        if !secret.is_empty() && secret.len() >= 4 {
            text = text.replace(secret.as_str(), "***");
        }
    }
    serde_json::from_str(&text).unwrap_or_else(|_| value.clone())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_tracker_tool_defs_count() {
        let defs = tracker_tool_defs();
        assert_eq!(defs.len(), 2);
        assert_eq!(defs[0].name, "tracker.query");
        assert_eq!(defs[1].name, "tracker.update_state");
    }

    #[test]
    fn test_parse_external_state() {
        assert_eq!(parse_external_state("Todo"), ExternalState::Todo);
        assert_eq!(
            parse_external_state("InProgress"),
            ExternalState::InProgress
        );
        assert_eq!(
            parse_external_state("in_progress"),
            ExternalState::InProgress
        );
        assert_eq!(parse_external_state("Done"), ExternalState::Done);
        assert_eq!(
            parse_external_state("unknown"),
            ExternalState::Custom("unknown".to_string())
        );
    }

    #[test]
    fn test_redact_value() {
        let val = json!({"message": "key is sk-12345-abcde", "ok": true});
        let redacted = redact_value(&val, &["sk-12345-abcde".to_string()]);
        let msg = redacted.get("message").unwrap().as_str().unwrap();
        assert!(!msg.contains("sk-12345-abcde"));
        assert!(msg.contains("***"));
    }

    #[test]
    fn test_redact_value_skips_short_secrets() {
        let val = json!({"data": "ab"});
        let redacted = redact_value(&val, &["ab".to_string()]);
        assert_eq!(redacted.get("data").unwrap().as_str().unwrap(), "ab");
    }

    #[tokio::test]
    async fn test_unknown_tool_returns_error() {
        struct MockTracker;
        #[async_trait::async_trait]
        impl TrackerAdapter for MockTracker {
            async fn poll_candidates(
                &self,
                _: &TrackerFilter,
            ) -> Result<Vec<pnevma_tracker::TrackerItem>, pnevma_tracker::TrackerError>
            {
                Ok(vec![])
            }
            async fn fetch_states(
                &self,
                _: &[String],
            ) -> Result<Vec<pnevma_tracker::TrackerItem>, pnevma_tracker::TrackerError>
            {
                Ok(vec![])
            }
            async fn transition_item(
                &self,
                _: &StateTransition,
            ) -> Result<(), pnevma_tracker::TrackerError> {
                Ok(())
            }
            async fn post_comment(
                &self,
                _: &str,
                _: &str,
            ) -> Result<(), pnevma_tracker::TrackerError> {
                Ok(())
            }
        }

        let tracker: Arc<dyn TrackerAdapter> = Arc::new(MockTracker);
        let result = handle_dynamic_tool_call(
            "call-1",
            "unknown.tool",
            &json!({}),
            &tracker,
            "task-1",
            "proj-1",
            &[],
        )
        .await;

        assert!(!result.get("success").unwrap().as_bool().unwrap());
        assert!(result
            .get("error")
            .unwrap()
            .as_str()
            .unwrap()
            .contains("unknown tool"));
    }

    #[tokio::test]
    async fn test_tracker_query_with_mock() {
        use chrono::Utc;

        struct MockTracker;
        #[async_trait::async_trait]
        impl TrackerAdapter for MockTracker {
            async fn poll_candidates(
                &self,
                _: &TrackerFilter,
            ) -> Result<Vec<pnevma_tracker::TrackerItem>, pnevma_tracker::TrackerError>
            {
                Ok(vec![pnevma_tracker::TrackerItem {
                    kind: "linear".to_string(),
                    external_id: "ext-1".to_string(),
                    identifier: "PRJ-123".to_string(),
                    title: "Test issue".to_string(),
                    description: None,
                    url: "https://linear.app/test".to_string(),
                    state: ExternalState::Todo,
                    priority: Some(1.0),
                    labels: vec!["bug".to_string()],
                    assignee: None,
                    updated_at: Utc::now(),
                }])
            }
            async fn fetch_states(
                &self,
                _: &[String],
            ) -> Result<Vec<pnevma_tracker::TrackerItem>, pnevma_tracker::TrackerError>
            {
                Ok(vec![])
            }
            async fn transition_item(
                &self,
                _: &StateTransition,
            ) -> Result<(), pnevma_tracker::TrackerError> {
                Ok(())
            }
            async fn post_comment(
                &self,
                _: &str,
                _: &str,
            ) -> Result<(), pnevma_tracker::TrackerError> {
                Ok(())
            }
        }

        let tracker: Arc<dyn TrackerAdapter> = Arc::new(MockTracker);
        let result = handle_dynamic_tool_call(
            "call-1",
            "tracker.query",
            &json!({"limit": 10}),
            &tracker,
            "task-1",
            "proj-1",
            &[],
        )
        .await;

        assert!(result.get("success").unwrap().as_bool().unwrap());
        assert_eq!(result.get("count").unwrap().as_u64().unwrap(), 1);
        let issues = result.get("issues").unwrap().as_array().unwrap();
        assert_eq!(
            issues[0].get("identifier").unwrap().as_str().unwrap(),
            "PRJ-123"
        );
    }
}
