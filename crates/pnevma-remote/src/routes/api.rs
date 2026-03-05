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
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(RpcResponse::failure(e)),
        )
            .into_response(),
    }
}

// --- project ---

pub async fn project_status(State(r): State<Arc<dyn CommandRouter>>) -> impl IntoResponse {
    call(&r, "project.status", Value::Null).await
}

pub async fn project_daily_brief(State(r): State<Arc<dyn CommandRouter>>) -> impl IntoResponse {
    call(&r, "project.daily_brief", Value::Null).await
}

pub async fn project_search(
    State(r): State<Arc<dyn CommandRouter>>,
    Json(params): Json<Value>,
) -> impl IntoResponse {
    call(&r, "project.search", params).await
}

fn inject_id(params: &mut Value, id: String) {
    if let Some(obj) = params.as_object_mut() {
        obj.insert("id".to_string(), Value::String(id));
    } else {
        *params = serde_json::json!({ "id": id });
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
    inject_id(&mut params, id);
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
}
