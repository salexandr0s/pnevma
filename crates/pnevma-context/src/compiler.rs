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
        std::fs::write(path, markdown)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
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
            architecture_notes: String::new(),
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
            .map(|(path, content)| (path.clone(), self.redact_string(content)))
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
    use pnevma_core::{Check, CheckType, Priority, TaskStatus};
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
