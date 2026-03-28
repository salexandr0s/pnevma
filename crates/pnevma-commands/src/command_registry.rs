use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::OnceLock;

/// Access tier for control-socket commands.
///
/// `Password` auth mode restricts access: `Privileged` commands are rejected
/// outright, while `ReadOnly` and `Standard` commands are allowed after a
/// valid password is supplied.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum AccessLevel {
    /// Pure reads — status, list, get, tail, etc.
    ReadOnly,
    /// Normal mutations — the default for most commands.
    Standard,
    /// Dangerous operations that require `SameUser` auth.
    Privileged,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CommandArgumentDescriptor {
    pub name: String,
    pub label: String,
    pub required: bool,
    pub default_value: Option<String>,
    pub source: Option<String>,
    pub description: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RegisteredCommand {
    pub id: String,
    pub label: String,
    pub description: String,
    pub args: Vec<CommandArgumentDescriptor>,
    pub access_level: AccessLevel,
}

#[derive(Debug, Clone, Default)]
pub struct CommandRegistry {
    commands: Vec<RegisteredCommand>,
    index: HashMap<String, usize>,
}

impl CommandRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn register(mut self, command: RegisteredCommand) -> Self {
        let id = command.id.clone();
        self.index.insert(id, self.commands.len());
        self.commands.push(command);
        self
    }

    pub fn list(&self) -> Vec<RegisteredCommand> {
        self.commands.clone()
    }

    pub fn contains(&self, id: &str) -> bool {
        self.index.contains_key(id)
    }

    /// Return the access level for a command. For registered commands, the
    /// stored level is returned. For unregistered methods, `infer_access_level`
    /// is used — this classifies known-privileged and known-readonly actions,
    /// defaulting remaining unknowns to `Privileged` (fail-closed).
    pub fn access_level(&self, id: &str) -> AccessLevel {
        self.index
            .get(id)
            .and_then(|&idx| self.commands.get(idx))
            .map(|cmd| cmd.access_level)
            .unwrap_or_else(|| infer_access_level(id))
    }
}

impl RegisteredCommand {
    /// Build a new command, deriving its access level from its id automatically.
    fn new(id: &str, label: &str, description: &str, args: Vec<CommandArgumentDescriptor>) -> Self {
        Self {
            access_level: infer_access_level(id),
            id: id.to_string(),
            label: label.to_string(),
            description: description.to_string(),
            args,
        }
    }
}

/// Derive the access level for a command from its id.
///
/// Privileged commands are listed explicitly. Read-only commands are
/// identified by their trailing action segment. Unregistered commands
/// default to `Privileged` (fail-closed) so new methods must be
/// explicitly categorised before Password-auth clients can invoke them.
fn infer_access_level(id: &str) -> AccessLevel {
    const PRIVILEGED: &[&str] = &[
        // Session lifecycle
        "session.new",
        "session.kill",
        "session.kill_all",
        "session.send_input",
        "session.recovery.execute",
        "session.restart_active",
        "session.reattach_active",
        "fleet.action",
        // Agent execution triggers
        "task.dispatch",
        "task.dispatch_next_ready",
        "task.claim",
        "task.draft",
        "task.delete_ready",
        "workflow.dispatch",
        "workflow.instantiate",
        // Git / merge operations
        "merge.queue.execute",
        "merge.execute_task",
        "checkpoint.restore",
        "checkpoint.create",
        // Review gates (can trigger merge)
        "review.approve",
        "review.approve_next",
        "review.approve_task",
        "review.reject_task",
        // Config / secrets / settings
        "harness.config.write",
        "plan.write",
        "plan.delete",
        "project.trust",
        "project.cleanup_data",
        "project.secrets.upsert",
        "project.secrets.delete",
        "project.secrets.import_env",
        "workspace.file.write",
        "settings.app.set",
        "usage.providers.settings.set",
        "keybindings.set",
        // SSH
        "ssh.connect",
        "ssh.disconnect",
        "ssh.runtime.ensure_helper",
        "ssh.delete_profile",
        // Resource creation/deletion (global scope)
        "workflow.create",
        "workflow.delete",
        "global_workflow.create",
        "global_workflow.delete",
        "agent_profile.create",
        "agent_profile.delete",
        "global_agent.create",
        "global_agent.delete",
        "rules.delete",
        "conventions.delete",
        // Telemetry
        "telemetry.clear",
        "telemetry.set",
    ];
    if PRIVILEGED.contains(&id) {
        return AccessLevel::Privileged;
    }
    let action = id.rsplit('.').next().unwrap_or(id);
    if matches!(
        action,
        "get"
            | "list"
            | "list_live"
            | "list_all"
            | "status"
            | "read"
            | "search"
            | "tail"
            | "scrollback"
            | "timeline"
            | "daily-brief"
            | "daily_brief"
            | "defs"
            | "automation"
            | "readiness"
            | "poll"
            | "snapshot"
            | "overview"
            | "summary"
            | "options"
            | "health"
    ) {
        return AccessLevel::ReadOnly;
    }
    AccessLevel::Standard
}

