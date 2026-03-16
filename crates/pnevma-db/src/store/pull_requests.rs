use super::*;

impl Db {
    pub async fn create_pull_request(&self, row: &PullRequestRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO pull_requests
            (id, project_id, task_id, number, title, source_branch, target_branch, remote_url, status, checks_status, review_status, mergeable, head_sha, created_at, updated_at, merged_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)
            "#,
        )
        .bind(&row.id)
        .bind(&row.project_id)
        .bind(&row.task_id)
        .bind(row.number)
        .bind(&row.title)
        .bind(&row.source_branch)
        .bind(&row.target_branch)
        .bind(&row.remote_url)
        .bind(&row.status)
        .bind(&row.checks_status)
        .bind(&row.review_status)
        .bind(row.mergeable)
        .bind(&row.head_sha)
        .bind(&row.created_at)
        .bind(&row.updated_at)
        .bind(&row.merged_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn get_pull_request(&self, id: &str) -> Result<Option<PullRequestRow>, DbError> {
        Ok(
            sqlx::query_as::<_, PullRequestRow>("SELECT * FROM pull_requests WHERE id = ?1")
                .bind(id)
                .fetch_optional(&self.pool)
                .await?,
        )
    }

    pub async fn get_pull_request_by_task(
        &self,
        project_id: &str,
        task_id: &str,
    ) -> Result<Option<PullRequestRow>, DbError> {
        Ok(sqlx::query_as::<_, PullRequestRow>(
            "SELECT * FROM pull_requests WHERE project_id = ?1 AND task_id = ?2",
        )
        .bind(project_id)
        .bind(task_id)
        .fetch_optional(&self.pool)
        .await?)
    }

    pub async fn list_pull_requests(
        &self,
        project_id: &str,
    ) -> Result<Vec<PullRequestRow>, DbError> {
        Ok(sqlx::query_as::<_, PullRequestRow>(
            "SELECT * FROM pull_requests WHERE project_id = ?1 ORDER BY updated_at DESC",
        )
        .bind(project_id)
        .fetch_all(&self.pool)
        .await?)
    }

    pub async fn update_pull_request_status(
        &self,
        id: &str,
        status: &str,
        merged_at: Option<&str>,
    ) -> Result<(), DbError> {
        sqlx::query(
            "UPDATE pull_requests SET status = ?1, merged_at = ?2, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?3",
        )
        .bind(status)
        .bind(merged_at)
        .bind(id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn upsert_pr_check_run(&self, row: &PrCheckRunRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO pr_check_runs (id, pr_id, name, status, conclusion, details_url, started_at, completed_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
            ON CONFLICT(pr_id, name) DO UPDATE SET
                status = excluded.status,
                conclusion = excluded.conclusion,
                details_url = excluded.details_url,
                started_at = excluded.started_at,
                completed_at = excluded.completed_at
            "#,
        )
        .bind(&row.id)
        .bind(&row.pr_id)
        .bind(&row.name)
        .bind(&row.status)
        .bind(&row.conclusion)
        .bind(&row.details_url)
        .bind(&row.started_at)
        .bind(&row.completed_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn list_pr_check_runs(&self, pr_id: &str) -> Result<Vec<PrCheckRunRow>, DbError> {
        Ok(sqlx::query_as::<_, PrCheckRunRow>(
            "SELECT * FROM pr_check_runs WHERE pr_id = ?1 ORDER BY name",
        )
        .bind(pr_id)
        .fetch_all(&self.pool)
        .await?)
    }
}
