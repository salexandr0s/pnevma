use serde::{Deserialize, Serialize};

#[derive(Debug, Deserialize)]
pub struct RpcRequest {
    pub id: u64,
    pub method: String,
    #[serde(default)]
    pub params: serde_json::Value,
}

#[derive(Debug, Serialize)]
pub struct RpcResponse {
    pub id: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<RpcError>,
}

#[derive(Debug, Serialize)]
pub struct RpcError {
    pub code: i32,
    pub message: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct RpcNotification {
    pub method: String,
    pub params: serde_json::Value,
}

#[derive(Debug, Deserialize)]
pub struct SessionIdParams {
    pub session_id: String,
}

#[derive(Debug, Deserialize)]
pub struct SessionCreateParams {
    pub session_id: String,
    pub cwd: String,
    pub command: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct SessionSignalParams {
    pub session_id: String,
    pub signal: String,
}

impl RpcResponse {
    pub fn ok(id: u64, result: serde_json::Value) -> Self {
        Self {
            id,
            result: Some(result),
            error: None,
        }
    }

    pub fn err(id: u64, code: i32, message: String) -> Self {
        Self {
            id,
            result: None,
            error: Some(RpcError { code, message }),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_deserializes() {
        let json = r#"{"id":1,"method":"session.status","params":{"session_id":"abc"}}"#;
        let req: RpcRequest = serde_json::from_str(json).unwrap();
        assert_eq!(req.id, 1);
        assert_eq!(req.method, "session.status");
        assert_eq!(req.params["session_id"], "abc");
    }

    #[test]
    fn request_with_empty_params() {
        let json = r#"{"id":2,"method":"health"}"#;
        let req: RpcRequest = serde_json::from_str(json).unwrap();
        assert_eq!(req.id, 2);
        assert!(req.params.is_null());
    }

    #[test]
    fn response_ok_serializes() {
        let resp = RpcResponse::ok(1, serde_json::json!({"state": "running"}));
        let json = serde_json::to_string(&resp).unwrap();
        assert!(json.contains(r#""id":1"#));
        assert!(json.contains(r#""result""#));
        assert!(!json.contains(r#""error""#));
    }

    #[test]
    fn response_err_serializes() {
        let resp = RpcResponse::err(1, -1, "not found".to_string());
        let json = serde_json::to_string(&resp).unwrap();
        assert!(json.contains(r#""error""#));
        assert!(!json.contains(r#""result""#));
    }

    #[test]
    fn notification_serializes() {
        let notif = RpcNotification {
            method: "session.state_changed".to_string(),
            params: serde_json::json!({"session_id": "abc", "state": "exited"}),
        };
        let json = serde_json::to_string(&notif).unwrap();
        assert!(json.contains("session.state_changed"));
        assert!(!json.contains(r#""id""#));
    }
}
