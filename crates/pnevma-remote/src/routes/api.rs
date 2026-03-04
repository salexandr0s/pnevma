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

async fn call(router: &Arc<dyn CommandRouter>, method: &str, params: Value) -> axum::response::Response {
    match router.route(method, &params).await {
        Ok(result) => (
            StatusCode::OK,
            Json(RpcResponse { ok: true, result: Some(result), error: None }),
        )
            .into_response(),
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(RpcResponse { ok: false, result: None, error: Some(e) }),
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
    if let Some(obj) = params.as_object_mut() {
        obj.insert("id".to_string(), Value::String(id));
    } else {
        params = serde_json::json!({ "id": id });
    }
    call(&r, "task.dispatch", params).await
}

// --- sessions ---

pub async fn session_list(State(r): State<Arc<dyn CommandRouter>>) -> impl IntoResponse {
    call(&r, "session.list", Value::Null).await
}

pub async fn session_new(
    State(r): State<Arc<dyn CommandRouter>>,
    Json(params): Json<Value>,
) -> impl IntoResponse {
    call(&r, "session.new", params).await
}

pub async fn session_send_input(
    State(r): State<Arc<dyn CommandRouter>>,
    Path(id): Path<String>,
    Json(mut params): Json<Value>,
) -> impl IntoResponse {
    if let Some(obj) = params.as_object_mut() {
        obj.insert("id".to_string(), Value::String(id));
    } else {
        params = serde_json::json!({ "id": id });
    }
    call(&r, "session.send_input", params).await
}

// --- workflows ---

pub async fn workflow_list_defs(State(r): State<Arc<dyn CommandRouter>>) -> impl IntoResponse {
    call(&r, "workflow.list_defs", Value::Null).await
}

pub async fn workflow_instantiate(
    State(r): State<Arc<dyn CommandRouter>>,
    Json(params): Json<Value>,
) -> impl IntoResponse {
    call(&r, "workflow.instantiate", params).await
}

// --- generic RPC passthrough ---

pub async fn rpc(
    State(r): State<Arc<dyn CommandRouter>>,
    Json(body): Json<RpcRequest>,
) -> impl IntoResponse {
    call(&r, &body.method, body.params).await
}
