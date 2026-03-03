use crate::error::CoreError;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::path::Path;
use uuid::Uuid;

/// Failure handling policy for a workflow step.
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum FailurePolicy {
    #[default]
    Pause,
    RetryOnce,
    Skip,
}

/// Result of a completed workflow stage (step execution).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StageResult {
    pub step_index: usize,
    pub task_id: String,
    pub status: String,
    pub completed_at: Option<DateTime<Utc>>,
}

/// A workflow definition, typically loaded from `.pnevma/workflows/*.yaml`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkflowDef {
    pub name: String,
    #[serde(default)]
    pub description: Option<String>,
    pub steps: Vec<WorkflowStep>,
}

/// A single step in a workflow definition.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkflowStep {
    pub title: String,
    pub goal: String,
    #[serde(default)]
    pub scope: Vec<String>,
    #[serde(default = "default_priority")]
    pub priority: String,
    /// Indices (0-based) into the parent `steps` array that must complete first.
    #[serde(default)]
    pub depends_on: Vec<usize>,
    #[serde(default)]
    pub auto_dispatch: bool,
    #[serde(default)]
    pub acceptance_criteria: Vec<String>,
    #[serde(default)]
    pub constraints: Vec<String>,
    /// What to do if this step fails.
    #[serde(default)]
    pub on_failure: FailurePolicy,
}

fn default_priority() -> String {
    "P1".to_string()
}

/// Status of a running workflow instance.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum WorkflowStatus {
    Running,
    Completed,
    Failed,
}

/// A concrete instance of a workflow that has been instantiated for a project.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkflowInstance {
    pub id: Uuid,
    pub workflow_name: String,
    pub description: Option<String>,
    pub project_id: Uuid,
    /// Task IDs created from workflow steps, in step order.
    pub task_ids: Vec<Uuid>,
    pub status: WorkflowStatus,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl WorkflowDef {
    /// Parse a workflow definition from a YAML string.
    pub fn from_yaml(yaml: &str) -> Result<Self, CoreError> {
        let def: WorkflowDef = serde_yaml::from_str(yaml)
            .map_err(|e| CoreError::Serialization(format!("invalid workflow YAML: {e}")))?;
        def.validate()?;
        Ok(def)
    }

    /// Load a workflow definition from a YAML file.
    pub fn from_file(path: &Path) -> Result<Self, CoreError> {
        let raw = std::fs::read_to_string(path)?;
        Self::from_yaml(&raw)
    }

    /// Load all workflow definitions from a directory.
    pub fn load_all(dir: &Path) -> Result<Vec<Self>, CoreError> {
        if !dir.is_dir() {
            return Ok(vec![]);
        }
        let mut workflows = Vec::new();
        let entries = std::fs::read_dir(dir)?;
        for entry in entries {
            let entry = entry?;
            let path = entry.path();
            if path
                .extension()
                .is_some_and(|ext| ext == "yaml" || ext == "yml")
            {
                match Self::from_file(&path) {
                    Ok(wf) => workflows.push(wf),
                    Err(e) => {
                        tracing::warn!(path = %path.display(), error = %e, "skipping invalid workflow file");
                    }
                }
            }
        }
        Ok(workflows)
    }

    /// Validate the workflow definition.
    pub fn validate(&self) -> Result<(), CoreError> {
        if self.name.trim().is_empty() {
            return Err(CoreError::InvalidConfig(
                "workflow name must not be empty".to_string(),
            ));
        }
        if self.steps.is_empty() {
            return Err(CoreError::InvalidConfig(
                "workflow must have at least one step".to_string(),
            ));
        }
        let step_count = self.steps.len();
        for (i, step) in self.steps.iter().enumerate() {
            if step.title.trim().is_empty() {
                return Err(CoreError::InvalidConfig(format!(
                    "step {i} title must not be empty"
                )));
            }
            if step.goal.trim().is_empty() {
                return Err(CoreError::InvalidConfig(format!(
                    "step {i} goal must not be empty"
                )));
            }
            for &dep in &step.depends_on {
                if dep >= step_count {
                    return Err(CoreError::InvalidConfig(format!(
                        "step {i} depends_on index {dep} is out of bounds (max {})",
                        step_count - 1
                    )));
                }
                if dep == i {
                    return Err(CoreError::InvalidConfig(format!(
                        "step {i} cannot depend on itself"
                    )));
                }
            }
        }
        // Check for cycles via topological sort.
        if has_cycle(&self.steps) {
            return Err(CoreError::InvalidConfig(
                "workflow steps have a dependency cycle".to_string(),
            ));
        }
        Ok(())
    }
}