fn arg(
    name: &str,
    label: &str,
    required: bool,
    default_value: Option<&str>,
    source: Option<&str>,
    description: Option<&str>,
) -> CommandArgumentDescriptor {
    CommandArgumentDescriptor {
        name: name.to_string(),
        label: label.to_string(),
        required,
        default_value: default_value.map(ToString::to_string),
        source: source.map(ToString::to_string),
        description: description.map(ToString::to_string),
    }
}

fn register_project_commands(registry: CommandRegistry) -> CommandRegistry {
    registry
        .register(RegisteredCommand::new(
            "project.open",
            "Open Project",
            "Open a project by path.",
            vec![arg(
                "path",
                "Project Path",
                true,
                Some("."),
                None,
                Some("Absolute or relative path to a directory containing pnevma.toml."),
            )],
        ))
        .register(RegisteredCommand::new(
            "environment.readiness",
            "Environment Readiness",
            "Check git/agent/global-config/project-init readiness.",
            vec![arg(
                "path",
                "Project Path",
                false,
                Some("."),
                None,
                Some("Optional path used for project scaffold readiness checks."),
            )],
        ))
        .register(RegisteredCommand::new(
            "environment.init_global_config",
            "Initialize Global Config",
            "Create ~/.config/pnevma/config.toml if missing.",
            vec![arg(
                "default_provider",
                "Default Provider",
                false,
                Some("claude-code"),
                None,
                Some("Optional default provider written on first creation."),
            )],
        ))
        .register(RegisteredCommand::new(
            "project.initialize_scaffold",
            "Initialize Project Scaffold",
            "Create pnevma.toml and .pnevma scaffold for a project path.",
            vec![
                arg("path", "Project Path", true, Some("."), None, None),
                arg("project_name", "Project Name", false, None, None, None),
                arg("project_brief", "Project Brief", false, None, None, None),
                arg(
                    "default_provider",
                    "Default Provider",
                    false,
                    Some("claude-code"),
                    None,
                    None,
                ),
            ],
        ))
}

fn register_session_commands(registry: CommandRegistry) -> CommandRegistry {
    registry
        .register(RegisteredCommand::new(
            "session.new",
            "New Session",
            "Create a new terminal session and open a pane.",
            vec![
                arg("name", "Session Name", true, Some("session"), None, None),
                arg("cwd", "Working Directory", true, Some("."), None, None),
                arg("command", "Command", true, Some("zsh"), None, None),
                arg(
                    "active_pane_id",
                    "Active Pane",
                    false,
                    None,
                    Some("active_pane_id"),
                    Some("If present, the new pane is inserted after this pane."),
                ),
            ],
        ))
        .register(RegisteredCommand::new(
            "session.reattach_active",
            "Reattach Active Session",
            "Reattach the current terminal session backend.",
            vec![arg(
                "active_session_id",
                "Active Session ID",
                true,
                None,
                Some("active_session_id"),
                None,
            )],
        ))
        .register(RegisteredCommand::new(
            "session.restart_active",
            "Restart Active Session",
            "Restart the active session and rebind the active pane.",
            vec![
                arg(
                    "active_session_id",
                    "Active Session ID",
                    true,
                    None,
                    Some("active_session_id"),
                    None,
                ),
                arg(
                    "active_pane_id",
                    "Active Pane ID",
                    true,
                    None,
                    Some("active_pane_id"),
                    None,
                ),
            ],
        ))
}

fn pane_cmd(id: &str, label: &str, description: &str) -> RegisteredCommand {
    RegisteredCommand::new(
        id,
        label,
        description,
        vec![arg(
            "active_pane_id",
            "Active Pane ID",
            false,
            None,
            Some("active_pane_id"),
            None,
        )],
    )
}

