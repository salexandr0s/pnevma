use crate::adapter::TrackerAdapter;
use crate::error::TrackerError;
use crate::types::{ExternalState, StateTransition, TrackerFilter, TrackerItem};
use async_trait::async_trait;
use chrono::{DateTime, Utc};
use reqwest::Client;
use secrecy::{ExposeSecret, SecretString};
use tracing::{debug, warn};

const LINEAR_API_URL: &str = "https://api.linear.app/graphql";

/// Convert a Linear GraphQL issue node to a `TrackerItem`.
/// Used by both `poll_candidates` and `fetch_states` to avoid duplicating
/// the field extraction logic.
fn node_to_tracker_item(node: &serde_json::Value, fallback_id: &str) -> Option<TrackerItem> {
    // Require id and title — skip malformed nodes instead of producing garbage items.
    let external_id = node
        .get("id")
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .unwrap_or(fallback_id);
    let title = node
        .get("title")
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())?;

    let state_name = node
        .get("state")
        .and_then(|s| s.get("name"))
        .and_then(|n| n.as_str())
        .unwrap_or("unknown");
    let labels: Vec<String> = node
        .get("labels")
        .and_then(|l| l.get("nodes"))
        .and_then(|n| n.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|l| l.get("name")?.as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default();

    Some(TrackerItem {
        kind: "linear".to_string(),
        external_id: external_id.to_string(),
        identifier: node
            .get("identifier")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
        title: title.to_string(),
        description: node
            .get("description")
            .and_then(|v| v.as_str())
            .map(String::from),
        url: node
            .get("url")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
        state: ExternalState::from_linear_state(state_name),
        priority: node.get("priority").and_then(|p| p.as_f64()),
        labels,
        assignee: node
            .get("assignee")
            .and_then(|a| a.get("name"))
            .and_then(|n| n.as_str())
            .map(String::from),
        updated_at: node
            .get("updatedAt")
            .and_then(|u| u.as_str())
            .and_then(|s| s.parse::<DateTime<Utc>>().ok())
            .unwrap_or_else(Utc::now),
    })
}

pub struct LinearAdapter {
    client: Client,
    api_key: SecretString,
    base_url: String,
}

impl LinearAdapter {
    pub fn new(api_key: impl Into<SecretString>) -> Self {
        Self {
            client: Client::new(),
            api_key: api_key.into(),
            base_url: LINEAR_API_URL.to_string(),
        }
    }

    #[cfg(test)]
    pub fn with_base_url(api_key: impl Into<SecretString>, base_url: String) -> Self {
        Self {
            client: Client::new(),
            api_key: api_key.into(),
            base_url,
        }
    }

    async fn graphql_query(
        &self,
        query: &str,
        variables: serde_json::Value,
    ) -> Result<serde_json::Value, TrackerError> {
        let body = serde_json::json!({
            "query": query,
            "variables": variables,
        });

        let resp = self
            .client
            .post(&self.base_url)
            .header(
                "Authorization",
                format!("Bearer {}", self.api_key.expose_secret()),
            )
            .header("Content-Type", "application/json")
            .json(&body)
            .send()
            .await?;

        let status = resp.status();
        let json: serde_json::Value = resp.json().await?;

        if let Some(errors) = json.get("errors") {
            let msg = errors.to_string();
            return Err(TrackerError::GraphQL(msg));
        }

        if !status.is_success() {
            return Err(TrackerError::GraphQL(format!("HTTP {}", status)));
        }

        json.get("data")
            .cloned()
            .ok_or_else(|| TrackerError::GraphQL("missing data field".into()))
    }
}

