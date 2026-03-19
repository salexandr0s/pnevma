use super::*;

impl Db {
    pub async fn upsert_session(&self, session: &SessionRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO sessions
            (id, project_id, name, type, backend, durability, lifecycle_state, status, pid, cwd, command, branch, worktree_id, connection_id, remote_session_id, controller_id, started_at, last_heartbeat, last_output_at, detached_at, last_error, restore_status, exit_code, ended_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24)
            ON CONFLICT(id) DO UPDATE SET
              backend=excluded.backend,
              durability=excluded.durability,
              lifecycle_state=excluded.lifecycle_state,
              status=excluded.status,
              pid=excluded.pid,
              cwd=excluded.cwd,
              command=excluded.command,
              branch=excluded.branch,
              worktree_id=excluded.worktree_id,
              connection_id=excluded.connection_id,
              remote_session_id=excluded.remote_session_id,
              controller_id=excluded.controller_id,
              last_heartbeat=excluded.last_heartbeat,
              last_output_at=excluded.last_output_at,
              detached_at=excluded.detached_at,
              last_error=excluded.last_error,
              restore_status=excluded.restore_status,
              exit_code=excluded.exit_code,
              ended_at=excluded.ended_at
            "#,
        )
        .bind(&session.id)
        .bind(&session.project_id)
        .bind(&session.name)
        .bind(&session.r#type)
        .bind(&session.backend)
        .bind(&session.durability)
        .bind(&session.lifecycle_state)
        .bind(&session.status)
        .bind(session.pid)
        .bind(&session.cwd)
        .bind(&session.command)
        .bind(&session.branch)
        .bind(&session.worktree_id)
        .bind(&session.connection_id)
        .bind(&session.remote_session_id)
        .bind(&session.controller_id)
        .bind(session.started_at)
        .bind(session.last_heartbeat)
        .bind(session.last_output_at)
        .bind(session.detached_at)
        .bind(&session.last_error)
        .bind(&session.restore_status)
        .bind(session.exit_code)
        .bind(&session.ended_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn list_sessions(&self, project_id: &str) -> Result<Vec<SessionRow>, DbError> {
        let rows = sqlx::query_as::<_, SessionRow>(
            r#"
            SELECT id, project_id, name, type, backend, durability, lifecycle_state, status, pid, cwd, command, branch, worktree_id, connection_id, remote_session_id, controller_id, started_at, last_heartbeat, last_output_at, detached_at, last_error, restore_status, exit_code, ended_at
            FROM sessions
            WHERE project_id = ?1
            ORDER BY started_at DESC
            "#,
        )
        .bind(project_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    pub async fn get_session(
        &self,
        project_id: &str,
        session_id: &str,
    ) -> Result<Option<SessionRow>, DbError> {
        let row = sqlx::query_as::<_, SessionRow>(
            r#"
            SELECT id, project_id, name, type, backend, durability, lifecycle_state, status, pid, cwd, command, branch, worktree_id, connection_id, remote_session_id, controller_id, started_at, last_heartbeat, last_output_at, detached_at, last_error, restore_status, exit_code, ended_at
            FROM sessions
            WHERE project_id = ?1 AND id = ?2
            LIMIT 1
            "#,
        )
        .bind(project_id)
        .bind(session_id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }

    pub async fn upsert_pane(&self, pane: &PaneRow) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO panes (id, project_id, session_id, type, position, label, metadata_json)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            ON CONFLICT(id) DO UPDATE SET
              project_id=excluded.project_id,
              session_id=excluded.session_id,
              type=excluded.type,
              position=excluded.position,
              label=excluded.label,
              metadata_json=excluded.metadata_json
            "#,
        )
        .bind(&pane.id)
        .bind(&pane.project_id)
        .bind(&pane.session_id)
        .bind(&pane.r#type)
        .bind(&pane.position)
        .bind(&pane.label)
        .bind(&pane.metadata_json)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn list_panes(&self, project_id: &str) -> Result<Vec<PaneRow>, DbError> {
        let rows = sqlx::query_as::<_, PaneRow>(
            r#"
            SELECT id, project_id, session_id, type, position, label, metadata_json
            FROM panes
            WHERE project_id = ?1
            ORDER BY
              CASE WHEN position = 'root' THEN 0 ELSE 1 END ASC,
              position ASC,
              id ASC
            "#,
        )
        .bind(project_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    pub async fn remove_pane(&self, pane_id: &str) -> Result<(), DbError> {
        sqlx::query("DELETE FROM panes WHERE id = ?1")
            .bind(pane_id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn upsert_pane_layout_template(
        &self,
        row: &PaneLayoutTemplateRow,
    ) -> Result<(), DbError> {
        sqlx::query(
            r#"
            INSERT INTO pane_layout_templates
            (id, project_id, name, display_name, pane_graph_json, is_system, created_at, updated_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
            ON CONFLICT(project_id, name) DO UPDATE SET
              display_name = excluded.display_name,
              pane_graph_json = excluded.pane_graph_json,
              is_system = excluded.is_system,
              updated_at = excluded.updated_at
            "#,
        )
        .bind(&row.id)
        .bind(&row.project_id)
        .bind(&row.name)
        .bind(&row.display_name)
        .bind(&row.pane_graph_json)
        .bind(row.is_system)
        .bind(row.created_at)
        .bind(row.updated_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn get_pane_layout_template(
        &self,
        project_id: &str,
        name: &str,
    ) -> Result<Option<PaneLayoutTemplateRow>, DbError> {
        let row = sqlx::query_as::<_, PaneLayoutTemplateRow>(
            r#"
            SELECT id, project_id, name, display_name, pane_graph_json, is_system, created_at, updated_at
            FROM pane_layout_templates
            WHERE project_id = ?1 AND name = ?2
            LIMIT 1
            "#,
        )
        .bind(project_id)
        .bind(name)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }

    pub async fn list_pane_layout_templates(
        &self,
        project_id: &str,
    ) -> Result<Vec<PaneLayoutTemplateRow>, DbError> {
        let rows = sqlx::query_as::<_, PaneLayoutTemplateRow>(
            r#"
            SELECT id, project_id, name, display_name, pane_graph_json, is_system, created_at, updated_at
            FROM pane_layout_templates
            WHERE project_id = ?1
            ORDER BY is_system DESC, name ASC
            "#,
        )
        .bind(project_id)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }
}
