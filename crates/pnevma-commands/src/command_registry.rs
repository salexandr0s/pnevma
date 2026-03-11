use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::OnceLock;

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
        .register(RegisteredCommand {
            id: "project.open".to_string(),
            label: "Open Project".to_string(),
            description: "Open a project by path.".to_string(),
            args: vec![arg(
                "path",
                "Project Path",
                true,
                Some("."),
                None,
                Some("Absolute or relative path to a directory containing pnevma.toml."),
            )],
        })
        .register(RegisteredCommand {
            id: "environment.readiness".to_string(),
            label: "Environment Readiness".to_string(),
            description: "Check git/agent/global-config/project-init readiness.".to_string(),
            args: vec![arg(
                "path",
                "Project Path",
                false,
                Some("."),
                None,
                Some("Optional path used for project scaffold readiness checks."),
            )],
        })
        .register(RegisteredCommand {
            id: "environment.init_global_config".to_string(),
            label: "Initialize Global Config".to_string(),
            description: "Create ~/.config/pnevma/config.toml if missing.".to_string(),
            args: vec![arg(
                "default_provider",
                "Default Provider",
                false,
                Some("claude-code"),
                None,
                Some("Optional default provider written on first creation."),
            )],
        })
        .register(RegisteredCommand {
            id: "project.initialize_scaffold".to_string(),
            label: "Initialize Project Scaffold".to_string(),
            description: "Create pnevma.toml and .pnevma scaffold for a project path.".to_string(),
            args: vec![
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
        })
}