fn register_pane_commands(mut registry: CommandRegistry) -> CommandRegistry {
    for (id, label, desc) in [
        (
            "pane.split_horizontal",
            "Split Pane Horizontal",
            "Duplicate the active pane in a horizontal split.",
        ),
        (
            "pane.split_vertical",
            "Split Pane Vertical",
            "Duplicate the active pane in a vertical split.",
        ),
    ] {
        registry = registry.register(pane_cmd(id, label, desc));
    }
    registry = registry.register(RegisteredCommand::new(
        "pane.close",
        "Close Pane",
        "Close the active pane if it is not the task board.",
        vec![arg(
            "active_pane_id",
            "Active Pane ID",
            true,
            None,
            Some("active_pane_id"),
            None,
        )],
    ));
    for (id, label, desc) in [
        (
            "pane.open_review",
            "Open Review Pane",
            "Create a review pane next to the active pane.",
        ),
        (
            "pane.open_notifications",
            "Open Notifications Pane",
            "Create a notifications pane next to the active pane.",
        ),
        (
            "pane.open_merge_queue",
            "Open Merge Queue Pane",
            "Create a merge queue pane next to the active pane.",
        ),
        (
            "pane.open_replay",
            "Open Replay Pane",
            "Create a replay pane next to the active pane.",
        ),
        (
            "pane.open_daily_brief",
            "Open Daily Brief Pane",
            "Create a daily brief pane next to the active pane.",
        ),
        (
            "pane.open_search",
            "Open Search Pane",
            "Create a project search pane next to the active pane.",
        ),
        (
            "pane.open_diff",
            "Open Diff Pane",
            "Create a dedicated diff pane next to the active pane.",
        ),
        (
            "pane.open_file_browser",
            "Open File Browser Pane",
            "Create a project file browser pane next to the active pane.",
        ),
        (
            "pane.open_rules_manager",
            "Open Rules Pane",
            "Create a rules/conventions manager pane next to the active pane.",
        ),
        (
            "pane.open_settings",
            "Open Settings Pane",
            "Create a settings pane next to the active pane.",
        ),
    ] {
        registry = registry.register(pane_cmd(id, label, desc));
    }
    registry
}

fn register_task_commands(registry: CommandRegistry) -> CommandRegistry {
    registry
        .register(RegisteredCommand::new(
            "task.new",
            "New Task",
            "Create a task with default manual acceptance criteria.",
            vec![
                arg(
                    "title",
                    "Task Title",
                    true,
                    Some("Implement endpoint"),
                    None,
                    None,
                ),
                arg("goal", "Task Goal", true, Some("Ship value"), None, None),
                arg("priority", "Priority", true, Some("P1"), None, None),
            ],
        ))
        .register(RegisteredCommand::new(
            "task.dispatch_next_ready",
            "Dispatch Next Ready Task",
            "Dispatch the oldest task currently in Ready.",
            vec![],
        ))
        .register(RegisteredCommand::new(
            "task.delete_ready",
            "Delete Ready Task",
            "Delete the first task in Ready status.",
            vec![],
        ))
        .register(RegisteredCommand::new(
            "review.approve_next",
            "Approve Next Review Task",
            "Approve the oldest task currently in Review and enqueue merge.",
            vec![],
        ))
        .register(RegisteredCommand::new(
            "review.approve_task",
            "Approve Review",
            "Approve a task review and enqueue merge.",
            vec![
                arg("task_id", "Task ID", true, None, None, None),
                arg("note", "Reviewer Note", false, None, None, None),
            ],
        ))
        .register(RegisteredCommand::new(
            "review.reject_task",
            "Reject Review",
            "Reject a task review and return task to In Progress.",
            vec![
                arg("task_id", "Task ID", true, None, None, None),
                arg("note", "Reviewer Note", false, None, None, None),
            ],
        ))
        .register(RegisteredCommand::new(
            "merge.execute_task",
            "Execute Merge",
            "Execute merge queue flow for a task.",
            vec![arg("task_id", "Task ID", true, None, None, None)],
        ))
        .register(RegisteredCommand::new(
            "checkpoint.create",
            "Create Checkpoint",
            "Create a git checkpoint snapshot.",
            vec![
                arg("description", "Description", false, None, None, None),
                arg("task_id", "Task ID", false, None, None, None),
            ],
        ))
}