#[async_trait]
impl TrackerAdapter for LinearAdapter {
    async fn poll_candidates(
        &self,
        filter: &TrackerFilter,
    ) -> Result<Vec<TrackerItem>, TrackerError> {
        let limit = filter.limit.unwrap_or(50);

        let query = r#"
            query($filter: IssueFilter, $first: Int!) {
                issues(first: $first, filter: $filter) {
                    nodes {
                        id
                        identifier
                        title
                        description
                        url
                        priority
                        updatedAt
                        state {
                            name
                        }
                        labels {
                            nodes {
                                name
                            }
                        }
                        assignee {
                            name
                        }
                    }
                }
            }
        "#;

        let mut filter_obj = serde_json::Map::new();

        if let Some(ref team_id) = filter.team_id {
            filter_obj.insert(
                "team".into(),
                serde_json::json!({ "id": { "eq": team_id } }),
            );
        }
        if let Some(ref project_id) = filter.project_id {
            filter_obj.insert(
                "project".into(),
                serde_json::json!({ "id": { "eq": project_id } }),
            );
        }
        if !filter.labels.is_empty() {
            filter_obj.insert(
                "labels".into(),
                serde_json::json!({ "name": { "in": filter.labels } }),
            );
        }
        if let Some(ref since) = filter.updated_since {
            filter_obj.insert(
                "updatedAt".into(),
                serde_json::json!({ "gte": since.to_rfc3339() }),
            );
        }

        let variables = serde_json::json!({
            "first": limit,
            "filter": serde_json::Value::Object(filter_obj),
        });

        let data = self.graphql_query(query, variables).await?;

        let nodes = data
            .get("issues")
            .and_then(|i| i.get("nodes"))
            .and_then(|n| n.as_array())
            .cloned()
            .unwrap_or_default();

        let items = nodes
            .iter()
            .filter_map(|node| node_to_tracker_item(node, ""))
            .collect();

        Ok(items)
    }