/// Detect cycles in the step dependency graph using DFS.
fn has_cycle(steps: &[WorkflowStep]) -> bool {
    let n = steps.len();
    // 0 = unvisited, 1 = in stack, 2 = done
    let mut state = vec![0u8; n];

    fn dfs(node: usize, steps: &[WorkflowStep], state: &mut [u8]) -> bool {
        state[node] = 1;
        for &dep in &steps[node].depends_on {
            if state[dep] == 1 {
                return true; // back edge = cycle
            }
            if state[dep] == 0 && dfs(dep, steps, state) {
                return true;
            }
        }
        state[node] = 2;
        false
    }

    for i in 0..n {
        if state[i] == 0 && dfs(i, steps, &mut state) {
            return true;
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_simple_workflow() {
        let yaml = r#"
name: "Feature Implementation"
description: "Standard feature workflow"
steps:
  - title: "Research"
    goal: "Explore codebase"
    auto_dispatch: true
  - title: "Implement"
    goal: "Write the code"
    depends_on: [0]
    auto_dispatch: true
  - title: "Test"
    goal: "Write tests"
    depends_on: [1]
    auto_dispatch: true
"#;
        let wf = WorkflowDef::from_yaml(yaml).unwrap();
        assert_eq!(wf.name, "Feature Implementation");
        assert_eq!(wf.steps.len(), 3);
        assert_eq!(wf.steps[1].depends_on, vec![0]);
        assert_eq!(wf.steps[2].depends_on, vec![1]);
    }

    #[test]
    fn detect_self_dependency() {
        let yaml = r#"
name: "Bad"
steps:
  - title: "A"
    goal: "Do A"
    depends_on: [0]
"#;
        let err = WorkflowDef::from_yaml(yaml).unwrap_err();
        assert!(err.to_string().contains("cannot depend on itself"));
    }

    #[test]
    fn detect_out_of_bounds_dependency() {
        let yaml = r#"
name: "Bad"
steps:
  - title: "A"
    goal: "Do A"
    depends_on: [5]
"#;
        let err = WorkflowDef::from_yaml(yaml).unwrap_err();
        assert!(err.to_string().contains("out of bounds"));
    }

    #[test]
    fn detect_cycle() {
        let yaml = r#"
name: "Cyclic"
steps:
  - title: "A"
    goal: "Do A"
    depends_on: [1]
  - title: "B"
    goal: "Do B"
    depends_on: [0]
"#;
        let err = WorkflowDef::from_yaml(yaml).unwrap_err();
        assert!(err.to_string().contains("dependency cycle"));
    }

    #[test]
    fn empty_steps_rejected() {
        let yaml = r#"
name: "Empty"
steps: []
"#;
        let err = WorkflowDef::from_yaml(yaml).unwrap_err();
        assert!(err.to_string().contains("at least one step"));
    }

    #[test]
    fn default_priority_is_p1() {
        let yaml = r#"
name: "Test"
steps:
  - title: "Step"
    goal: "Do it"
"#;
        let wf = WorkflowDef::from_yaml(yaml).unwrap();
        assert_eq!(wf.steps[0].priority, "P1");
    }
}
