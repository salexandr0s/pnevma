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
    "intake.list",
    "intake.status",
    "pr.list",
    "pr.get",
    "ci.list",
    "ci.get",
    "ci.summary",
    "deployment.list",
    "fleet.snapshot",
    "telemetry.fleet_snapshot",
    "telemetry.fleet_history",
    "telemetry.agent_performance",
    "telemetry.metrics_query",
    "review.files.list",
    "review.comments.list",
    "review.checklist.list",
    "attention_rules.list",
    "agent_hooks.list",
    "task.lineage",
    "task.forks",
    "port.list",
    "workspace.hooks.list",
    "editor.profiles.list",
    "ssh.files.read",
    "ssh.files.list",
];

/// Write/mutate methods — require Operator role.
pub(crate) const WRITE_METHODS: &[&str] = &[
    "task.create",
    "task.dispatch",
    "task.dispatch_next_ready",
    "workflow.instantiate",
    "workflow.dispatch",
    "notification.mark_read",
    "intake.accept",
    "intake.reject",
    "intake.poll",
    "pr.create",
    "pr.sync",
    "pr.merge",
    "pr.close",
    "ci.sync",
    "fleet.action",
    "telemetry.prune",
    "attention_rules.create",
    "attention_rules.update",
    "attention_rules.delete",
    "agent_hooks.create",
    "agent_hooks.update",
    "agent_hooks.delete",
    "task.fork",
    "port.allocate",
    "port.release",
    "editor.profiles.create",
    "editor.profiles.delete",
    "editor.profiles.set_default",
];

pub(crate) fn is_allowed(method: &str) -> bool {
    READ_METHODS.contains(&method) || WRITE_METHODS.contains(&method)
}

pub(crate) fn requires_operator(method: &str) -> bool {
    WRITE_METHODS.contains(&method)
}