fn register_tracker_commands(registry: CommandRegistry) -> CommandRegistry {
    registry
        .register(RegisteredCommand::new(
            "tracker.poll",
            "Poll Tracker",
            "Poll the external issue tracker for new or updated items.",
            vec![
                arg(
                    "limit",
                    "Limit",
                    false,
                    Some("50"),
                    None,
                    Some("Maximum number of items to fetch."),
                ),
                arg(
                    "labels",
                    "Labels",
                    false,
                    None,
                    None,
                    Some("Comma-separated list of label names to filter by."),
                ),
            ],
        ))
        .register(RegisteredCommand::new(
            "tracker.status",
            "Tracker Status",
            "Return the tracker configuration and active status.",
            vec![],
        ))
}

pub fn default_registry() -> &'static CommandRegistry {
    static REGISTRY: OnceLock<CommandRegistry> = OnceLock::new();
    REGISTRY.get_or_init(|| {
        let registry = CommandRegistry::new();
        let registry = register_project_commands(registry);
        let registry = register_session_commands(registry);
        let registry = register_pane_commands(registry);
        let registry = register_task_commands(registry);
        let registry = register_tracker_commands(registry);
        let registry = register_github_auth_commands(registry);
        let registry = register_harness_config_commands(registry);
        register_plan_commands(registry)
    })
}

fn register_github_auth_commands(registry: CommandRegistry) -> CommandRegistry {
    registry
        .register(RegisteredCommand::new(
            "github.auth.status",
            "GitHub Account Status",
            "Return GitHub CLI account status for github.com.",
            vec![],
        ))
        .register(RegisteredCommand::new(
            "github.auth.refresh",
            "Refresh GitHub Accounts",
            "Refresh GitHub CLI account status for github.com.",
            vec![],
        ))
        .register(RegisteredCommand::new(
            "github.auth.switch",
            "Switch GitHub Account",
            "Switch the active GitHub CLI account for github.com.",
            vec![arg(
                "login",
                "Login",
                true,
                None,
                None,
                Some("The GitHub login to switch to."),
            )],
        ))
        .register(RegisteredCommand::new(
            "github.auth.add_account",
            "Add GitHub Account",
            "Start a background GitHub CLI browser login for github.com.",
            vec![],
        ))
        .register(RegisteredCommand::new(
            "github.auth.fix_git_helper",
            "Fix GitHub Git Helper",
            "Configure GitHub CLI as the Git credential helper for github.com.",
            vec![],
        ))
}

fn register_harness_config_commands(registry: CommandRegistry) -> CommandRegistry {
    registry
        .register(RegisteredCommand::new(
            "harness.config.list",
            "List Harness Configs",
            "List all available harness configuration files (MCP, settings, hooks, agents, skills, memory)",
            vec![],
        ))
        .register(RegisteredCommand::new(
            "harness.config.read",
            "Read Harness Config",
            "Read the content of a harness configuration file",
            vec![arg("key", "Config Key", true, None, None, Some("The config entry key (e.g. claude.mcp)"))],
        ))
        .register(RegisteredCommand::new(
            "harness.config.write",
            "Write Harness Config",
            "Write content to a harness configuration file",
            vec![
                arg("key", "Config Key", true, None, None, Some("The config entry key")),
                arg("content", "Content", true, None, None, Some("File content to write")),
            ],
        ))
}

fn register_plan_commands(registry: CommandRegistry) -> CommandRegistry {
    registry
        .register(RegisteredCommand::new(
            "plan.list",
            "List Plans",
            "List all plan files for the current project",
            vec![],
        ))
        .register(RegisteredCommand::new(
            "plan.read",
            "Read Plan",
            "Read a specific plan file",
            vec![arg(
                "id",
                "Plan ID",
                true,
                None,
                None,
                Some("The plan identifier"),
            )],
        ))
        .register(RegisteredCommand::new(
            "plan.write",
            "Write Plan",
            "Create or update a plan file",
            vec![
                arg(
                    "id",
                    "Plan ID",
                    true,
                    None,
                    None,
                    Some("The plan identifier"),
                ),
                arg("title", "Title", false, None, None, Some("Plan title")),
                arg(
                    "status",
                    "Status",
                    false,
                    None,
                    None,
                    Some("Plan status: draft, approved, in_progress, complete"),
                ),
                arg(
                    "content",
                    "Content",
                    false,
                    None,
                    None,
                    Some("Plan content in markdown"),
                ),
            ],
        ))
        .register(RegisteredCommand::new(
            "plan.delete",
            "Delete Plan",
            "Remove a plan file",
            vec![arg(
                "id",
                "Plan ID",
                true,
                None,
                None,
                Some("The plan identifier"),
            )],
        ))
}
