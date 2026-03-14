use super::*;

impl Db {
    pub async fn create_check_run(&self, row: &CheckRunRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO check_runs (id, project_id, task_id, status, summary, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            "#,
        )
        .bind(&row.id)
        .bind(&row.project_id)
        .bind(&row.task_id)
        .bind(&row.status)
        .bind(&row.summary)
        .bind(row.created_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn create_check_result(&self, row: &CheckResultRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO check_results
            (id, check_run_id, project_id, task_id, description, check_type, command, passed, output, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
            "#,
        )
        .bind(&row.id)
        .bind(&row.check_run_id)
        .bind(&row.project_id)
        .bind(&row.task_id)
        .bind(&row.description)
        .bind(&row.check_type)
        .bind(&row.command)
        .bind(row.passed)
        .bind(&row.output)
        .bind(row.created_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn latest_check_run_for_task(
        &self,
        task_id: &str,
    ) -> Result<Option<CheckRunRow>, DbError> {
        let row = sqlx::query_as::<_, CheckRunRow>(
            r#"
            SELECT id, project_id, task_id, status, summary, created_at
            FROM check_runs
            WHERE task_id = ?1
            ORDER BY created_at DESC
            LIMIT 1
            "#,
        )
        .bind(task_id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }

    pub async fn list_check_results_for_run(
        &self,
        check_run_id: &str,
    ) -> Result<Vec<CheckResultRow>, DbError> {
        let rows = sqlx::query_as::<_, CheckResultRow>(
            r#"
            SELECT id, check_run_id, project_id, task_id, description, check_type, command, passed, output, created_at
            FROM check_results
            WHERE check_run_id = ?1
            ORDER BY created_at ASC
            "#,
        )
        .bind(check_run_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    pub async fn upsert_review(&self, row: &ReviewRow) -> Result<(), DbError> {
        let mut tx = self.pool.begin().await?;
        let updated = sqlx::query(
            r#"
            UPDATE reviews
            SET id = ?1, status = ?2, review_pack_path = ?3,
                reviewer_notes = ?4, approved_at = ?5
            WHERE task_id = ?6
            "#,
        )
        .bind(&row.id)
        .bind(&row.status)
        .bind(&row.review_pack_path)
        .bind(&row.reviewer_notes)
        .bind(row.approved_at)
        .bind(&row.task_id)
        .execute(&mut *tx)
        .await?;

        if updated.rows_affected() == 0 {
            sqlx::query(
                r#"
                INSERT INTO reviews (id, task_id, status, review_pack_path, reviewer_notes, approved_at)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                "#,
            )
            .bind(&row.id)
            .bind(&row.task_id)
            .bind(&row.status)
            .bind(&row.review_pack_path)
            .bind(&row.reviewer_notes)
            .bind(row.approved_at)
            .execute(&mut *tx)
            .await?;
        }
        tx.commit().await?;

        Ok(())
    }

    pub async fn get_review_by_task(&self, task_id: &str) -> Result<Option<ReviewRow>, DbError> {
        let row = sqlx::query_as::<_, ReviewRow>(
            r#"
            SELECT id, task_id, status, review_pack_path, reviewer_notes, approved_at
            FROM reviews
            WHERE task_id = ?1
            LIMIT 1
            "#,
        )
        .bind(task_id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }

    pub async fn delete_review_by_task(&self, task_id: &str) -> Result<(), DbError> {
        sqlx::query("DELETE FROM reviews WHERE task_id = ?1")
            .bind(task_id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn upsert_merge_queue_item(&self, row: &MergeQueueRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO merge_queue
            (id, project_id, task_id, status, blocked_reason, approved_at, started_at, completed_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
            ON CONFLICT(task_id) DO UPDATE SET
              id = excluded.id,
              status = excluded.status,
              blocked_reason = excluded.blocked_reason,
              approved_at = excluded.approved_at,
              started_at = excluded.started_at,
              completed_at = excluded.completed_at
            "#,
        )
        .bind(&row.id)
        .bind(&row.project_id)
        .bind(&row.task_id)
        .bind(&row.status)
        .bind(&row.blocked_reason)
        .bind(row.approved_at)
        .bind(row.started_at)
        .bind(row.completed_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn get_merge_queue_item_by_task(
        &self,
        task_id: &str,
    ) -> Result<Option<MergeQueueRow>, DbError> {
        let row = sqlx::query_as::<_, MergeQueueRow>(
            r#"
            SELECT id, project_id, task_id, status, blocked_reason, approved_at, started_at, completed_at
            FROM merge_queue
            WHERE task_id = ?1
            LIMIT 1
            "#,
        )
        .bind(task_id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }

    pub async fn list_merge_queue(&self, project_id: &str) -> Result<Vec<MergeQueueRow>, DbError> {
        let rows = sqlx::query_as::<_, MergeQueueRow>(
            r#"
            SELECT id, project_id, task_id, status, blocked_reason, approved_at, started_at, completed_at
            FROM merge_queue
            WHERE project_id = ?1
            ORDER BY approved_at ASC
            "#,
        )
        .bind(project_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }
}
