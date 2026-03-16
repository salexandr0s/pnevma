use super::*;

impl Db {
    // ── Review files ──────────────────────────────────────────────────────────

    pub async fn create_review_file(&self, row: &ReviewFileRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO review_files (id, project_id, task_id, file_path, status, reviewer_notes, created_at, updated_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
            "#,
        )
        .bind(&row.id)
        .bind(&row.project_id)
        .bind(&row.task_id)
        .bind(&row.file_path)
        .bind(&row.status)
        .bind(&row.reviewer_notes)
        .bind(&row.created_at)
        .bind(&row.updated_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn list_review_files(&self, task_id: &str) -> Result<Vec<ReviewFileRow>, DbError> {
        Ok(sqlx::query_as::<_, ReviewFileRow>(
            "SELECT * FROM review_files WHERE task_id = ?1 ORDER BY file_path",
        )
        .bind(task_id)
        .fetch_all(&self.pool)
        .await?)
    }

    pub async fn update_review_file_status(
        &self,
        id: &str,
        status: &str,
        reviewer_notes: Option<&str>,
    ) -> Result<(), DbError> {
        sqlx::query(
            "UPDATE review_files SET status = ?1, reviewer_notes = ?2, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?3",
        )
        .bind(status)
        .bind(reviewer_notes)
        .bind(id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    // ── Review comments ─────────────────────────────────────────────────────

    pub async fn create_review_comment(&self, row: &ReviewCommentRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO review_comments (id, project_id, task_id, file_path, line_number, body, author, resolved, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
            "#,
        )
        .bind(&row.id)
        .bind(&row.project_id)
        .bind(&row.task_id)
        .bind(&row.file_path)
        .bind(row.line_number)
        .bind(&row.body)
        .bind(&row.author)
        .bind(row.resolved)
        .bind(&row.created_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn list_review_comments(
        &self,
        task_id: &str,
    ) -> Result<Vec<ReviewCommentRow>, DbError> {
        Ok(sqlx::query_as::<_, ReviewCommentRow>(
            "SELECT * FROM review_comments WHERE task_id = ?1 ORDER BY created_at",
        )
        .bind(task_id)
        .fetch_all(&self.pool)
        .await?)
    }

    pub async fn resolve_review_comment(&self, id: &str) -> Result<(), DbError> {
        sqlx::query("UPDATE review_comments SET resolved = 1 WHERE id = ?1")
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    // ── Review checklist ────────────────────────────────────────────────────

    pub async fn create_review_checklist_item(
        &self,
        row: &ReviewChecklistItemRow,
    ) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO review_checklist_items (id, project_id, task_id, label, checked, sort_order, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            "#,
        )
        .bind(&row.id)
        .bind(&row.project_id)
        .bind(&row.task_id)
        .bind(&row.label)
        .bind(row.checked)
        .bind(row.sort_order)
        .bind(&row.created_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn list_review_checklist(
        &self,
        task_id: &str,
    ) -> Result<Vec<ReviewChecklistItemRow>, DbError> {
        Ok(sqlx::query_as::<_, ReviewChecklistItemRow>(
            "SELECT * FROM review_checklist_items WHERE task_id = ?1 ORDER BY sort_order",
        )
        .bind(task_id)
        .fetch_all(&self.pool)
        .await?)
    }

    pub async fn toggle_review_checklist_item(
        &self,
        id: &str,
        checked: bool,
    ) -> Result<(), DbError> {
        sqlx::query("UPDATE review_checklist_items SET checked = ?1 WHERE id = ?2")
            .bind(checked)
            .bind(id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }
}
