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
    registry.register(RegisteredCommand {
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

fn register_pane_commands(registry: CommandRegistry) -> CommandRegistry {
    registry
        .register(RegisteredCommand {
            id: "pane.split_horizontal".to_string(),
            label: "Split Pane Horizontal".to_string(),
            description: "Duplicate the active pane in a horizontal split.".to_string(),
            args: vec![arg(
                "active_pane_id",
                "Active Pane ID",
                false,
                None,
                Some("active_pane_id"),
                None,
            )],
        })
        .register(RegisteredCommand {
            id: "pane.split_vertical".to_string(),
            label: "Split Pane Vertical".to_string(),
            description: "Duplicate the active pane in a vertical split.".to_string(),
            args: vec![arg(
                "active_pane_id",
                "Active Pane ID",
                false,
                None,
                Some("active_pane_id"),
                None,
            )],
        })
        .register(RegisteredCommand {
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
        })
        .register(RegisteredCommand {
            id: "pane.open_review".to_string(),
            label: "Open Review Pane".to_string(),
            description: "Create a review pane next to the active pane.".to_string(),
            args: vec![arg(
                "active_pane_id",
                "Active Pane ID",
                false,
                None,
                Some("active_pane_id"),
                None,
            )],
        })
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
            id: "task.delete_ready".to_string(),
            label: "Delete Ready Task".to_string(),
            description: "Delete the first task in Ready status.".to_string(),
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
        register_task_commands(registry)
    })
}
