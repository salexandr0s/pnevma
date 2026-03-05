/// Methods allowed via the generic RPC endpoint and WebSocket RPC messages.
/// Dangerous operations like `session.new`, `trust_workspace`, `ssh.connect`,
/// and mutation of rules/conventions/keybindings are deliberately excluded.
pub(crate) const ALLOWED_RPC_METHODS: &[&str] = &[
    "project.status",
    "project.daily_brief",
    "project.search",
    "task.list",
    "task.create",
    "task.dispatch",
    "task.dispatch_next_ready",
    "task.poll",
    "session.list",
    "session.send_input",
    "session.timeline",
    "workflow.list_defs",
    "workflow.list_instances",
    "workflow.instantiate",
    "notification.list",
    "notification.mark_read",
];

pub(crate) fn is_allowed(method: &str) -> bool {
    ALLOWED_RPC_METHODS.contains(&method)
}