    async fn fetch_states(&self, ids: &[String]) -> Result<Vec<TrackerItem>, TrackerError> {
        if ids.is_empty() {
            return Ok(Vec::new());
        }

        // Validate IDs are well-formed UUIDs to prevent GraphQL injection.
        let uuid_re = regex::Regex::new(
            r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
        )
        .expect("uuid regex");
        for id in ids {
            if !uuid_re.is_match(id) {
                return Err(TrackerError::Config(format!(
                    "invalid issue ID (not a valid UUID): {id}"
                )));
            }
        }

        let alias_queries: Vec<String> = ids
            .iter()
            .enumerate()
            .map(|(i, id)| {
                format!(
                    r#"i{i}: issue(id: "{id}") {{
                        id
                        identifier
                        title
                        description
                        url
                        priority
                        updatedAt
                        state {{ name }}
                        labels {{ nodes {{ name }} }}
                        assignee {{ name }}
                    }}"#
                )
            })
            .collect();

        let query = format!("query {{ {} }}", alias_queries.join("\n"));

        match self.graphql_query(&query, serde_json::json!({})).await {
            Ok(data) => {
                let mut items = Vec::new();
                for (i, id) in ids.iter().enumerate() {
                    let alias = format!("i{i}");
                    if let Some(node) = data.get(&alias) {
                        if let Some(item) = node_to_tracker_item(node, id) {
                            items.push(item);
                        }
                    } else {
                        warn!(id = %id, "issue not found in batched response");
                    }
                }
                Ok(items)
            }
            Err(e) => {
                warn!(error = %e, "batched fetch_states failed, falling back to individual queries");
                // Fallback to individual queries if batch fails
                let mut items = Vec::new();
                for id in ids {
                    let query = r#"
                        query($id: String!) {
                            issue(id: $id) {
                                id identifier title description url priority updatedAt
                                state { name }
                                labels { nodes { name } }
                                assignee { name }
                            }
                        }
                    "#;
                    match self
                        .graphql_query(query, serde_json::json!({"id": id}))
                        .await
                    {
                        Ok(data) => {
                            if let Some(node) = data.get("issue") {
                                if let Some(item) = node_to_tracker_item(node, id) {
                                    items.push(item);
                                }
                            }
                        }
                        Err(e) => {
                            warn!(id = %id, error = %e, "failed to fetch issue state");
                        }
                    }
                }
                Ok(items)
            }
        }
    }

    async fn transition_item(&self, transition: &StateTransition) -> Result<(), TrackerError> {
        // When team_id is available, scope the query to that team's workflow states
        // to avoid name collisions across teams. Otherwise fall back to unscoped query.
        let data = if let Some(ref team_id) = transition.team_id {
            let scoped_query = r#"
                query($teamId: ID!) {
                    workflowStates(filter: { team: { id: { eq: $teamId } } }) {
                        nodes {
                            id
                            name
                        }
                    }
                }
            "#;
            self.graphql_query(scoped_query, serde_json::json!({ "teamId": team_id }))
                .await?
        } else {
            let unscoped_query = r#"
                query {
                    workflowStates {
                        nodes {
                            id
                            name
                        }
                    }
                }
            "#;
            self.graphql_query(unscoped_query, serde_json::json!({}))
                .await?
        };
        let target_state_name = match &transition.to_state {
            ExternalState::Todo => "Todo",
            ExternalState::InProgress => "In Progress",
            ExternalState::InReview => "In Review",
            ExternalState::Done => "Done",
            ExternalState::Cancelled => "Cancelled",
            ExternalState::Custom(name) => name.as_str(),
            _ => {
                return Err(TrackerError::Config(format!(
                    "unsupported target state: {:?}",
                    transition.to_state
                )))
            }
        };

        let state_id = data
            .get("workflowStates")
            .and_then(|s| s.get("nodes"))
            .and_then(|n| n.as_array())
            .and_then(|arr| {
                arr.iter().find(|s| {
                    s.get("name")
                        .and_then(|n| n.as_str())
                        .map(|n| n.eq_ignore_ascii_case(target_state_name))
                        .unwrap_or(false)
                })
            })
            .and_then(|s| s.get("id"))
            .and_then(|id| id.as_str())
            .ok_or_else(|| {
                TrackerError::NotFound(format!("state '{}' not found", target_state_name))
            })?;

        let mutation = r#"
            mutation($issueId: String!, $stateId: String!) {
                issueUpdate(id: $issueId, input: { stateId: $stateId }) {
                    success
                }
            }
        "#;

        self.graphql_query(
            mutation,
            serde_json::json!({
                "issueId": transition.external_id,
                "stateId": state_id,
            }),
        )
        .await?;

        debug!(
            external_id = %transition.external_id,
            from = ?transition.from_state,
            to = ?transition.to_state,
            "transitioned issue"
        );

        Ok(())
    }

    async fn post_comment(&self, external_id: &str, body: &str) -> Result<(), TrackerError> {
        let mutation = r#"
            mutation($issueId: String!, $body: String!) {
                commentCreate(input: { issueId: $issueId, body: $body }) {
                    success
                }
            }
        "#;

        self.graphql_query(
            mutation,
            serde_json::json!({
                "issueId": external_id,
                "body": body,
            }),
        )
        .await?;

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use wiremock::matchers::{header, method};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    #[test]
    fn linear_adapter_debug_does_not_leak_api_key() {
        let adapter = LinearAdapter::new("lin_api_test_secret_key_12345".to_string());
        let debug_output = format!("{:?}", adapter.api_key);
        assert!(
            !debug_output.contains("lin_api_test_secret_key_12345"),
            "API key should not appear in debug output"
        );
    }

    fn mock_adapter(base_url: String) -> LinearAdapter {
        LinearAdapter::with_base_url("test-key", base_url)
    }

    fn issue_node(id: &str, title: &str, state: &str) -> serde_json::Value {
        serde_json::json!({
            "id": id,
            "identifier": format!("ENG-{}", &id[..3]),
            "title": title,
            "description": "desc",
            "url": format!("https://linear.app/issue/{id}"),
            "priority": 2,
            "updatedAt": "2026-01-01T00:00:00Z",
            "state": { "name": state },
            "labels": { "nodes": [] },
            "assignee": { "name": "Dev" }
        })
    }

    #[tokio::test]
    async fn poll_candidates_success() {
        let server = MockServer::start().await;
        let response = serde_json::json!({
            "data": {
                "issues": {
                    "nodes": [
                        issue_node("aaa-bbb-ccc", "Fix login bug", "Todo"),
                        issue_node("ddd-eee-fff", "Add dashboard", "In Progress"),
                    ]
                }
            }
        });

        Mock::given(method("POST"))
            .and(header("Authorization", "Bearer test-key"))
            .respond_with(ResponseTemplate::new(200).set_body_json(&response))
            .mount(&server)
            .await;

        let adapter = mock_adapter(server.uri());
        let filter = TrackerFilter {
            team_id: None,
            project_id: None,
            labels: vec![],
            states: vec![],
            updated_since: None,
            limit: Some(10),
        };

        let items = adapter.poll_candidates(&filter).await.unwrap();
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].title, "Fix login bug");
        assert_eq!(items[1].title, "Add dashboard");
    }

    #[tokio::test]
    async fn poll_candidates_graphql_error() {
        let server = MockServer::start().await;
        let response = serde_json::json!({
            "errors": [{"message": "Authentication required"}]
        });

        Mock::given(method("POST"))
            .respond_with(ResponseTemplate::new(200).set_body_json(&response))
            .mount(&server)
            .await;

        let adapter = mock_adapter(server.uri());
        let filter = TrackerFilter::default();
        let err = adapter.poll_candidates(&filter).await.unwrap_err();
        assert!(matches!(err, TrackerError::GraphQL(_)));
    }

    #[tokio::test]
    async fn poll_candidates_http_error() {
        let server = MockServer::start().await;

        Mock::given(method("POST"))
            .respond_with(ResponseTemplate::new(500).set_body_json(serde_json::json!({
                "data": null
            })))
            .mount(&server)
            .await;

        let adapter = mock_adapter(server.uri());
        let filter = TrackerFilter::default();
        let err = adapter.poll_candidates(&filter).await.unwrap_err();
        assert!(matches!(err, TrackerError::GraphQL(_)));
    }

    #[tokio::test]
    async fn fetch_states_empty_ids() {
        let adapter = LinearAdapter::new("test-key");
        let items = adapter.fetch_states(&[]).await.unwrap();
        assert!(items.is_empty());
    }

    #[tokio::test]
    async fn fetch_states_success() {
        let server = MockServer::start().await;
        let id = "550e8400-e29b-41d4-a716-446655440000";
        let response = serde_json::json!({
            "data": {
                "i0": issue_node(id, "Task one", "Done")
            }
        });

        Mock::given(method("POST"))
            .respond_with(ResponseTemplate::new(200).set_body_json(&response))
            .mount(&server)
            .await;

        let adapter = mock_adapter(server.uri());
        let items = adapter.fetch_states(&[id.to_string()]).await.unwrap();
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].title, "Task one");
    }

    #[tokio::test]
    async fn fetch_states_rejects_invalid_uuid() {
        let adapter = LinearAdapter::new("test-key");
        let err = adapter
            .fetch_states(&["not-a-valid-uuid".to_string()])
            .await
            .unwrap_err();
        assert!(matches!(err, TrackerError::Config(_)));
    }

    #[tokio::test]
    async fn transition_item_success() {
        let server = MockServer::start().await;
        // First call: fetch workflow states
        // Second call: issue update mutation
        Mock::given(method("POST"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "data": {
                    "workflowStates": {
                        "nodes": [
                            { "id": "state-1", "name": "Todo" },
                            { "id": "state-2", "name": "In Progress" },
                            { "id": "state-3", "name": "Done" },
                        ]
                    }
                }
            })))
            .up_to_n_times(1)
            .mount(&server)
            .await;

        Mock::given(method("POST"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "data": {
                    "issueUpdate": { "success": true }
                }
            })))
            .mount(&server)
            .await;

        let adapter = mock_adapter(server.uri());
        let transition = StateTransition {
            external_id: "issue-123".to_string(),
            kind: "linear".to_string(),
            from_state: ExternalState::Todo,
            to_state: ExternalState::InProgress,
            team_id: None,
            comment: None,
        };

        adapter.transition_item(&transition).await.unwrap();
    }

    #[tokio::test]
    async fn post_comment_success() {
        let server = MockServer::start().await;

        Mock::given(method("POST"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "data": {
                    "commentCreate": { "success": true }
                }
            })))
            .mount(&server)
            .await;

        let adapter = mock_adapter(server.uri());
        adapter
            .post_comment("issue-123", "Build passed!")
            .await
            .unwrap();
    }
}
