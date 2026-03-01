use crate::error::ContextError;
use pnevma_core::{ContextManifestItem, ContextPack, TaskContract};
use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum ContextCompileMode {
    V1,
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
}

impl ContextCompiler {
    pub fn new(config: ContextCompilerConfig) -> Self {
        Self { config }
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
            ContextCompileMode::V1 => self.compile_v1(input),
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
        Ok(())
    }

    fn compile_v1(
        &self,
        input: ContextCompileInput,
    ) -> Result<ContextCompilerResult, ContextError> {
        let task = input.task;
        if task.goal.trim().is_empty() {
            return Err(ContextError::Compile(
                "task goal cannot be empty for context compilation".to_string(),
            ));
        }
        let markdown = format!(
            "# Task Context\n\n## Goal\n{}\n\n## Acceptance Criteria\n{}\n\n## Constraints\n{}\n\n## Scope\n{}\n\n## Rules\n{}\n",
            task.goal,
            task.acceptance_criteria
                .iter()
                .map(|c| format!("- {}", c.description))
                .collect::<Vec<_>>()
                .join("\n"),
            task.constraints
                .iter()
                .map(|c| format!("- {}", c))
                .collect::<Vec<_>>()
                .join("\n"),
            task.scope
                .iter()
                .map(|s| format!("- {}", s))
                .collect::<Vec<_>>()
                .join("\n"),
            input
                .rules
                .iter()
                .map(|r| format!("- {}", r))
                .collect::<Vec<_>>()
                .join("\n")
        );

        let pack = ContextPack {
            task_contract: Box::new(task),
            project_brief: input.project_brief,
            architecture_notes: input.architecture_notes,
            conventions: input.conventions,
            rules: input.rules,
            relevant_file_contents: input.relevant_file_contents,
            prior_task_summaries: input.prior_task_summaries,
            token_budget: self.config.token_budget,
            actual_tokens: markdown.len() / 4,
            manifest: vec![ContextManifestItem {
                kind: "v1_simplified".to_string(),
                included: true,
                reason: None,
            }],
        };

        Ok(ContextCompilerResult { pack, markdown })
    }

    fn compile_v2(
        &self,
        input: ContextCompileInput,
    ) -> Result<ContextCompilerResult, ContextError> {
        if input.task.goal.trim().is_empty() {
            return Err(ContextError::Compile(
                "task goal cannot be empty for context compilation".to_string(),
            ));
        }

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

        let task = input.task;
        push_section(
            "## Task Contract",
            format!("title: {}\ngoal: {}", task.title, task.goal),
            true,
            &mut manifest,
        );

        push_section(
            "## Relevant Files",
            input
                .relevant_file_contents
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
                input.rules.join("\n"),
                input.conventions.join("\n")
            ),
            false,
            &mut manifest,
        );

        push_section(
            "## Architecture Notes",
            input.architecture_notes,
            false,
            &mut manifest,
        );

        push_section(
            "## Prior Summaries",
            input.prior_task_summaries.join("\n"),
            false,
            &mut manifest,
        );

        push_section(
            "## Project Brief",
            input.project_brief.clone(),
            false,
            &mut manifest,
        );

        let pack = ContextPack {
            task_contract: Box::new(task),
            project_brief: input.project_brief,
            architecture_notes: String::new(),
            conventions: input.conventions,
            rules: input.rules,
            relevant_file_contents: input.relevant_file_contents,
            prior_task_summaries: input.prior_task_summaries,
            token_budget: budget,
            actual_tokens: used,
            manifest,
        };

        Ok(ContextCompilerResult {
            pack,
            markdown: text,
        })
    }
}
