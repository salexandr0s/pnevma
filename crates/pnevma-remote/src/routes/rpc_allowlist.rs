/// Methods allowed via the generic RPC endpoint and WebSocket RPC messages.
/// Dangerous operations like `session.new`, `trust_workspace`, `ssh.connect`,
/// and mutation of rules/conventions/keybindings are deliberately excluded.
///
/// Read-only methods — available to all authenticated tokens.
pub(crate) const READ_METHODS: &[&str] = &[
    "project.status",
    "project.automation",
    "project.daily_brief",
    "project.search",
    "task.list",
    "task.poll",
    "session.list",
    "session.timeline",
    "workflow.list_defs",
    "workflow.list_instances",
    "workflow.list",
    "workflow.get",
    "workflow.get_instance",
    "agent_profile.list",
    "notification.list",
];

/// Write/mutate methods — require Operator role.
pub(crate) const WRITE_METHODS: &[&str] = &[
    "task.create",
    "task.dispatch",
    "task.dispatch_next_ready",
    "workflow.instantiate",
    "workflow.dispatch",
    "notification.mark_read",
];

pub(crate) fn is_allowed(method: &str) -> bool {
    READ_METHODS.contains(&method) || WRITE_METHODS.contains(&method)
}

pub(crate) fn requires_operator(method: &str) -> bool {
    WRITE_METHODS.contains(&method)
}
