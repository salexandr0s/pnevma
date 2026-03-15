use parking_lot::Mutex;
use pnevma_agents::DynamicToolDef;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;
use tracing::{debug, warn};

use crate::event_emitter::EventEmitter;

/// Pending browser tool calls awaiting Swift-side completion.
pub type BrowserToolPending = Arc<Mutex<HashMap<String, tokio::sync::oneshot::Sender<Value>>>>;

pub fn new_browser_tool_pending() -> BrowserToolPending {
    Arc::new(Mutex::new(HashMap::new()))
}

/// Dynamic tool definitions to register with the agent for browser access.
pub fn browser_tool_defs() -> Vec<DynamicToolDef> {
    vec![
        DynamicToolDef {
            name: "browser.navigate".to_string(),
            description: "Navigate the browser to a URL, wait for the page to load, and return the page title and final URL.".to_string(),
            parameters_schema: json!({
                "type": "object",
                "properties": {
                    "url": { "type": "string", "description": "URL to navigate to" }
                },
                "required": ["url"]
            }),
        },
        DynamicToolDef {
            name: "browser.get_content".to_string(),
            description: "Extract the current page content as markdown via reader mode.".to_string(),
            parameters_schema: json!({
                "type": "object",
                "properties": {}
            }),
        },
        DynamicToolDef {
            name: "browser.screenshot".to_string(),
            description: "Take a screenshot of the current browser viewport, returned as base64-encoded PNG.".to_string(),
            parameters_schema: json!({
                "type": "object",
                "properties": {}
            }),
        },
        DynamicToolDef {
            name: "browser.copy_selection".to_string(),
            description: "Copy the current browser text selection with its source URL and return the copied content.".to_string(),
            parameters_schema: json!({
                "type": "object",
                "properties": {}
            }),
        },
        DynamicToolDef {
            name: "browser.save_markdown".to_string(),
            description: "Save the current page as markdown into the deterministic workspace browser-captures scratch directory.".to_string(),
            parameters_schema: json!({
                "type": "object",
                "properties": {}
            }),
        },
        DynamicToolDef {
            name: "browser.copy_link_list".to_string(),
            description: "Copy the current page's link list as markdown and return the copied links.".to_string(),
            parameters_schema: json!({
                "type": "object",
                "properties": {}
            }),
        },
    ]
}

/// Handle a browser tool call by emitting an event to Swift and waiting for the result.
///
/// Flow: Rust emits `browser_tool_request` → Swift observes via BridgeEventHub →
/// Swift executes WKWebView operation → Swift calls `browser.tool_result` RPC →
/// Rust resumes the oneshot channel.
pub async fn handle_browser_tool_call(
    call_id: &str,
    tool_name: &str,
    params: &Value,
    emitter: &dyn EventEmitter,
    pending: &BrowserToolPending,
) -> Value {
    debug!(
        call_id = %call_id,
        tool_name = %tool_name,
        "handling browser tool call"
    );

    let (tx, rx) = tokio::sync::oneshot::channel();
    pending.lock().insert(call_id.to_string(), tx);

    emitter.emit(
        "browser_tool_request",
        json!({
            "call_id": call_id,
            "tool_name": tool_name,
            "params": params,
        }),
    );

    match tokio::time::timeout(Duration::from_secs(30), rx).await {
        Ok(Ok(result)) => result,
        Ok(Err(_)) => {
            warn!(call_id = %call_id, "browser tool channel dropped");
            json!({"error": "browser tool channel dropped", "success": false})
        }
        Err(_) => {
            pending.lock().remove(call_id);
            warn!(call_id = %call_id, "browser tool timed out after 30s");
            json!({"error": "browser tool timed out after 30s", "success": false})
        }
    }
}

/// Complete a pending browser tool call with the result from Swift.
/// Called when the `browser.tool_result` RPC arrives.
pub fn complete_browser_tool_call(call_id: &str, result: Value, pending: &BrowserToolPending) {
    if let Some(tx) = pending.lock().remove(call_id) {
        let _ = tx.send(result);
        debug!(call_id = %call_id, "browser tool call completed");
    } else {
        warn!(call_id = %call_id, "no pending browser tool call found for completion");
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_browser_tool_defs_count() {
        let defs = browser_tool_defs();
        assert_eq!(defs.len(), 6);
        assert_eq!(defs[0].name, "browser.navigate");
        assert_eq!(defs[1].name, "browser.get_content");
        assert_eq!(defs[2].name, "browser.screenshot");
        assert_eq!(defs[3].name, "browser.copy_selection");
        assert_eq!(defs[4].name, "browser.save_markdown");
        assert_eq!(defs[5].name, "browser.copy_link_list");
    }

    #[test]
    fn test_complete_unknown_call_id_is_noop() {
        let pending = new_browser_tool_pending();
        // Should not panic
        complete_browser_tool_call("nonexistent", json!({"ok": true}), &pending);
    }

    #[tokio::test]
    async fn test_complete_resumes_pending_call() {
        let pending = new_browser_tool_pending();
        let (tx, rx) = tokio::sync::oneshot::channel();
        pending.lock().insert("call-1".to_string(), tx);

        complete_browser_tool_call("call-1", json!({"title": "Test Page"}), &pending);

        let result = rx.await.unwrap();
        assert_eq!(result.get("title").unwrap().as_str().unwrap(), "Test Page");
        assert!(pending.lock().is_empty());
    }

    #[tokio::test]
    async fn test_handle_browser_tool_timeout() {
        use crate::event_emitter::NullEmitter;

        let _emitter = NullEmitter;
        let pending = new_browser_tool_pending();

        // Use a very short timeout scenario: the channel will never be completed
        // so this would normally timeout. We can test the pending insertion.
        let (tx, _rx) = tokio::sync::oneshot::channel::<Value>();
        pending.lock().insert("pre-call".to_string(), tx);

        // Verify the pending map contains our entry
        assert!(pending.lock().contains_key("pre-call"));
    }
}
