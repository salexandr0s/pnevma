use super::*;

impl Db {
    // ── Artifacts ────────────────────────────────────────────────────────────

    pub async fn list_artifacts(&self, project_id: &str) -> Result<Vec<ArtifactRow>, DbError> {
        let rows = sqlx::query_as::<_, ArtifactRow>(
            r#"
            SELECT id, project_id, task_id, type, path, description, created_at
            FROM artifacts
            WHERE project_id = ?1
            ORDER BY created_at DESC
            "#,
        )
        .bind(project_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    pub async fn create_artifact(&self, row: &ArtifactRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO artifacts (id, project_id, task_id, type, path, description, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            "#,
        )
        .bind(&row.id)
        .bind(&row.project_id)
        .bind(&row.task_id)
        .bind(&row.r#type)
        .bind(&row.path)
        .bind(&row.description)
        .bind(row.created_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn delete_artifact(&self, artifact_id: &str) -> Result<(), DbError> {
        sqlx::query("DELETE FROM artifacts WHERE id = ?1")
            .bind(artifact_id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    // ── Rules ────────────────────────────────────────────────────────────────

    pub async fn upsert_rule(&self, row: &RuleRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO rules (id, project_id, name, path, scope, active)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            ON CONFLICT(id) DO UPDATE SET
              name = excluded.name,
              path = excluded.path,
              scope = excluded.scope,
              active = excluded.active
            "#,
        )
        .bind(&row.id)
        .bind(&row.project_id)
        .bind(&row.name)
        .bind(&row.path)
        .bind(&row.scope)
        .bind(row.active)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn list_rules(
        &self,
        project_id: &str,
        scope: Option<&str>,
    ) -> Result<Vec<RuleRow>, DbError> {
        let rows = match scope {
            Some(scope) => {
                sqlx::query_as::<_, RuleRow>(
                    r#"
                    SELECT id, project_id, name, path, scope, active
                    FROM rules
                    WHERE project_id = ?1 AND scope = ?2
                    ORDER BY active DESC, name ASC
                    "#,
                )
                .bind(project_id)
                .bind(scope)
                .fetch_all(&self.pool)
                .await?
            }
            None => {
                sqlx::query_as::<_, RuleRow>(
                    r#"
                    SELECT id, project_id, name, path, scope, active
                    FROM rules
                    WHERE project_id = ?1
                    ORDER BY active DESC, name ASC
                    "#,
                )
                .bind(project_id)
                .fetch_all(&self.pool)
                .await?
            }
        };
        Ok(rows)
    }

    pub async fn get_rule(&self, rule_id: &str) -> Result<Option<RuleRow>, DbError> {
        let row = sqlx::query_as::<_, RuleRow>(
            r#"
            SELECT id, project_id, name, path, scope, active
            FROM rules
            WHERE id = ?1
            LIMIT 1
            "#,
        )
        .bind(rule_id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }

    pub async fn delete_rule(&self, rule_id: &str) -> Result<(), DbError> {
        sqlx::query("DELETE FROM rules WHERE id = ?1")
            .bind(rule_id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn create_context_rule_usage(
        &self,
        row: &ContextRuleUsageRow,
    ) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO context_rule_usage
            (id, project_id, run_id, rule_id, included, reason, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            "#,
        )
        .bind(&row.id)
        .bind(&row.project_id)
        .bind(&row.run_id)
        .bind(&row.rule_id)
        .bind(row.included)
        .bind(&row.reason)
        .bind(row.created_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn list_context_rule_usage(
        &self,
        project_id: &str,
        rule_id: &str,
        limit: i64,
    ) -> Result<Vec<ContextRuleUsageRow>, DbError> {
        let rows = sqlx::query_as::<_, ContextRuleUsageRow>(
            r#"
            SELECT id, project_id, run_id, rule_id, included, reason, created_at
            FROM context_rule_usage
            WHERE project_id = ?1 AND rule_id = ?2
            ORDER BY created_at DESC
            LIMIT ?3
            "#,
        )
        .bind(project_id)
        .bind(rule_id)
        .bind(limit)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    // ── Onboarding ───────────────────────────────────────────────────────────

    pub async fn upsert_onboarding_state(&self, row: &OnboardingStateRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO onboarding_state (project_id, step, completed, dismissed, updated_at)
            VALUES (?1, ?2, ?3, ?4, ?5)
            ON CONFLICT(project_id) DO UPDATE SET
              step = excluded.step,
              completed = excluded.completed,
              dismissed = excluded.dismissed,
              updated_at = excluded.updated_at
            "#,
        )
        .bind(&row.project_id)
        .bind(&row.step)
        .bind(row.completed)
        .bind(row.dismissed)
        .bind(row.updated_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn get_onboarding_state(
        &self,
        project_id: &str,
    ) -> Result<Option<OnboardingStateRow>, DbError> {
        let row = sqlx::query_as::<_, OnboardingStateRow>(
            r#"
            SELECT project_id, step, completed, dismissed, updated_at
            FROM onboarding_state
            WHERE project_id = ?1
            LIMIT 1
            "#,
        )
        .bind(project_id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }

    // ── Telemetry ────────────────────────────────────────────────────────────

    pub async fn append_telemetry_event(&self, row: &TelemetryEventRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO telemetry_events (id, project_id, event_type, payload_json, anonymized, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            "#,
        )
        .bind(&row.id)
        .bind(&row.project_id)
        .bind(&row.event_type)
        .bind(&row.payload_json)
        .bind(row.anonymized)
        .bind(row.created_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn list_telemetry_events(
        &self,
        project_id: &str,
        limit: i64,
    ) -> Result<Vec<TelemetryEventRow>, DbError> {
        let rows = sqlx::query_as::<_, TelemetryEventRow>(
            r#"
            SELECT id, project_id, event_type, payload_json, anonymized, created_at
            FROM telemetry_events
            WHERE project_id = ?1
            ORDER BY created_at DESC
            LIMIT ?2
            "#,
        )
        .bind(project_id)
        .bind(limit)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    pub async fn count_telemetry_events(&self, project_id: &str) -> Result<i64, DbError> {
        let count = sqlx::query_scalar::<_, i64>(
            r#"
            SELECT COUNT(*)
            FROM telemetry_events
            WHERE project_id = ?1
            "#,
        )
        .bind(project_id)
        .fetch_one(&self.pool)
        .await?;
        Ok(count)
    }

    pub async fn clear_telemetry_events(&self, project_id: &str) -> Result<(), DbError> {
        sqlx::query("DELETE FROM telemetry_events WHERE project_id = ?1")
            .bind(project_id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    // ── Feedback ─────────────────────────────────────────────────────────────

    pub async fn create_feedback(&self, row: &FeedbackRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO feedback_entries
            (id, project_id, category, body, contact, artifact_path, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            "#,
        )
        .bind(&row.id)
        .bind(&row.project_id)
        .bind(&row.category)
        .bind(&row.body)
        .bind(&row.contact)
        .bind(&row.artifact_path)
        .bind(row.created_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn list_feedback(
        &self,
        project_id: &str,
        limit: i64,
    ) -> Result<Vec<FeedbackRow>, DbError> {
        let rows = sqlx::query_as::<_, FeedbackRow>(
            r#"
            SELECT id, project_id, category, body, contact, artifact_path, created_at
            FROM feedback_entries
            WHERE project_id = ?1
            ORDER BY created_at DESC
            LIMIT ?2
            "#,
        )
        .bind(project_id)
        .bind(limit)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    pub async fn clear_feedback_artifact_path(&self, feedback_id: &str) -> Result<(), DbError> {
        sqlx::query(
            r#"
            UPDATE feedback_entries
            SET artifact_path = NULL
            WHERE id = ?1
            "#,
        )
        .bind(feedback_id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    // ── Secret refs ──────────────────────────────────────────────────────────

    pub async fn upsert_secret_ref(&self, row: &SecretRefRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO secret_refs
            (
              id,
              project_id,
              scope,
              name,
              backend,
              keychain_service,
              keychain_account,
              env_file_path,
              created_at,
              updated_at
            )
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
            ON CONFLICT(project_id, scope, name) DO UPDATE SET
              backend = excluded.backend,
              keychain_service = excluded.keychain_service,
              keychain_account = excluded.keychain_account,
              env_file_path = excluded.env_file_path,
              updated_at = excluded.updated_at
            "#,
        )
        .bind(&row.id)
        .bind(&row.project_id)
        .bind(&row.scope)
        .bind(&row.name)
        .bind(&row.backend)
        .bind(&row.keychain_service)
        .bind(&row.keychain_account)
        .bind(&row.env_file_path)
        .bind(row.created_at)
        .bind(row.updated_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn update_secret_ref(&self, row: &SecretRefRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            UPDATE secret_refs
            SET
              project_id = ?2,
              scope = ?3,
              name = ?4,
              backend = ?5,
              keychain_service = ?6,
              keychain_account = ?7,
              env_file_path = ?8,
              updated_at = ?9
            WHERE id = ?1
            "#,
        )
        .bind(&row.id)
        .bind(&row.project_id)
        .bind(&row.scope)
        .bind(&row.name)
        .bind(&row.backend)
        .bind(&row.keychain_service)
        .bind(&row.keychain_account)
        .bind(&row.env_file_path)
        .bind(row.updated_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn list_secret_refs(
        &self,
        project_id: &str,
        scope: Option<&str>,
    ) -> Result<Vec<SecretRefRow>, DbError> {
        let rows = match scope {
            Some(scope) => {
                sqlx::query_as::<_, SecretRefRow>(
                    r#"
                    SELECT
                      id,
                      project_id,
                      scope,
                      name,
                      backend,
                      keychain_service,
                      keychain_account,
                      env_file_path,
                      created_at,
                      updated_at
                    FROM secret_refs
                    WHERE (project_id IS NULL OR project_id = ?1) AND scope = ?2
                    ORDER BY scope ASC, name ASC
                    "#,
                )
                .bind(project_id)
                .bind(scope)
                .fetch_all(&self.pool)
                .await?
            }
            None => {
                sqlx::query_as::<_, SecretRefRow>(
                    r#"
                    SELECT
                      id,
                      project_id,
                      scope,
                      name,
                      backend,
                      keychain_service,
                      keychain_account,
                      env_file_path,
                      created_at,
                      updated_at
                    FROM secret_refs
                    WHERE project_id IS NULL OR project_id = ?1
                    ORDER BY scope ASC, name ASC
                    "#,
                )
                .bind(project_id)
                .fetch_all(&self.pool)
                .await?
            }
        };
        Ok(rows)
    }

    pub async fn get_secret_ref(&self, id: &str) -> Result<Option<SecretRefRow>, DbError> {
        sqlx::query_as::<_, SecretRefRow>(
            r#"
            SELECT
              id,
              project_id,
              scope,
              name,
              backend,
              keychain_service,
              keychain_account,
              env_file_path,
              created_at,
              updated_at
            FROM secret_refs
            WHERE id = ?1
            "#,
        )
        .bind(id)
        .fetch_optional(&self.pool)
        .await
        .map_err(Into::into)
    }

    pub async fn delete_secret_ref(&self, id: &str) -> Result<(), DbError> {
        sqlx::query("DELETE FROM secret_refs WHERE id = ?1")
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    // ── Checkpoints ──────────────────────────────────────────────────────────

    pub async fn create_checkpoint(&self, row: &CheckpointRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO checkpoints
            (id, project_id, task_id, git_ref, session_metadata_json, created_at, description)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            "#,
        )
        .bind(&row.id)
        .bind(&row.project_id)
        .bind(&row.task_id)
        .bind(&row.git_ref)
        .bind(&row.session_metadata_json)
        .bind(row.created_at)
        .bind(&row.description)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn list_checkpoints(&self, project_id: &str) -> Result<Vec<CheckpointRow>, DbError> {
        let rows = sqlx::query_as::<_, CheckpointRow>(
            r#"
            SELECT id, project_id, task_id, git_ref, session_metadata_json, created_at, description
            FROM checkpoints
            WHERE project_id = ?1
            ORDER BY created_at DESC
            "#,
        )
        .bind(project_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    pub async fn get_checkpoint(
        &self,
        checkpoint_id: &str,
    ) -> Result<Option<CheckpointRow>, DbError> {
        let row = sqlx::query_as::<_, CheckpointRow>(
            r#"
            SELECT id, project_id, task_id, git_ref, session_metadata_json, created_at, description
            FROM checkpoints
            WHERE id = ?1
            LIMIT 1
            "#,
        )
        .bind(checkpoint_id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }

    // ── SSH profiles ─────────────────────────────────────────────────────────

    pub async fn list_ssh_profiles(&self, project_id: &str) -> Result<Vec<SshProfileRow>, DbError> {
        let rows = sqlx::query_as::<_, SshProfileRow>(
            "SELECT id, project_id, name, host, port, user, identity_file, proxy_jump, tags_json, source, created_at, updated_at FROM ssh_profiles WHERE project_id = ? ORDER BY name"
        )
        .bind(project_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    pub async fn get_ssh_profile(&self, id: &str) -> Result<SshProfileRow, DbError> {
        let row = sqlx::query_as::<_, SshProfileRow>(
            "SELECT id, project_id, name, host, port, user, identity_file, proxy_jump, tags_json, source, created_at, updated_at FROM ssh_profiles WHERE id = ?"
        )
        .bind(id)
        .fetch_one(&self.pool)
        .await?;
        Ok(row)
    }

    pub async fn upsert_ssh_profile(&self, row: &SshProfileRow) -> Result<(), DbError> {
        sqlx::query(
            "INSERT INTO ssh_profiles (id, project_id, name, host, port, user, identity_file, proxy_jump, tags_json, source, created_at, updated_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
             ON CONFLICT(id) DO UPDATE SET name=excluded.name, host=excluded.host, port=excluded.port, user=excluded.user, identity_file=excluded.identity_file, proxy_jump=excluded.proxy_jump, tags_json=excluded.tags_json, source=excluded.source, updated_at=excluded.updated_at"
        )
        .bind(&row.id)
        .bind(&row.project_id)
        .bind(&row.name)
        .bind(&row.host)
        .bind(row.port)
        .bind(&row.user)
        .bind(&row.identity_file)
        .bind(&row.proxy_jump)
        .bind(&row.tags_json)
        .bind(&row.source)
        .bind(row.created_at)
        .bind(row.updated_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn delete_ssh_profile(&self, id: &str) -> Result<(), DbError> {
        sqlx::query("DELETE FROM ssh_profiles WHERE id = ?")
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    // ── Error Signature methods ──────────────────────────────────────────────

    pub async fn upsert_error_signature(&self, row: &ErrorSignatureRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO error_signatures
                (id, project_id, signature_hash, canonical_message, category,
                 first_seen, last_seen, total_count, sample_output, remediation_hint)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
            ON CONFLICT(project_id, signature_hash) DO UPDATE SET
                last_seen = excluded.last_seen,
                total_count = total_count + 1,
                sample_output = excluded.sample_output
            "#,
        )
        .bind(&row.id)
        .bind(&row.project_id)
        .bind(&row.signature_hash)
        .bind(&row.canonical_message)
        .bind(&row.category)
        .bind(row.first_seen)
        .bind(row.last_seen)
        .bind(row.total_count)
        .bind(&row.sample_output)
        .bind(&row.remediation_hint)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn increment_error_signature_daily(
        &self,
        signature_id: &str,
        date: &str,
    ) -> Result<(), DbError> {
        let id = uuid::Uuid::new_v4().to_string();
        sqlx::query(
            r#"
            INSERT INTO error_signature_daily (id, signature_id, date, count)
            VALUES (?1, ?2, ?3, 1)
            ON CONFLICT(signature_id, date) DO UPDATE SET count = count + 1
            "#,
        )
        .bind(&id)
        .bind(signature_id)
        .bind(date)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn list_error_signatures(
        &self,
        project_id: &str,
        limit: i64,
    ) -> Result<Vec<ErrorSignatureRow>, DbError> {
        let rows = sqlx::query_as::<_, ErrorSignatureRow>(
            r#"
            SELECT id, project_id, signature_hash, canonical_message, category,
                   first_seen, last_seen, total_count, sample_output, remediation_hint
            FROM error_signatures
            WHERE project_id = ?1
            ORDER BY total_count DESC
            LIMIT ?2
            "#,
        )
        .bind(project_id)
        .bind(limit)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    pub async fn get_error_signature(
        &self,
        id: &str,
    ) -> Result<Option<ErrorSignatureRow>, DbError> {
        let row = sqlx::query_as::<_, ErrorSignatureRow>(
            r#"
            SELECT id, project_id, signature_hash, canonical_message, category,
                   first_seen, last_seen, total_count, sample_output, remediation_hint
            FROM error_signatures WHERE id = ?1
            "#,
        )
        .bind(id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }

    pub async fn get_error_trend(
        &self,
        project_id: &str,
        days: i64,
    ) -> Result<Vec<ErrorSignatureDailyRow>, DbError> {
        let rows = sqlx::query_as::<_, ErrorSignatureDailyRow>(
            r#"
            SELECT esd.id, esd.signature_id, esd.date, esd.count,
                   es.signature_hash, es.category
            FROM error_signature_daily esd
            JOIN error_signatures es ON es.id = esd.signature_id
            WHERE es.project_id = ?1
              AND esd.date >= date('now', '-' || ?2 || ' days')
            ORDER BY esd.date ASC
            "#,
        )
        .bind(project_id)
        .bind(days)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    // ── Agent Profile methods ───────────────────────────────────────────────

    pub async fn create_agent_profile(&self, row: &AgentProfileRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO agent_profiles
                (id, project_id, name, provider, model, token_budget, timeout_minutes,
                 max_concurrent, stations_json, config_json, active, created_at, updated_at,
                 role, system_prompt, source, source_path, user_modified,
                 thinking_level, thinking_budget, tool_restrictions_json, extra_flags_json)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22)
            "#,
        )
        .bind(&row.id)
        .bind(&row.project_id)
        .bind(&row.name)
        .bind(&row.provider)
        .bind(&row.model)
        .bind(row.token_budget)
        .bind(row.timeout_minutes)
        .bind(row.max_concurrent)
        .bind(&row.stations_json)
        .bind(&row.config_json)
        .bind(row.active)
        .bind(row.created_at)
        .bind(row.updated_at)
        .bind(&row.role)
        .bind(&row.system_prompt)
        .bind(&row.source)
        .bind(&row.source_path)
        .bind(row.user_modified)
        .bind(&row.thinking_level)
        .bind(row.thinking_budget)
        .bind(&row.tool_restrictions_json)
        .bind(&row.extra_flags_json)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn get_agent_profile(&self, id: &str) -> Result<Option<AgentProfileRow>, DbError> {
        let row = sqlx::query_as::<_, AgentProfileRow>(
            r#"
            SELECT id, project_id, name, provider, model, token_budget, timeout_minutes,
                   max_concurrent, stations_json, config_json, active, created_at, updated_at,
                   role, system_prompt, source, source_path, user_modified,
                   thinking_level, thinking_budget, tool_restrictions_json, extra_flags_json
            FROM agent_profiles
            WHERE id = ?1
            "#,
        )
        .bind(id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }

    pub async fn get_agent_profile_by_name(
        &self,
        project_id: &str,
        name: &str,
    ) -> Result<Option<AgentProfileRow>, DbError> {
        let row = sqlx::query_as::<_, AgentProfileRow>(
            r#"
            SELECT id, project_id, name, provider, model, token_budget, timeout_minutes,
                   max_concurrent, stations_json, config_json, active, created_at, updated_at,
                   role, system_prompt, source, source_path, user_modified,
                   thinking_level, thinking_budget, tool_restrictions_json, extra_flags_json
            FROM agent_profiles
            WHERE project_id = ?1 AND name = ?2
            "#,
        )
        .bind(project_id)
        .bind(name)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }

    pub async fn get_agent_profile_by_source_path(
        &self,
        project_id: &str,
        source_path: &str,
    ) -> Result<Option<AgentProfileRow>, DbError> {
        let row = sqlx::query_as::<_, AgentProfileRow>(
            r#"
            SELECT id, project_id, name, provider, model, token_budget, timeout_minutes,
                   max_concurrent, stations_json, config_json, active, created_at, updated_at,
                   role, system_prompt, source, source_path, user_modified,
                   thinking_level, thinking_budget, tool_restrictions_json, extra_flags_json
            FROM agent_profiles
            WHERE project_id = ?1 AND source_path = ?2
            "#,
        )
        .bind(project_id)
        .bind(source_path)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }

    pub async fn list_agent_profiles(
        &self,
        project_id: &str,
    ) -> Result<Vec<AgentProfileRow>, DbError> {
        let rows = sqlx::query_as::<_, AgentProfileRow>(
            r#"
            SELECT id, project_id, name, provider, model, token_budget, timeout_minutes,
                   max_concurrent, stations_json, config_json, active, created_at, updated_at,
                   role, system_prompt, source, source_path, user_modified,
                   thinking_level, thinking_budget, tool_restrictions_json, extra_flags_json
            FROM agent_profiles
            WHERE project_id = ?1 AND active = 1
            ORDER BY name
            "#,
        )
        .bind(project_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    pub async fn update_agent_profile(&self, row: &AgentProfileRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            UPDATE agent_profiles
            SET name = ?1, provider = ?2, model = ?3, token_budget = ?4,
                timeout_minutes = ?5, max_concurrent = ?6, stations_json = ?7,
                config_json = ?8, active = ?9, updated_at = ?10,
                role = ?11, system_prompt = ?12,
                source = ?13, source_path = ?14, user_modified = ?15,
                thinking_level = ?16, thinking_budget = ?17,
                tool_restrictions_json = ?18, extra_flags_json = ?19
            WHERE id = ?20
            "#,
        )
        .bind(&row.name)
        .bind(&row.provider)
        .bind(&row.model)
        .bind(row.token_budget)
        .bind(row.timeout_minutes)
        .bind(row.max_concurrent)
        .bind(&row.stations_json)
        .bind(&row.config_json)
        .bind(row.active)
        .bind(row.updated_at)
        .bind(&row.role)
        .bind(&row.system_prompt)
        .bind(&row.source)
        .bind(&row.source_path)
        .bind(row.user_modified)
        .bind(&row.thinking_level)
        .bind(row.thinking_budget)
        .bind(&row.tool_restrictions_json)
        .bind(&row.extra_flags_json)
        .bind(&row.id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn delete_agent_profile(&self, id: &str) -> Result<(), DbError> {
        sqlx::query("DELETE FROM agent_profiles WHERE id = ?1")
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    // ── Automation runs ──────────────────────────────────────────────────────

    pub async fn create_automation_run(&self, row: &AutomationRunRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO automation_runs
            (id, project_id, task_id, run_id, origin, provider, model, status, attempt,
             started_at, finished_at, duration_seconds, tokens_in, tokens_out, cost_usd,
             summary, error_message, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18)
            "#,
        )
        .bind(&row.id)
        .bind(&row.project_id)
        .bind(&row.task_id)
        .bind(&row.run_id)
        .bind(&row.origin)
        .bind(&row.provider)
        .bind(&row.model)
        .bind(&row.status)
        .bind(row.attempt)
        .bind(row.started_at)
        .bind(row.finished_at)
        .bind(row.duration_seconds)
        .bind(row.tokens_in)
        .bind(row.tokens_out)
        .bind(row.cost_usd)
        .bind(&row.summary)
        .bind(&row.error_message)
        .bind(row.created_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn update_automation_run_status(
        &self,
        id: &str,
        status: &str,
        finished_at: Option<DateTime<Utc>>,
        duration_seconds: Option<f64>,
        error_message: Option<&str>,
    ) -> Result<(), DbError> {
        sqlx::query(
            r#"
            UPDATE automation_runs
            SET status = ?2, finished_at = ?3, duration_seconds = ?4, error_message = ?5
            WHERE id = ?1
            "#,
        )
        .bind(id)
        .bind(status)
        .bind(finished_at)
        .bind(duration_seconds)
        .bind(error_message)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn update_automation_run_usage(
        &self,
        id: &str,
        tokens_in: i64,
        tokens_out: i64,
        cost_usd: f64,
        summary: Option<&str>,
    ) -> Result<(), DbError> {
        sqlx::query(
            r#"
            UPDATE automation_runs
            SET tokens_in = ?2, tokens_out = ?3, cost_usd = ?4, summary = ?5
            WHERE id = ?1
            "#,
        )
        .bind(id)
        .bind(tokens_in)
        .bind(tokens_out)
        .bind(cost_usd)
        .bind(summary)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn get_automation_run(&self, id: &str) -> Result<Option<AutomationRunRow>, DbError> {
        let row = sqlx::query_as::<_, AutomationRunRow>(
            r#"
            SELECT id, project_id, task_id, run_id, origin, provider, model, status, attempt,
                   started_at, finished_at, duration_seconds, tokens_in, tokens_out, cost_usd,
                   summary, error_message, created_at
            FROM automation_runs
            WHERE id = ?1
            LIMIT 1
            "#,
        )
        .bind(id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }

    pub async fn list_automation_runs(
        &self,
        project_id: &str,
        limit: i64,
    ) -> Result<Vec<AutomationRunRow>, DbError> {
        let rows = sqlx::query_as::<_, AutomationRunRow>(
            r#"
            SELECT id, project_id, task_id, run_id, origin, provider, model, status, attempt,
                   started_at, finished_at, duration_seconds, tokens_in, tokens_out, cost_usd,
                   summary, error_message, created_at
            FROM automation_runs
            WHERE project_id = ?1
            ORDER BY started_at DESC
            LIMIT ?2
            "#,
        )
        .bind(project_id)
        .bind(limit)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    pub async fn list_active_automation_runs(
        &self,
        project_id: &str,
    ) -> Result<Vec<AutomationRunRow>, DbError> {
        let rows = sqlx::query_as::<_, AutomationRunRow>(
            r#"
            SELECT id, project_id, task_id, run_id, origin, provider, model, status, attempt,
                   started_at, finished_at, duration_seconds, tokens_in, tokens_out, cost_usd,
                   summary, error_message, created_at
            FROM automation_runs
            WHERE project_id = ?1 AND status = 'running'
            ORDER BY started_at DESC
            "#,
        )
        .bind(project_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    pub async fn create_automation_retry(&self, row: &AutomationRetryRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO automation_retries
            (id, project_id, run_id, task_id, attempt, reason, retry_after, retried_at, outcome, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
            "#,
        )
        .bind(&row.id)
        .bind(&row.project_id)
        .bind(&row.run_id)
        .bind(&row.task_id)
        .bind(row.attempt)
        .bind(&row.reason)
        .bind(row.retry_after)
        .bind(row.retried_at)
        .bind(&row.outcome)
        .bind(row.created_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn update_automation_retry_outcome(
        &self,
        id: &str,
        outcome: &str,
        retried_at: Option<DateTime<Utc>>,
    ) -> Result<(), DbError> {
        sqlx::query(
            r#"
            UPDATE automation_retries
            SET outcome = ?2, retried_at = ?3
            WHERE id = ?1
            "#,
        )
        .bind(id)
        .bind(outcome)
        .bind(retried_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn list_pending_retries(
        &self,
        project_id: &str,
    ) -> Result<Vec<AutomationRetryRow>, DbError> {
        let rows = sqlx::query_as::<_, AutomationRetryRow>(
            r#"
            SELECT id, project_id, run_id, task_id, attempt, reason, retry_after,
                   retried_at, outcome, created_at
            FROM automation_retries
            WHERE project_id = ?1 AND retried_at IS NULL
            ORDER BY retry_after ASC
            "#,
        )
        .bind(project_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    /// Mark all automation runs stuck in 'running' as 'failed' for a project.
    /// Used at startup to recover from crashes that left zombie run rows.
    /// Returns the number of rows updated.
    pub async fn mark_stale_automation_runs(&self, project_id: &str) -> Result<u64, DbError> {
        let result = sqlx::query(
            r#"
            UPDATE automation_runs
            SET status = 'failed',
                finished_at = datetime('now'),
                error_message = 'recovered: process terminated while running'
            WHERE project_id = ?1 AND status = 'running'
            "#,
        )
        .bind(project_id)
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected())
    }
}
