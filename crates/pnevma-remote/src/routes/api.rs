use std::sync::Arc;

use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::IntoResponse,
    Json,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::CommandRouter;

#[derive(Debug, Deserialize)]
pub struct RpcRequest {
    pub method: String,
    #[serde(default)]
    pub params: Value,
}

#[derive(Debug, Serialize)]
pub struct RpcResponse {
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

impl RpcResponse {
    fn success(val: Value) -> Self {
        Self {
            ok: true,
            result: Some(val),
            error: None,
        }
    }
    fn failure(msg: String) -> Self {
        Self {
            ok: false,
            result: None,
            error: Some(msg),
        }
    }
}

async fn call(
    router: &Arc<dyn CommandRouter>,
    method: &str,
    params: Value,
) -> axum::response::Response {
    match router.route(method, &params).await {
        Ok(result) => (StatusCode::OK, Json(RpcResponse::success(result))).into_response(),
        Err(e) => {
            let error_id = uuid::Uuid::new_v4().to_string();
            tracing::warn!(error_id = %error_id, method = %method, error = %e, "RPC call failed");
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(RpcResponse::failure(format!(
                    "internal error (ref: {error_id})"
                ))),
            )
                .into_response()
        }
    }
}

// --- project ---

pub async fn project_status(State(r): State<Arc<dyn CommandRouter>>) -> impl IntoResponse {
    call(&r, "project.status", Value::Null).await
}

pub async fn project_daily_brief(State(r): State<Arc<dyn CommandRouter>>) -> impl IntoResponse {
    call(&r, "project.daily_brief", Value::Null).await
}

pub async fn project_automation(State(r): State<Arc<dyn CommandRouter>>) -> impl IntoResponse {
    call(&r, "project.automation", Value::Null).await
}

pub async fn project_search(
    State(r): State<Arc<dyn CommandRouter>>,
    Json(params): Json<Value>,
) -> impl IntoResponse {
    call(&r, "project.search", params).await
}

pub async fn fleet_snapshot(State(r): State<Arc<dyn CommandRouter>>) -> impl IntoResponse {
    call(&r, "fleet.snapshot", Value::Null).await
}

pub async fn fleet_action(
    State(r): State<Arc<dyn CommandRouter>>,
    Json(params): Json<Value>,
) -> impl IntoResponse {
    call(&r, "fleet.action", params).await
}

fn inject_id(params: &mut Value, id: String) {
    if let Some(obj) = params.as_object_mut() {
        obj.insert("id".to_string(), Value::String(id));
    } else {
        *params = serde_json::json!({ "id": id });
    }
}

fn inject_param(params: &mut Value, key: &str, value: String) {
    if let Some(obj) = params.as_object_mut() {
        obj.insert(key.to_string(), Value::String(value));
    } else {
        *params = serde_json::json!({ key: value });
    }
}

// --- tasks ---

pub async fn task_list(State(r): State<Arc<dyn CommandRouter>>) -> impl IntoResponse {
    call(&r, "task.list", Value::Null).await
}

pub async fn task_create(
    State(r): State<Arc<dyn CommandRouter>>,
    Json(params): Json<Value>,
) -> impl IntoResponse {
    call(&r, "task.create", params).await
}

pub async fn task_dispatch(
    State(r): State<Arc<dyn CommandRouter>>,
    Path(id): Path<String>,
    Json(mut params): Json<Value>,
) -> impl IntoResponse {
    inject_param(&mut params, "task_id", id);
    call(&r, "task.dispatch", params).await
}

// --- sessions ---
// Note: session.new is deliberately excluded — no POST /api/sessions route.

pub async fn session_list(State(r): State<Arc<dyn CommandRouter>>) -> impl IntoResponse {
    call(&r, "session.list", Value::Null).await
}

// --- workflows ---

pub async fn workflow_list(State(r): State<Arc<dyn CommandRouter>>) -> impl IntoResponse {
    call(&r, "workflow.list", Value::Null).await
}

pub async fn workflow_list_defs(State(r): State<Arc<dyn CommandRouter>>) -> impl IntoResponse {
    call(&r, "workflow.list_defs", Value::Null).await
}

pub async fn workflow_create(
    State(r): State<Arc<dyn CommandRouter>>,
    Json(params): Json<Value>,
) -> impl IntoResponse {
    call(&r, "workflow.create", params).await
}

pub async fn workflow_get(
    State(r): State<Arc<dyn CommandRouter>>,
    Path(id): Path<String>,
) -> impl IntoResponse {
    let mut params = serde_json::json!({});
    inject_id(&mut params, id);
    call(&r, "workflow.get", params).await
}

pub async fn workflow_update(
    State(r): State<Arc<dyn CommandRouter>>,
    Path(id): Path<String>,
    Json(mut params): Json<Value>,
) -> impl IntoResponse {
    inject_id(&mut params, id);
    call(&r, "workflow.update", params).await
}

