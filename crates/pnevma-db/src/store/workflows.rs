use super::*;

impl Db {
    // ─── Workflow definitions ────────────────────────────────────────────────

    pub async fn create_workflow(&self, row: &WorkflowRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO workflows (id, project_id, name, description, definition_yaml, source, created_at, updated_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
            "#,
        )
        .bind(&row.id)
        .bind(&row.project_id)
        .bind(&row.name)
        .bind(&row.description)
        .bind(&row.definition_yaml)
        .bind(&row.source)
        .bind(row.created_at)
        .bind(row.updated_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn get_workflow(&self, id: &str) -> Result<Option<WorkflowRow>, DbError> {
        let row = sqlx::query_as::<_, WorkflowRow>(
            r#"
            SELECT id, project_id, name, description, definition_yaml, source, created_at, updated_at
            FROM workflows WHERE id = ?1
            "#,
        )
        .bind(id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }

    pub async fn get_workflow_by_name(
        &self,
        project_id: &str,
        name: &str,
    ) -> Result<Option<WorkflowRow>, DbError> {
        let row = sqlx::query_as::<_, WorkflowRow>(
            r#"
            SELECT id, project_id, name, description, definition_yaml, source, created_at, updated_at
            FROM workflows WHERE project_id = ?1 AND name = ?2
            "#,
        )
        .bind(project_id)
        .bind(name)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }

    pub async fn list_workflows(&self, project_id: &str) -> Result<Vec<WorkflowRow>, DbError> {
        let rows = sqlx::query_as::<_, WorkflowRow>(
            r#"
            SELECT id, project_id, name, description, definition_yaml, source, created_at, updated_at
            FROM workflows WHERE project_id = ?1
            ORDER BY name ASC
            "#,
        )
        .bind(project_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    pub async fn update_workflow(&self, row: &WorkflowRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            UPDATE workflows
            SET name = ?1, description = ?2, definition_yaml = ?3, source = ?4, updated_at = ?5
            WHERE id = ?6
            "#,
        )
        .bind(&row.name)
        .bind(&row.description)
        .bind(&row.definition_yaml)
        .bind(&row.source)
        .bind(row.updated_at)
        .bind(&row.id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn delete_workflow(&self, id: &str) -> Result<(), DbError> {
        sqlx::query("DELETE FROM workflows WHERE id = ?1")
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    // ─── Workflow instances ──────────────────────────────────────────

    pub async fn create_workflow_instance(
        &self,
        instance: &WorkflowInstanceRow,
    ) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO workflow_instances (id, project_id, workflow_name, description, status, created_at, updated_at, params_json, stage_results_json, expanded_steps_json)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
            "#,
        )
        .bind(&instance.id)
        .bind(&instance.project_id)
        .bind(&instance.workflow_name)
        .bind(&instance.description)
        .bind(&instance.status)
        .bind(instance.created_at)
        .bind(instance.updated_at)
        .bind(&instance.params_json)
        .bind(&instance.stage_results_json)
        .bind(&instance.expanded_steps_json)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn update_workflow_instance_status(
        &self,
        workflow_id: &str,
        status: &str,
    ) -> Result<(), DbError> {
        sqlx::query(
            r#"
            UPDATE workflow_instances SET status = ?1, updated_at = ?2 WHERE id = ?3
            "#,
        )
        .bind(status)
        .bind(Utc::now())
        .bind(workflow_id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn get_workflow_instance(
        &self,
        workflow_id: &str,
    ) -> Result<Option<WorkflowInstanceRow>, DbError> {
        let row = sqlx::query_as::<_, WorkflowInstanceRow>(
            r#"
            SELECT id, project_id, workflow_name, description, status, created_at, updated_at,
                   params_json, stage_results_json, expanded_steps_json
            FROM workflow_instances WHERE id = ?1
            "#,
        )
        .bind(workflow_id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }

    pub async fn list_workflow_instances(
        &self,
        project_id: &str,
    ) -> Result<Vec<WorkflowInstanceRow>, DbError> {
        let rows = sqlx::query_as::<_, WorkflowInstanceRow>(
            r#"
            SELECT id, project_id, workflow_name, description, status, created_at, updated_at,
                   params_json, stage_results_json, expanded_steps_json
            FROM workflow_instances WHERE project_id = ?1
            ORDER BY created_at DESC
            "#,
        )
        .bind(project_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    pub async fn add_workflow_task(
        &self,
        workflow_id: &str,
        step_index: i64,
        iteration: i64,
        task_id: &str,
    ) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO workflow_tasks (workflow_id, step_index, iteration, task_id)
            VALUES (?1, ?2, ?3, ?4)
            "#,
        )
        .bind(workflow_id)
        .bind(step_index)
        .bind(iteration)
        .bind(task_id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn list_workflow_tasks(
        &self,
        workflow_id: &str,
    ) -> Result<Vec<WorkflowTaskRow>, DbError> {
        let rows = sqlx::query_as::<_, WorkflowTaskRow>(
            r#"
            SELECT workflow_id, step_index, iteration, task_id
            FROM workflow_tasks WHERE workflow_id = ?1
            ORDER BY step_index ASC, iteration ASC
            "#,
        )
        .bind(workflow_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    pub async fn find_workflow_by_task(
        &self,
        task_id: &str,
    ) -> Result<Option<WorkflowTaskRow>, DbError> {
        let row = sqlx::query_as::<_, WorkflowTaskRow>(
            r#"
            SELECT workflow_id, step_index, iteration, task_id
            FROM workflow_tasks WHERE task_id = ?1
            "#,
        )
        .bind(task_id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }

    /// Get the latest (highest) iteration number for a step in a workflow.
    pub async fn get_latest_iteration(
        &self,
        workflow_id: &str,
        step_index: i64,
    ) -> Result<i64, DbError> {
        let row: (i64,) = sqlx::query_as(
            r#"
            SELECT COALESCE(MAX(iteration), 0)
            FROM workflow_tasks
            WHERE workflow_id = ?1 AND step_index = ?2
            "#,
        )
        .bind(workflow_id)
        .bind(step_index)
        .fetch_one(&self.pool)
        .await?;
        Ok(row.0)
    }

    pub async fn update_workflow_instance_results(
        &self,
        id: &str,
        stage_results_json: &str,
        status: &str,
    ) -> Result<(), DbError> {
        sqlx::query(
            r#"
            UPDATE workflow_instances
            SET stage_results_json = ?1, status = ?2, updated_at = ?3
            WHERE id = ?4
            "#,
        )
        .bind(stage_results_json)
        .bind(status)
        .bind(Utc::now())
        .bind(id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Update expanded_steps_json on a workflow instance.
    pub async fn update_workflow_instance_expanded_steps(
        &self,
        workflow_id: &str,
        expanded_steps_json: &str,
    ) -> Result<(), DbError> {
        sqlx::query(
            r#"
            UPDATE workflow_instances
            SET expanded_steps_json = ?1, updated_at = ?2
            WHERE id = ?3
            "#,
        )
        .bind(expanded_steps_json)
        .bind(Utc::now())
        .bind(workflow_id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn update_workflow_instance_params(
        &self,
        id: &str,
        params_json: &str,
    ) -> Result<(), DbError> {
        sqlx::query(
            r#"
            UPDATE workflow_instances
            SET params_json = ?1, updated_at = ?2
            WHERE id = ?3
            "#,
        )
        .bind(params_json)
        .bind(Utc::now())
        .bind(id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn update_workflow_instance_expanded(
        &self,
        id: &str,
        expanded_steps_json: &str,
    ) -> Result<(), DbError> {
        sqlx::query(
            r#"
            UPDATE workflow_instances
            SET expanded_steps_json = ?1, updated_at = ?2
            WHERE id = ?3
            "#,
        )
        .bind(expanded_steps_json)
        .bind(Utc::now())
        .bind(id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }
}
