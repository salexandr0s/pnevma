use crate::adapter::TrackerAdapter;
use crate::error::TrackerError;
use crate::types::{ExternalState, StateTransition, TrackerFilter, TrackerItem};
use async_trait::async_trait;
use chrono::{DateTime, Utc};
use reqwest::Client;
use tracing::{debug, warn};

const LINEAR_API_URL: &str = "https://api.linear.app/graphql";

pub struct LinearAdapter {
    client: Client,
    api_key: String,
}

impl LinearAdapter {
    pub fn new(api_key: String) -> Self {
        Self {
            client: Client::new(),
            api_key,
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
            .post(LINEAR_API_URL)
            .header("Authorization", &self.api_key)
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
            .filter_map(|node| {
                let state_name = node.get("state")?.get("name")?.as_str()?;
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
                    external_id: node.get("id")?.as_str()?.to_string(),
                    identifier: node.get("identifier")?.as_str()?.to_string(),
                    title: node.get("title")?.as_str()?.to_string(),
                    description: node
                        .get("description")
                        .and_then(|d| d.as_str())
                        .map(String::from),
                    url: node.get("url")?.as_str()?.to_string(),
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
            })
            .collect();

        Ok(items)
    }

    async fn fetch_states(&self, ids: &[String]) -> Result<Vec<TrackerItem>, TrackerError> {
        let mut items = Vec::new();
        for id in ids {
            let query = r#"
                query($id: String!) {
                    issue(id: $id) {
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
            "#;

            match self
                .graphql_query(query, serde_json::json!({"id": id}))
                .await
            {
                Ok(data) => {
                    if let Some(node) = data.get("issue") {
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

                        items.push(TrackerItem {
                            kind: "linear".to_string(),
                            external_id: node
                                .get("id")
                                .and_then(|v| v.as_str())
                                .unwrap_or(id)
                                .to_string(),
                            identifier: node
                                .get("identifier")
                                .and_then(|v| v.as_str())
                                .unwrap_or("")
                                .to_string(),
                            title: node
                                .get("title")
                                .and_then(|v| v.as_str())
                                .unwrap_or("")
                                .to_string(),
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
                        });
                    }
                }
                Err(e) => {
                    warn!(id = %id, error = %e, "failed to fetch issue state");
                }
            }
        }
        Ok(items)
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