fn register_session_commands(registry: CommandRegistry) -> CommandRegistry {
    registry
        .register(RegisteredCommand {
            id: "session.new".to_string(),
            label: "New Session".to_string(),
            description: "Create a new terminal session and open a pane.".to_string(),
            args: vec![
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
        })
        .register(RegisteredCommand {
            id: "session.reattach_active".to_string(),
            label: "Reattach Active Session".to_string(),
            description: "Reattach the current terminal session backend.".to_string(),
            args: vec![arg(
                "active_session_id",
                "Active Session ID",
                true,
                None,
                Some("active_session_id"),
                None,
            )],
        })
        .register(RegisteredCommand {
            id: "session.restart_active".to_string(),
            label: "Restart Active Session".to_string(),
            description: "Restart the active session and rebind the active pane.".to_string(),
            args: vec![
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
        })
}

fn pane_cmd(id: &str, label: &str, description: &str) -> RegisteredCommand {
    RegisteredCommand {
        id: id.to_string(),
        label: label.to_string(),
        description: description.to_string(),
        args: vec![arg(
            "active_pane_id",
            "Active Pane ID",
            false,
            None,
            Some("active_pane_id"),
            None,
        )],
    }
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
    registry = registry.register(RegisteredCommand {
        id: "pane.close".to_string(),
        label: "Close Pane".to_string(),
        description: "Close the active pane if it is not the task board.".to_string(),
        args: vec![arg(
            "active_pane_id",
            "Active Pane ID",
            true,
            None,
            Some("active_pane_id"),
            None,
        )],
    });
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
        .register(RegisteredCommand {
            id: "task.new".to_string(),
            label: "New Task".to_string(),
            description: "Create a task with default manual acceptance criteria.".to_string(),
            args: vec![
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
        })
        .register(RegisteredCommand {
            id: "task.dispatch_next_ready".to_string(),
            label: "Dispatch Next Ready Task".to_string(),
            description: "Dispatch the oldest task currently in Ready.".to_string(),
            args: vec![],
        })
        .register(RegisteredCommand {
            id: "task.delete_ready".to_string(),
            label: "Delete Ready Task".to_string(),
            description: "Delete the first task in Ready status.".to_string(),
            args: vec![],
        })
        .register(RegisteredCommand {
            id: "review.approve_next".to_string(),
            label: "Approve Next Review Task".to_string(),
            description: "Approve the oldest task currently in Review and enqueue merge."
                .to_string(),
            args: vec![],
        })
        .register(RegisteredCommand {
            id: "review.approve_task".to_string(),
            label: "Approve Review".to_string(),
            description: "Approve a task review and enqueue merge.".to_string(),
            args: vec![
                arg("task_id", "Task ID", true, None, None, None),
                arg("note", "Reviewer Note", false, None, None, None),
            ],
        })
        .register(RegisteredCommand {
            id: "review.reject_task".to_string(),
            label: "Reject Review".to_string(),
            description: "Reject a task review and return task to In Progress.".to_string(),
            args: vec![
                arg("task_id", "Task ID", true, None, None, None),
                arg("note", "Reviewer Note", false, None, None, None),
            ],
        })
        .register(RegisteredCommand {
            id: "merge.execute_task".to_string(),
            label: "Execute Merge".to_string(),
            description: "Execute merge queue flow for a task.".to_string(),
            args: vec![arg("task_id", "Task ID", true, None, None, None)],
        })
        .register(RegisteredCommand {
            id: "checkpoint.create".to_string(),
            label: "Create Checkpoint".to_string(),
            description: "Create a git checkpoint snapshot.".to_string(),
            args: vec![
                arg("description", "Description", false, None, None, None),
                arg("task_id", "Task ID", false, None, None, None),
            ],
        })
}

fn register_tracker_commands(registry: CommandRegistry) -> CommandRegistry {
    registry
        .register(RegisteredCommand {
            id: "tracker.poll".to_string(),
            label: "Poll Tracker".to_string(),
            description: "Poll the external issue tracker for new or updated items.".to_string(),
            args: vec![
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
        })
        .register(RegisteredCommand {
            id: "tracker.status".to_string(),
            label: "Tracker Status".to_string(),
            description: "Return the tracker configuration and active status.".to_string(),
            args: vec![],
        })
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
        let registry = register_harness_config_commands(registry);
        register_plan_commands(registry)
    })
}

fn register_harness_config_commands(registry: CommandRegistry) -> CommandRegistry {
    registry
        .register(RegisteredCommand {
            id: "harness.config.list".to_string(),
            label: "List Harness Configs".to_string(),
            description: "List all available harness configuration files (MCP, settings, hooks, agents, skills, memory)".to_string(),
            args: vec![],
        })
        .register(RegisteredCommand {
            id: "harness.config.read".to_string(),
            label: "Read Harness Config".to_string(),
            description: "Read the content of a harness configuration file".to_string(),
            args: vec![arg("key", "Config Key", true, None, None, Some("The config entry key (e.g. claude.mcp)"))],
        })
        .register(RegisteredCommand {
            id: "harness.config.write".to_string(),
            label: "Write Harness Config".to_string(),
            description: "Write content to a harness configuration file".to_string(),
            args: vec![
                arg("key", "Config Key", true, None, None, Some("The config entry key")),
                arg("content", "Content", true, None, None, Some("File content to write")),
            ],
        })
}

fn register_plan_commands(registry: CommandRegistry) -> CommandRegistry {
    registry
        .register(RegisteredCommand {
            id: "plan.list".to_string(),
            label: "List Plans".to_string(),
            description: "List all plan files for the current project".to_string(),
            args: vec![],
        })
        .register(RegisteredCommand {
            id: "plan.read".to_string(),
            label: "Read Plan".to_string(),
            description: "Read a specific plan file".to_string(),
            args: vec![arg(
                "id",
                "Plan ID",
                true,
                None,
                None,
                Some("The plan identifier"),
            )],
        })
        .register(RegisteredCommand {
            id: "plan.write".to_string(),
            label: "Write Plan".to_string(),
            description: "Create or update a plan file".to_string(),
            args: vec![
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
        })
        .register(RegisteredCommand {
            id: "plan.delete".to_string(),
            label: "Delete Plan".to_string(),
            description: "Remove a plan file".to_string(),
            args: vec![arg(
                "id",
                "Plan ID",
                true,
                None,
                None,
                Some("The plan identifier"),
            )],
        })
}
