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

/// Execution isolation mode for a workflow step.
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ExecutionMode {
    #[default]
    Worktree,
    Main,
}

impl ExecutionMode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Worktree => "worktree",
            Self::Main => "main",
        }
    }
}

impl FailurePolicy {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Pause => "Pause",
            Self::RetryOnce => "RetryOnce",
            Self::Skip => "Skip",
        }
    }
}

/// Loop mode for a workflow step.
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum LoopMode {
    #[default]
    OnFailure,
    UntilComplete,
}

/// Loop configuration for a workflow step.
/// When this step fails, loop back to `target` step, up to `max_iterations` times.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LoopConfig {
    /// Step index to loop back to (must be < this step's index, or == for until_complete self-loops).
    pub target: usize,
    /// Maximum number of loop iterations (default 5, max 20).
    #[serde(default = "default_max_loop_iterations")]
    pub max_iterations: u32,
    /// Loop mode: `on_failure` (default) loops only on failure; `until_complete` loops on
    /// success too, stopping only when the agent includes `<COMPLETE>` in its summary.
    #[serde(default)]
    pub mode: LoopMode,
}

fn default_max_loop_iterations() -> u32 {
    5
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
    /// Agent profile name (references AgentProfileRow.name). Overrides project default.
    #[serde(default)]
    pub agent_profile: Option<String>,
    /// Execution isolation mode for this step.
    #[serde(default)]
    pub execution_mode: ExecutionMode,
    /// Timeout override in minutes. Falls back to agent profile or config default.
    #[serde(default)]
    pub timeout_minutes: Option<u64>,
    /// Max retry attempts (0 = no retries).
    #[serde(default)]
    pub max_retries: Option<u32>,
    /// Loop configuration. If set, failing this step loops back to `target`.
    #[serde(default, rename = "loop")]
    pub loop_config: Option<LoopConfig>,
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
            if let Some(t) = step.timeout_minutes {
                if t == 0 {
                    return Err(CoreError::InvalidConfig(format!(
                        "step {i} timeout_minutes must be > 0 if set"
                    )));
                }
            }
            if let Some(r) = step.max_retries {
                if r > 5 {
                    return Err(CoreError::InvalidConfig(format!(
                        "step {i} max_retries must be <= 5 (got {r})"
                    )));
                }
            }
            if let Some(ref profile) = step.agent_profile {
                if profile.trim().is_empty() {
                    return Err(CoreError::InvalidConfig(format!(
                        "step {i} agent_profile must not be empty if set"
                    )));
                }
            }
            if let Some(ref lp) = step.loop_config {
                if lp.mode == LoopMode::UntilComplete {
                    if lp.target > i {
                        return Err(CoreError::InvalidConfig(format!(
                            "step {i} until_complete loop target must be <= step index (got {})",
                            lp.target
                        )));
                    }
                } else if lp.target >= i {
                    return Err(CoreError::InvalidConfig(format!(
                        "step {i} loop target must reference an earlier step (got {})",
                        lp.target
                    )));
                }
                if lp.max_iterations == 0 || lp.max_iterations > 20 {
                    return Err(CoreError::InvalidConfig(format!(
                        "step {i} loop max_iterations must be 1..=20 (got {})",
                        lp.max_iterations
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
    use proptest::prelude::*;

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

    #[test]
    fn parse_new_step_fields() {
        let yaml = r#"
name: "Multi-Model"
steps:
  - title: "Plan"
    goal: "Create plan"
    agent_profile: "opus-planner"
    execution_mode: main
    timeout_minutes: 45
    max_retries: 2
  - title: "Build"
    goal: "Implement"
    depends_on: [0]
    execution_mode: worktree
"#;
        let wf = WorkflowDef::from_yaml(yaml).unwrap();
        assert_eq!(wf.steps[0].agent_profile.as_deref(), Some("opus-planner"));
        assert_eq!(wf.steps[0].execution_mode, ExecutionMode::Main);
        assert_eq!(wf.steps[0].timeout_minutes, Some(45));
        assert_eq!(wf.steps[0].max_retries, Some(2));
        assert_eq!(wf.steps[1].execution_mode, ExecutionMode::Worktree);
        assert_eq!(wf.steps[1].agent_profile, None);
        assert_eq!(wf.steps[1].timeout_minutes, None);
    }

    #[test]
    fn reject_zero_timeout() {
        let yaml = r#"
name: "Bad"
steps:
  - title: "A"
    goal: "Do A"
    timeout_minutes: 0
"#;
        let err = WorkflowDef::from_yaml(yaml).unwrap_err();
        assert!(err.to_string().contains("timeout_minutes must be > 0"));
    }

    #[test]
    fn reject_excessive_retries() {
        let yaml = r#"
name: "Bad"
steps:
  - title: "A"
    goal: "Do A"
    max_retries: 10
"#;
        let err = WorkflowDef::from_yaml(yaml).unwrap_err();
        assert!(err.to_string().contains("max_retries must be <= 5"));
    }

    #[test]
    fn reject_empty_agent_profile() {
        let yaml = r#"
name: "Bad"
steps:
  - title: "A"
    goal: "Do A"
    agent_profile: "  "
"#;
        let err = WorkflowDef::from_yaml(yaml).unwrap_err();
        assert!(err.to_string().contains("agent_profile must not be empty"));
    }

    #[test]
    fn execution_mode_as_str() {
        assert_eq!(ExecutionMode::Worktree.as_str(), "worktree");
        assert_eq!(ExecutionMode::Main.as_str(), "main");
    }

    #[test]
    fn failure_policy_as_str() {
        assert_eq!(FailurePolicy::Pause.as_str(), "Pause");
        assert_eq!(FailurePolicy::RetryOnce.as_str(), "RetryOnce");
        assert_eq!(FailurePolicy::Skip.as_str(), "Skip");
    }

    // ── Proptest helpers ──────────────────────────────────────────────────────

    /// Build a valid N-step linear workflow YAML (each step depends on the previous).
    fn linear_workflow_yaml(n: usize) -> String {
        assert!(n >= 1);
        let mut steps = String::new();
        for i in 0..n {
            steps.push_str(&format!(
                "  - title: \"Step {i}\"\n    goal: \"Do step {i}\"\n"
            ));
            if i > 0 {
                steps.push_str(&format!("    depends_on: [{prev}]\n", prev = i - 1));
            }
        }
        format!("name: \"Linear\"\nsteps:\n{steps}")
    }

    proptest! {
        #[test]
        fn arbitrary_linear_workflow_validates(n in 1usize..=12) {
            let yaml = linear_workflow_yaml(n);
            let result = WorkflowDef::from_yaml(&yaml);
            prop_assert!(result.is_ok(), "linear workflow of {} steps should validate; err: {:?}", n, result.err());
        }

        #[test]
        fn step_with_out_of_bounds_dep_is_rejected(
            // A 1-step workflow where the step references dep index 1..=20
            dep in 1usize..=20
        ) {
            let yaml = format!(
                "name: \"Bad\"\nsteps:\n  - title: \"A\"\n    goal: \"Do A\"\n    depends_on: [{dep}]\n"
            );
            let result = WorkflowDef::from_yaml(&yaml);
            prop_assert!(result.is_err(), "dep {dep} is out of bounds for 1-step workflow");
        }

        #[test]
        fn empty_workflow_name_always_rejected(
            // Blank or whitespace-only name
            name in "[ \t]*"
        ) {
            let yaml = format!(
                "name: \"{name}\"\nsteps:\n  - title: \"A\"\n    goal: \"Do A\"\n"
            );
            let result = WorkflowDef::from_yaml(&yaml);
            prop_assert!(result.is_err(), "blank name should be rejected");
        }

        #[test]
        fn workflow_step_ordering_invariant_holds(n in 2usize..=8) {
            // A valid linear workflow's steps must be in order (depends_on only references earlier steps).
            let yaml = linear_workflow_yaml(n);
            let wf = WorkflowDef::from_yaml(&yaml).expect("linear workflow must be valid");
            for (i, step) in wf.steps.iter().enumerate() {
                for &dep in &step.depends_on {
                    prop_assert!(dep < i, "step {i} has dep {dep} >= itself (ordering violated)");
                }
            }
        }
    }

    #[test]
    fn parse_loop_config() {
        let yaml = r#"
name: "Loop Workflow"
steps:
  - title: "Build"
    goal: "Implement feature"
    auto_dispatch: true
  - title: "Test"
    goal: "Run tests"
    depends_on: [0]
    auto_dispatch: true
  - title: "Verify"
    goal: "Verify output"
    depends_on: [1]
    auto_dispatch: true
    loop:
      target: 0
      max_iterations: 5
"#;
        let wf = WorkflowDef::from_yaml(yaml).unwrap();
        assert_eq!(wf.steps.len(), 3);
        assert!(wf.steps[0].loop_config.is_none());
        assert!(wf.steps[1].loop_config.is_none());
        let lc = wf.steps[2].loop_config.as_ref().unwrap();
        assert_eq!(lc.target, 0);
        assert_eq!(lc.max_iterations, 5);
    }

    #[test]
    fn loop_config_default_max_iterations() {
        let yaml = r#"
name: "Default Loop"
steps:
  - title: "Plan"
    goal: "Make plan"
  - title: "Review"
    goal: "Review plan"
    depends_on: [0]
    loop:
      target: 0
"#;
        let wf = WorkflowDef::from_yaml(yaml).unwrap();
        let lc = wf.steps[1].loop_config.as_ref().unwrap();
        assert_eq!(lc.max_iterations, 5);
    }

    #[test]
    fn reject_loop_target_not_earlier() {
        let yaml = r#"
name: "Bad Loop"
steps:
  - title: "A"
    goal: "Do A"
    loop:
      target: 0
      max_iterations: 3
"#;
        let err = WorkflowDef::from_yaml(yaml).unwrap_err();
        assert!(err
            .to_string()
            .contains("loop target must reference an earlier step"));
    }

    #[test]
    fn reject_loop_zero_iterations() {
        let yaml = r#"
name: "Bad Loop"
steps:
  - title: "A"
    goal: "Do A"
  - title: "B"
    goal: "Do B"
    depends_on: [0]
    loop:
      target: 0
      max_iterations: 0
"#;
        let err = WorkflowDef::from_yaml(yaml).unwrap_err();
        assert!(err
            .to_string()
            .contains("loop max_iterations must be 1..=20"));
    }

    #[test]
    fn reject_loop_excessive_iterations() {
        let yaml = r#"
name: "Bad Loop"
steps:
  - title: "A"
    goal: "Do A"
  - title: "B"
    goal: "Do B"
    depends_on: [0]
    loop:
      target: 0
      max_iterations: 25
"#;
        let err = WorkflowDef::from_yaml(yaml).unwrap_err();
        assert!(err
            .to_string()
            .contains("loop max_iterations must be 1..=20"));
    }

    #[test]
    fn loop_does_not_create_cycle_in_dag() {
        let yaml = r#"
name: "Loop No Cycle"
steps:
  - title: "Build"
    goal: "Build"
    auto_dispatch: true
  - title: "Test"
    goal: "Test"
    depends_on: [0]
    auto_dispatch: true
  - title: "Verify"
    goal: "Verify"
    depends_on: [1]
    auto_dispatch: true
    loop:
      target: 0
      max_iterations: 10
"#;
        let wf = WorkflowDef::from_yaml(yaml);
        assert!(
            wf.is_ok(),
            "loop config should not cause cycle detection to fail"
        );
    }

    #[test]
    fn parse_until_complete_mode() {
        let yaml = r#"
name: "Ralph Loop"
steps:
  - title: "Implement"
    goal: "Pick next story and implement"
    auto_dispatch: true
    loop:
      target: 0
      mode: until_complete
      max_iterations: 10
"#;
        let wf = WorkflowDef::from_yaml(yaml).unwrap();
        let lc = wf.steps[0].loop_config.as_ref().unwrap();
        assert_eq!(lc.target, 0);
        assert_eq!(lc.max_iterations, 10);
        assert_eq!(lc.mode, LoopMode::UntilComplete);
    }

    #[test]
    fn until_complete_self_loop_allowed() {
        let yaml = r#"
name: "Self Loop"
steps:
  - title: "Do Work"
    goal: "Work until done"
    auto_dispatch: true
    loop:
      target: 0
      mode: until_complete
      max_iterations: 5
"#;
        let wf = WorkflowDef::from_yaml(yaml);
        assert!(wf.is_ok(), "self-loop with until_complete should be valid");
    }

    #[test]
    fn on_failure_self_loop_rejected() {
        let yaml = r#"
name: "Bad Self Loop"
steps:
  - title: "Do Work"
    goal: "Work"
    loop:
      target: 0
      mode: on_failure
      max_iterations: 5
"#;
        let err = WorkflowDef::from_yaml(yaml).unwrap_err();
        assert!(err
            .to_string()
            .contains("loop target must reference an earlier step"));
    }

    #[test]
    fn until_complete_forward_target_rejected() {
        let yaml = r#"
name: "Bad Forward"
steps:
  - title: "Build"
    goal: "Build"
    loop:
      target: 1
      mode: until_complete
      max_iterations: 5
  - title: "Test"
    goal: "Test"
    depends_on: [0]
"#;
        let err = WorkflowDef::from_yaml(yaml).unwrap_err();
        assert!(err
            .to_string()
            .contains("until_complete loop target must be <= step index"));
    }

    #[test]
    fn default_loop_mode_is_on_failure() {
        let yaml = r#"
name: "Default Mode"
steps:
  - title: "Build"
    goal: "Build"
  - title: "Verify"
    goal: "Verify"
    depends_on: [0]
    loop:
      target: 0
"#;
        let wf = WorkflowDef::from_yaml(yaml).unwrap();
        let lc = wf.steps[1].loop_config.as_ref().unwrap();
        assert_eq!(lc.mode, LoopMode::OnFailure);
    }

    #[test]
    fn until_complete_multi_step_loop() {
        let yaml = r#"
name: "Multi-step Ralph"
steps:
  - title: "Build"
    goal: "Pick next task and implement"
    auto_dispatch: true
  - title: "Verify"
    goal: "Run tests"
    depends_on: [0]
    auto_dispatch: true
    loop:
      target: 0
      mode: until_complete
      max_iterations: 10
"#;
        let wf = WorkflowDef::from_yaml(yaml).unwrap();
        assert_eq!(wf.steps.len(), 2);
        let lc = wf.steps[1].loop_config.as_ref().unwrap();
        assert_eq!(lc.target, 0);
        assert_eq!(lc.mode, LoopMode::UntilComplete);
    }
}