pub async fn workflow_delete(
    State(r): State<Arc<dyn CommandRouter>>,
    Path(id): Path<String>,
) -> impl IntoResponse {
    let mut params = serde_json::json!({});
    inject_id(&mut params, id);
    call(&r, "workflow.delete", params).await
}

pub async fn workflow_list_instances(State(r): State<Arc<dyn CommandRouter>>) -> impl IntoResponse {
    call(&r, "workflow.list_instances", Value::Null).await
}

pub async fn workflow_instantiate(
    State(r): State<Arc<dyn CommandRouter>>,
    Json(params): Json<Value>,
) -> impl IntoResponse {
    call(&r, "workflow.instantiate", params).await
}

pub async fn workflow_dispatch(
    State(r): State<Arc<dyn CommandRouter>>,
    Json(params): Json<Value>,
) -> impl IntoResponse {
    call(&r, "workflow.dispatch", params).await
}

pub async fn workflow_get_instance(
    State(r): State<Arc<dyn CommandRouter>>,
    Path(id): Path<String>,
) -> impl IntoResponse {
    let mut params = serde_json::json!({});
    inject_id(&mut params, id);
    call(&r, "workflow.get_instance", params).await
}

// --- generic RPC passthrough ---

pub async fn rpc(
    State(r): State<Arc<dyn CommandRouter>>,
    Json(body): Json<RpcRequest>,
) -> impl IntoResponse {
    if !super::rpc_allowlist::is_allowed(&body.method) {
        return (
            StatusCode::FORBIDDEN,
            Json(RpcResponse::failure(format!(
                "method not allowed via RPC: {}",
                body.method
            ))),
        )
            .into_response();
    }
    call(&r, &body.method, body.params).await
}

#[cfg(test)]
mod tests {
    use super::super::rpc_allowlist;
    use super::{fleet_action, fleet_snapshot, task_dispatch};
    use crate::CommandRouter;
    use async_trait::async_trait;
    use axum::{
        extract::{Path, State},
        Json,
    };
    use serde_json::{json, Value};
    use std::sync::{Arc, Mutex};

    #[derive(Default)]
    struct RecordingRouter {
        method: Mutex<Option<String>>,
        params: Mutex<Option<Value>>,
    }

    #[async_trait]
    impl CommandRouter for RecordingRouter {
        async fn route(&self, method: &str, params: &Value) -> Result<Value, String> {
            *self.method.lock().expect("method mutex") = Some(method.to_string());
            *self.params.lock().expect("params mutex") = Some(params.clone());
            Ok(json!({"ok": true}))
        }
    }

    #[test]
    fn rpc_allowlist_includes_expected_methods() {
        assert!(rpc_allowlist::is_allowed("project.status"));
        assert!(rpc_allowlist::is_allowed("task.list"));
        assert!(rpc_allowlist::is_allowed("session.list"));
    }

    #[test]
    fn rpc_allowlist_excludes_dangerous_methods() {
        assert!(!rpc_allowlist::is_allowed("session.new"));
        assert!(!rpc_allowlist::is_allowed("trust_workspace"));
        assert!(!rpc_allowlist::is_allowed("ssh.connect"));
        assert!(!rpc_allowlist::is_allowed("checkpoint.restore"));
    }

    #[tokio::test]
    async fn task_dispatch_injects_task_id_without_dropping_existing_fields() {
        let recorder = Arc::new(RecordingRouter::default());
        let router: Arc<dyn CommandRouter> = recorder.clone();

        let _ = task_dispatch(
            State(router),
            Path("task-123".to_string()),
            Json(json!({ "priority": "high" })),
        )
        .await;

        assert_eq!(
            recorder.method.lock().expect("method mutex").as_deref(),
            Some("task.dispatch")
        );
        assert_eq!(
            recorder.params.lock().expect("params mutex").clone(),
            Some(json!({
                "priority": "high",
                "task_id": "task-123"
            }))
        );
    }

    #[tokio::test]
    async fn fleet_snapshot_routes_to_fleet_snapshot_method() {
        let recorder = Arc::new(RecordingRouter::default());
        let router: Arc<dyn CommandRouter> = recorder.clone();

        let _ = fleet_snapshot(State(router)).await;

        assert_eq!(
            recorder.method.lock().expect("method mutex").as_deref(),
            Some("fleet.snapshot")
        );
        assert_eq!(
            recorder.params.lock().expect("params mutex").clone(),
            Some(Value::Null)
        );
    }

    #[tokio::test]
    async fn fleet_action_routes_to_fleet_action_method() {
        let recorder = Arc::new(RecordingRouter::default());
        let router: Arc<dyn CommandRouter> = recorder.clone();
        let params = json!({
            "action": "kill_session",
            "session_id": "session-123"
        });

        let _ = fleet_action(State(router), Json(params.clone())).await;

        assert_eq!(
            recorder.method.lock().expect("method mutex").as_deref(),
            Some("fleet.action")
        );
        assert_eq!(
            recorder.params.lock().expect("params mutex").clone(),
            Some(params)
        );
    }
}
