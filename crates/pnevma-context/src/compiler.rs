use crate::discovery::redact_secrets_with_known_values;
use crate::error::ContextError;
use pnevma_core::{ContextManifestItem, ContextPack, TaskContract};
use pnevma_redaction::normalize_secrets;
use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum ContextCompileMode {
    V2,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ContextCompilerConfig {
    pub mode: ContextCompileMode,
    pub token_budget: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ContextCompileInput {
    pub task: TaskContract,
    pub project_brief: String,
    pub architecture_notes: String,
    pub conventions: Vec<String>,
    pub rules: Vec<String>,
    pub relevant_file_contents: Vec<(String, String)>,
    pub prior_task_summaries: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ContextCompilerResult {
    pub pack: ContextPack,
    pub markdown: String,
}

#[derive(Debug, Clone)]
pub struct ContextCompiler {
    config: ContextCompilerConfig,
    redaction_secrets: Vec<String>,
}

impl ContextCompiler {
    pub fn new(config: ContextCompilerConfig, redaction_secrets: Vec<String>) -> Self {
        Self {
            config,
            redaction_secrets: normalize_secrets(&redaction_secrets),
        }
    }

    pub fn compile(
        &self,
        input: ContextCompileInput,
    ) -> Result<ContextCompilerResult, ContextError> {
        if self.config.token_budget == 0 {
            return Err(ContextError::Compile(
                "token_budget must be greater than zero".to_string(),
            ));
        }
        match self.config.mode {
            ContextCompileMode::V2 => self.compile_v2(input),
        }
    }

    pub fn write_markdown(
        &self,
        markdown: &str,
        output_path: impl AsRef<Path>,
    ) -> Result<(), ContextError> {
        let path = output_path.as_ref();
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        #[cfg(unix)]
        {
            use std::io::Write;
            use std::os::unix::fs::OpenOptionsExt;
            let mut file = std::fs::OpenOptions::new()
                .create(true)
                .truncate(true)
                .write(true)
                .mode(0o600)
                .open(path)?;
            file.write_all(markdown.as_bytes())?;
            file.sync_all()?;
        }
        #[cfg(not(unix))]
        {
            std::fs::write(path, markdown)?;
        }
        Ok(())
    }

    fn compile_v2(
        &self,
        input: ContextCompileInput,
    ) -> Result<ContextCompilerResult, ContextError> {
        let task = self.redact_task(input.task);
        if task.goal.trim().is_empty() {
            return Err(ContextError::Compile(
                "task goal cannot be empty for context compilation".to_string(),
            ));
        }
        let project_brief = self.redact_string(&input.project_brief);
        let architecture_notes = self.redact_string(&input.architecture_notes);
        let conventions = self.redact_strings(&input.conventions);
        let rules = self.redact_strings(&input.rules);
        let relevant_file_contents = self.redact_file_contents(&input.relevant_file_contents);
        let prior_task_summaries = self.redact_strings(&input.prior_task_summaries);

        let mut manifest = Vec::new();
        let mut text = String::new();
        let mut used = 0usize;
        let budget = self.config.token_budget;

        let mut push_section =
            |name: &str, body: String, required: bool, manifest: &mut Vec<ContextManifestItem>| {
                let token_estimate = body.len() / 4;
                if used + token_estimate <= budget || required {
                    text.push_str("\n\n");
                    text.push_str(name);
                    text.push('\n');
                    text.push_str(&body);
                    used += token_estimate;
                    manifest.push(ContextManifestItem {
                        kind: name.to_string(),
                        included: true,
                        reason: None,
                    });
                } else {
                    manifest.push(ContextManifestItem {
                        kind: name.to_string(),
                        included: false,
                        reason: Some("token budget exceeded".to_string()),
                    });
                }
            };

        push_section(
            "## Task Contract",
            format!("title: {}\ngoal: {}", task.title, task.goal),
            true,
            &mut manifest,
        );

        push_section(
            "## Relevant Files",
            relevant_file_contents
                .iter()
                .map(|(path, content)| format!("### {}\n{}", path, content))
                .collect::<Vec<_>>()
                .join("\n\n"),
            false,
            &mut manifest,
        );

        push_section(
            "## Rules and Conventions",
            format!(
                "Rules:\n{}\n\nConventions:\n{}",
                rules.join("\n"),
                conventions.join("\n")
            ),
            false,
            &mut manifest,
        );

        push_section(
            "## Architecture Notes",
            architecture_notes.clone(),
            false,
            &mut manifest,
        );

        push_section(
            "## Prior Summaries",
            prior_task_summaries.join("\n"),
            false,
            &mut manifest,
        );

        push_section(
            "## Project Brief",
            project_brief.clone(),
            false,
            &mut manifest,
        );

        let pack = ContextPack {
            task_contract: Box::new(task),
            project_brief,
            architecture_notes,
            conventions,
            rules,
            relevant_file_contents,
            prior_task_summaries,
            token_budget: budget,
            actual_tokens: used,
            manifest,
        };

        Ok(ContextCompilerResult {
            pack,
            markdown: text,
        })
    }

    fn redact_string(&self, input: &str) -> String {
        redact_secrets_with_known_values(input, &self.redaction_secrets)
    }

    fn redact_strings(&self, inputs: &[String]) -> Vec<String> {
        inputs
            .iter()
            .map(|input| self.redact_string(input))
            .collect()
    }

    fn redact_file_contents(&self, inputs: &[(String, String)]) -> Vec<(String, String)> {
        inputs
            .iter()
            .map(|(path, content)| (self.redact_string(path), self.redact_string(content)))
            .collect()
    }

    fn redact_task(&self, mut task: TaskContract) -> TaskContract {
        task.title = self.redact_string(&task.title);
        task.goal = self.redact_string(&task.goal);
        task.scope = self.redact_strings(&task.scope);
        task.out_of_scope = self.redact_strings(&task.out_of_scope);
        task.constraints = self.redact_strings(&task.constraints);
        task.handoff_summary = task
            .handoff_summary
            .as_ref()
            .map(|summary| self.redact_string(summary));
        task
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;
    use pnevma_core::{Check, CheckType, ContextPack, Priority, TaskStatus};
    use uuid::Uuid;

    fn make_task(secret: &str) -> TaskContract {
        TaskContract {
            id: Uuid::new_v4(),
            title: format!("Investigate {secret}"),
            goal: format!("Handle {secret} safely"),
            scope: vec!["src/main.rs".to_string()],
            out_of_scope: vec![format!("ignore {secret}")],
            dependencies: vec![],
            acceptance_criteria: vec![Check {
                description: "does not leak".to_string(),
                check_type: CheckType::ManualApproval,
                command: None,
            }],
            constraints: vec![format!("never print {secret}")],
            priority: Priority::P1,
            status: TaskStatus::Ready,
            assigned_session: None,
            branch: None,
            worktree: None,
            prompt_pack: None,
            handoff_summary: Some(format!("summary includes {secret}")),
            auto_dispatch: false,
            agent_profile_override: None,
            execution_mode: None,
            timeout_minutes: None,
            max_retries: None,
            loop_iteration: 0,
            loop_context_json: None,
            external_source: None,
            created_at: Utc::now(),
            updated_at: Utc::now(),
        }
    }

    fn make_minimal_task() -> TaskContract {
        TaskContract {
            id: Uuid::new_v4(),
            title: "Minimal task".to_string(),
            goal: "Do the thing".to_string(),
            scope: vec![],
            out_of_scope: vec![],
            dependencies: vec![],
            acceptance_criteria: vec![],
            constraints: vec![],
            priority: Priority::P1,
            status: TaskStatus::Ready,
            assigned_session: None,
            branch: None,
            worktree: None,
            prompt_pack: None,
            handoff_summary: None,
            auto_dispatch: false,
            agent_profile_override: None,
            execution_mode: None,
            timeout_minutes: None,
            max_retries: None,
            loop_iteration: 0,
            loop_context_json: None,
            external_source: None,
            created_at: Utc::now(),
            updated_at: Utc::now(),
        }
    }

    fn make_compiler(budget: usize) -> ContextCompiler {
        ContextCompiler::new(
            ContextCompilerConfig {
                mode: ContextCompileMode::V2,
                token_budget: budget,
            },
            vec![],
        )
    }

    fn make_minimal_input() -> ContextCompileInput {
        ContextCompileInput {
            task: make_minimal_task(),
            project_brief: String::new(),
            architecture_notes: String::new(),
            conventions: vec![],
            rules: vec![],
            relevant_file_contents: vec![],
            prior_task_summaries: vec![],
        }
    }

    // --- G.8: Context compiler round-trip tests ---

    #[test]
    fn compile_minimal_context_pack_succeeds() {
        let compiler = make_compiler(10_000);
        let result = compiler
            .compile(make_minimal_input())
            .expect("compile should succeed");
        // The pack should contain the task contract with the original goal
        assert_eq!(result.pack.task_contract.goal, "Do the thing");
        // Markdown output should not be empty (at least contains the task section)
        assert!(!result.markdown.is_empty());
    }

    #[test]
    fn compile_rejects_zero_token_budget() {
        let compiler = make_compiler(0);
        let err = compiler
            .compile(make_minimal_input())
            .expect_err("zero budget should be rejected");
        let msg = format!("{err}");
        assert!(
            msg.contains("token_budget"),
            "error should mention token_budget: {msg}"
        );
    }

    #[test]
    fn compile_rejects_empty_goal() {
        let compiler = make_compiler(10_000);
        let mut input = make_minimal_input();
        input.task.goal = "   ".to_string();
        let err = compiler
            .compile(input)
            .expect_err("empty goal should be rejected");
        let msg = format!("{err}");
        assert!(msg.contains("goal"), "error should mention goal: {msg}");
    }

    #[test]
    fn actual_tokens_does_not_exceed_budget_when_content_fits() {
        let compiler = make_compiler(10_000);
        let mut input = make_minimal_input();
        input.project_brief = "A brief project description.".to_string();
        input.architecture_notes = "Simple flat architecture.".to_string();
        input.conventions = vec!["Use snake_case".to_string()];
        input.rules = vec!["No unsafe code".to_string()];
        let result = compiler.compile(input).expect("compile");
        assert!(
            result.pack.actual_tokens <= result.pack.token_budget,
            "actual_tokens ({}) should not exceed token_budget ({})",
            result.pack.actual_tokens,
            result.pack.token_budget,
        );
    }

    #[test]
    fn tight_budget_excludes_optional_sections() {
        // Set budget so small that only the required Task Contract section fits.
        // The task title+goal is ~30 chars => ~8 tokens, so a budget of 20 should
        // include the task but exclude the larger optional sections.
        let compiler = make_compiler(20);
        let mut input = make_minimal_input();
        input.project_brief = "A".repeat(200); // ~50 tokens, should be excluded
        input.architecture_notes = "B".repeat(200);
        let result = compiler.compile(input).expect("compile");
        // Task Contract is required, so it must always be included
        let task_item = result
            .pack
            .manifest
            .iter()
            .find(|m| m.kind == "## Task Contract")
            .expect("manifest should contain Task Contract");
        assert!(
            task_item.included,
            "Task Contract should always be included"
        );
        // At least one optional section should have been excluded
        let excluded = result.pack.manifest.iter().any(|m| !m.included);
        assert!(
            excluded,
            "with a tight budget, at least one optional section should be excluded"
        );
        // Excluded items should have a reason
        for item in &result.pack.manifest {
            if !item.included {
                assert!(
                    item.reason.is_some(),
                    "excluded manifest item '{}' should have a reason",
                    item.kind
                );
            }
        }
    }

    #[test]
    fn manifest_records_all_section_kinds() {
        let compiler = make_compiler(100_000);
        let mut input = make_minimal_input();
        input.project_brief = "brief".to_string();
        input.architecture_notes = "arch".to_string();
        input.conventions = vec!["conv".to_string()];
        input.rules = vec!["rule".to_string()];
        input.relevant_file_contents = vec![("f.rs".to_string(), "code".to_string())];
        input.prior_task_summaries = vec!["prior".to_string()];
        let result = compiler.compile(input).expect("compile");
        let kinds: Vec<&str> = result
            .pack
            .manifest
            .iter()
            .map(|m| m.kind.as_str())
            .collect();
        assert!(
            kinds.contains(&"## Task Contract"),
            "missing Task Contract in manifest"
        );
        assert!(
            kinds.contains(&"## Relevant Files"),
            "missing Relevant Files in manifest"
        );
        assert!(
            kinds.contains(&"## Rules and Conventions"),
            "missing Rules and Conventions in manifest"
        );
        assert!(
            kinds.contains(&"## Architecture Notes"),
            "missing Architecture Notes in manifest"
        );
        assert!(
            kinds.contains(&"## Prior Summaries"),
            "missing Prior Summaries in manifest"
        );
        assert!(
            kinds.contains(&"## Project Brief"),
            "missing Project Brief in manifest"
        );
    }

    #[test]
    fn context_pack_round_trip_serde_json() {
        let compiler = make_compiler(10_000);
        let mut input = make_minimal_input();
        input.project_brief = "Test project brief".to_string();
        input.architecture_notes = "Layered architecture".to_string();
        input.conventions = vec!["Use Rust 2021".to_string()];
        input.rules = vec!["No panics".to_string()];
        input.relevant_file_contents =
            vec![("src/lib.rs".to_string(), "pub fn hello() {}".to_string())];
        input.prior_task_summaries = vec!["Completed setup".to_string()];
        let result = compiler.compile(input).expect("compile");
        let json = serde_json::to_string(&result.pack).expect("serialize ContextPack");
        let deserialized: ContextPack =
            serde_json::from_str(&json).expect("deserialize ContextPack");
        // Verify key fields survive the round-trip
        assert_eq!(
            deserialized.task_contract.goal,
            result.pack.task_contract.goal
        );
        assert_eq!(deserialized.project_brief, result.pack.project_brief);
        assert_eq!(deserialized.token_budget, result.pack.token_budget);
        assert_eq!(deserialized.actual_tokens, result.pack.actual_tokens);
        assert_eq!(deserialized.manifest.len(), result.pack.manifest.len());
        assert_eq!(deserialized.conventions, result.pack.conventions);
        assert_eq!(deserialized.rules, result.pack.rules);
        assert_eq!(
            deserialized.relevant_file_contents,
            result.pack.relevant_file_contents
        );
        assert_eq!(
            deserialized.prior_task_summaries,
            result.pack.prior_task_summaries
        );
    }

    #[test]
    fn context_compiler_config_round_trip_serde_json() {
        let config = ContextCompilerConfig {
            mode: ContextCompileMode::V2,
            token_budget: 5000,
        };
        let json = serde_json::to_string(&config).expect("serialize config");
        let deserialized: ContextCompilerConfig =
            serde_json::from_str(&json).expect("deserialize config");
        assert_eq!(deserialized.mode, config.mode);
        assert_eq!(deserialized.token_budget, config.token_budget);
    }

    #[test]
    fn compile_v2_redacts_known_secret_values_in_markdown_and_pack() {
        let secret = "plain-known-secret-value";
        let compiler = ContextCompiler::new(
            ContextCompilerConfig {
                mode: ContextCompileMode::V2,
                token_budget: 10_000,
            },
            vec![secret.to_string()],
        );

        let result = compiler
            .compile(ContextCompileInput {
                task: make_task(secret),
                project_brief: format!("brief {secret}"),
                architecture_notes: format!("notes {secret}"),
                conventions: vec![format!("convention {secret}")],
                rules: vec![format!("rule {secret}")],
                relevant_file_contents: vec![(
                    "src/main.rs".to_string(),
                    format!("const S: &str = \"{secret}\";"),
                )],
                prior_task_summaries: vec![format!("prior {secret}")],
            })
            .expect("compile");

        assert!(!result.markdown.contains(secret));

        let pack = format!("{:?}", result.pack);
        assert!(!pack.contains(secret));
        assert!(pack.contains("[REDACTED]"));
    }
}
