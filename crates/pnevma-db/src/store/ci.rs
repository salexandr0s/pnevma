use super::*;

impl Db {
    pub async fn create_ci_pipeline(&self, row: &CiPipelineRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO ci_pipelines
            (id, project_id, task_id, pr_id, provider, run_number, workflow_name, head_sha, status, conclusion, html_url, started_at, completed_at, created_at, updated_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)
            "#,
        )
        .bind(&row.id)
        .bind(&row.project_id)
        .bind(&row.task_id)
        .bind(&row.pr_id)
        .bind(&row.provider)
        .bind(row.run_number)
        .bind(&row.workflow_name)
        .bind(&row.head_sha)
        .bind(&row.status)
        .bind(&row.conclusion)
        .bind(&row.html_url)
        .bind(&row.started_at)
        .bind(&row.completed_at)
        .bind(&row.created_at)
        .bind(&row.updated_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn get_ci_pipeline(&self, id: &str) -> Result<Option<CiPipelineRow>, DbError> {
        Ok(
            sqlx::query_as::<_, CiPipelineRow>("SELECT * FROM ci_pipelines WHERE id = ?1")
                .bind(id)
                .fetch_optional(&self.pool)
                .await?,
        )
    }

    pub async fn list_ci_pipelines(&self, project_id: &str) -> Result<Vec<CiPipelineRow>, DbError> {
        Ok(sqlx::query_as::<_, CiPipelineRow>(
            "SELECT * FROM ci_pipelines WHERE project_id = ?1 ORDER BY created_at DESC",
        )
        .bind(project_id)
        .fetch_all(&self.pool)
        .await?)
    }

    pub async fn update_ci_pipeline_status(
        &self,
        id: &str,
        status: &str,
        conclusion: Option<&str>,
    ) -> Result<(), DbError> {
        sqlx::query(
            "UPDATE ci_pipelines SET status = ?1, conclusion = ?2, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?3",
        )
        .bind(status)
        .bind(conclusion)
        .bind(id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn create_ci_job(&self, row: &CiJobRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO ci_jobs (id, pipeline_id, name, status, conclusion, started_at, completed_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            "#,
        )
        .bind(&row.id)
        .bind(&row.pipeline_id)
        .bind(&row.name)
        .bind(&row.status)
        .bind(&row.conclusion)
        .bind(&row.started_at)
        .bind(&row.completed_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn list_ci_jobs(&self, pipeline_id: &str) -> Result<Vec<CiJobRow>, DbError> {
        Ok(sqlx::query_as::<_, CiJobRow>(
            "SELECT * FROM ci_jobs WHERE pipeline_id = ?1 ORDER BY name",
        )
        .bind(pipeline_id)
        .fetch_all(&self.pool)
        .await?)
    }

    pub async fn create_deployment(&self, row: &DeploymentRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO deployments
            (id, project_id, task_id, environment, status, ref_name, sha, url, created_at, updated_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
            "#,
        )
        .bind(&row.id)
        .bind(&row.project_id)
        .bind(&row.task_id)
        .bind(&row.environment)
        .bind(&row.status)
        .bind(&row.ref_name)
        .bind(&row.sha)
        .bind(&row.url)
        .bind(&row.created_at)
        .bind(&row.updated_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn list_deployments(&self, project_id: &str) -> Result<Vec<DeploymentRow>, DbError> {
        Ok(sqlx::query_as::<_, DeploymentRow>(
            "SELECT * FROM deployments WHERE project_id = ?1 ORDER BY created_at DESC",
        )
        .bind(project_id)
        .fetch_all(&self.pool)
        .await?)
    }
}
