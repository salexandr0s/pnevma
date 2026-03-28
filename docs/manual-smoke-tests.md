# Pnevma v0.2.0 Manual Smoke Tests

Run these checks in order against the `0.2.0` DMG. Stop at the first failure and record:

- step number,
- what you expected,
- what actually happened,
- any SQL output or screenshots that help reproduce it.

This document complements:

- `scripts/run-packaged-launch-smoke.sh` for packaged app launch smoke,
- `docs/manual-remote-ssh-tests.md` for real-host remote helper validation on Linux and remote macOS hosts,
- `docs/manual-remote-durable-lifecycle-tests.md` for packaged remote durable session lifecycle validation and clean-machine relaunch evidence,
- `docs/manual-security-tests.md` for remote/security validation,
- `docs/macos-release.md` for signing, DMG packaging, first-launch instructions, and release evidence.

## Prerequisites

- A macOS machine that can mount the release DMG.
- `sqlite3`, `git`, and at least one supported agent CLI on `PATH` (`claude-code` or `codex`) for dispatch checks.
- A throwaway local git repository.
- Enough time to let at least one dispatched task finish.

Use a test repo path with no single quotes in it so the shell snippets below work unchanged.

## Test fixture setup

Set up the fixture repo and helper variables first:

```bash
export DMG_PATH="$PWD/Pnevma-0.2.0-macos-arm64.dmg"
export EVIDENCE_DIR="${EVIDENCE_DIR:-$PWD/release-evidence}"
export APP_COPY="/Applications/Pnevma.app"
export TEST_REPO="$HOME/tmp/pnevma-smoke-repo"
export GLOBAL_DB="$HOME/.local/share/pnevma/global.db"
export PROJECT_DB="$TEST_REPO/.pnevma/pnevma.db"
export TASK_TITLE="Smoke Task Alpha"
export TASK_TITLE_2="Smoke Task Beta"
export TASK_TITLE_3="Smoke Task Gamma"
export TASK_TITLE_4="Smoke Task Delta"
export WORKFLOW_NAME="Smoke Workflow Alpha"

rm -rf "$TEST_REPO"
mkdir -p "$TEST_REPO"
cd "$TEST_REPO"
git init -b main
git config user.name "Pnevma Smoke"
git config user.email "smoke@example.com"
cat > README.md <<'EOF'
# Pnevma Smoke Fixture

Baseline fixture for the v0.2.0 manual smoke run.
EOF
cat > NOTES.md <<'EOF'
# Smoke Notes

No notes yet.
EOF
git add README.md NOTES.md
git commit -m "Initial smoke fixture"
```

Useful DB helpers:

```bash
sql_global() { sqlite3 -header -box "$GLOBAL_DB" "$1"; }
sql_project() { sqlite3 -header -box "$PROJECT_DB" "$1"; }
```

When you finish the run, record the result in:

- `$EVIDENCE_DIR/manual/manual-smoke-results.md`
- `$EVIDENCE_DIR/manual/clean-machine-install-notes.md`

## 1. Launch and first run

1. Mount the DMG and drag `Pnevma.app` to `/Applications`.
2. Launch Pnevma from `/Applications`.
3. If macOS blocks the build, use **right-click → Open** in Finder and record that it was required.
4. If Finder `Open` is still not enough, use **System Settings → Privacy & Security → Open Anyway** and record that it was required.
5. Confirm the app does not crash and the main window appears.
6. Open **Pnevma → About Pnevma** and confirm the version shown is `0.2.0`.

**Pass:** app launches through the documented first-run flow, main window renders, and About shows `0.2.0`.

**Fail:** launch only works through undocumented steps, the app crashes, the window is blank, or the version is wrong.

## 2. Project setup and persistence

1. In Pnevma, open the local workspace at `$TEST_REPO`.
2. If prompted, initialize `pnevma.toml` and the `.pnevma/` scaffold.
3. Confirm the project opens and appears in the sidebar/workspace UI.
4. Confirm these files now exist:

   ```bash
   test -f "$TEST_REPO/pnevma.toml"
   test -d "$TEST_REPO/.pnevma"
   test -f "$PROJECT_DB"
   ```

5. Quit and relaunch Pnevma.
6. Confirm the project still appears as a recent/openable workspace and can be reopened without re-initializing.

**DB checks:**

```bash
sql_global "SELECT path, name, project_id, opened_at FROM recent_projects WHERE path = '$TEST_REPO';"
sql_project "SELECT id, name, path, config_path, created_at FROM projects WHERE path = '$TEST_REPO';"
```

**Pass:** scaffold created once, project reopens after relaunch, recent-project row exists, per-project DB has the project row.

**Fail:** scaffold not created, reopen loses the project, or either DB query returns no matching row.

## 3. Terminal and session lifecycle

1. Confirm a terminal pane opens for the project.
2. In the terminal, run:

   ```bash
   pwd
   printf 'line-%03d\n' {1..200}
   ```

3. Confirm input works, output renders correctly, and scrollback is usable.
4. Open a second terminal with **File → New Terminal** or `Cmd+N`.
5. Open the **Sessions** manager and confirm both sessions appear.
6. Kill one session from the session manager and confirm its status changes away from `running`.

**DB checks:**

```bash
sql_project "SELECT id, name, status, pid, cwd, command, started_at FROM sessions ORDER BY started_at DESC LIMIT 5;"
```

**Pass:** at least two sessions can exist, one can be killed cleanly, and session rows reflect the change.

**Fail:** no working shell, broken rendering, missing second session, or killed session remains stuck as `running`.

## 4. Task create and persistence

1. Open **Task Board**.
2. Create a task with:
   - **Title:** `$TASK_TITLE`
   - **Goal:** `Append a smoke-test line to README.md and summarize the change`
   - **Priority:** `P1`
   - **Scope:** `README.md`
   - **Acceptance criteria:** `README.md contains a smoke-test marker`
3. Confirm the task appears in **Planned**.
4. Open the task card menu and move it to **Ready**.
5. Quit and relaunch Pnevma, reopen the project, and confirm the task still exists with the same title, goal, priority, and `Ready` status.

Extract the task ID for later checks:

```bash
export TASK_ID="$(sqlite3 "$PROJECT_DB" "SELECT id FROM tasks WHERE title = '$TASK_TITLE' ORDER BY created_at DESC LIMIT 1;")"
printf 'TASK_ID=%s\n' "$TASK_ID"
```

**DB checks:**

```bash
sql_project "SELECT id, title, goal, priority, status, branch, worktree_id, created_at, updated_at FROM tasks WHERE id = '$TASK_ID';"
```

**Pass:** task survives relaunch, status is `Ready`, and the stored title/goal/priority match the UI.

**Fail:** task disappears, task fields drift, or task cannot reach `Ready`.

## 5. Agent dispatch, live output, and cost tracking

1. Confirm an adapter exists:

   ```bash
   command -v claude-code || command -v codex
   ```

2. Dispatch `$TASK_TITLE` from its task card.
3. Confirm:
   - a dedicated agent terminal/session appears,
   - the task leaves `Ready` and enters active execution,
   - live output streams into the terminal pane,
   - cost data begins appearing in the UI once provider output is flowing.

**DB checks while or after the run is active:**

```bash
sql_project "SELECT id, title, status, branch, worktree_id, updated_at FROM tasks WHERE id = '$TASK_ID';"
sql_project "SELECT id, task_id, run_id, origin, provider, model, status, attempt, started_at, finished_at, tokens_in, tokens_out, cost_usd FROM automation_runs WHERE task_id = '$TASK_ID' ORDER BY created_at DESC LIMIT 3;"
sql_project "SELECT id, task_id, session_id, provider, model, tokens_in, tokens_out, estimated_usd, tracked, timestamp FROM costs WHERE task_id = '$TASK_ID' ORDER BY timestamp DESC LIMIT 5;"
```

**Pass:** task becomes active (`InProgress` during execution), automation run rows appear, and at least one cost row is recorded once the adapter emits usage.

**Fail:** dispatch does nothing, no live session appears, task stays `Ready`, or no automation row is created.

## 6. Git worktree, branch, diff, checks, and review pack

Wait for the dispatched task to finish.

1. Confirm the task reaches `Review`.
2. Confirm a task branch and worktree were created during execution.
3. In the repo, inspect the git state:

   ```bash
   git -C "$TEST_REPO" worktree list
   git -C "$TEST_REPO" branch --all
   ```

4. In Pnevma, open the right inspector and confirm the generated diff is visible.
5. Confirm automated checks ran and a review pack is available.

**DB checks:**

```bash
sql_project "SELECT id, task_id, path, branch, lease_status, lease_started, last_active FROM worktrees WHERE task_id = '$TASK_ID';"
sql_project "SELECT id, status, summary, created_at FROM check_runs WHERE task_id = '$TASK_ID' ORDER BY created_at DESC LIMIT 3;"
sql_project "SELECT id, check_run_id, description, check_type, passed, created_at FROM check_results WHERE task_id = '$TASK_ID' ORDER BY created_at DESC LIMIT 10;"
sql_project "SELECT id, task_id, status, review_pack_path, approved_at FROM reviews WHERE task_id = '$TASK_ID';"
```

**Pass:** a unique worktree/branch exists for the task, checks populate `check_runs` and `check_results`, and a review-pack row exists for the task.

**Fail:** the task skips review unexpectedly, no task-specific worktree exists, no diff is visible, or check/review rows are missing.

## 7. Merge queue and merge completion

1. Open the review UI and approve the task.
2. Open the merge queue UI and confirm the task is queued.
3. Run the merge from the queue.
4. Confirm:
   - the task branch lands on `main`,
   - the task worktree is cleaned up,
   - the task reaches `Done`.

**DB checks:**

```bash
sql_project "SELECT id, task_id, status, blocked_reason, approved_at, started_at, completed_at FROM merge_queue WHERE task_id = '$TASK_ID';"
sql_project "SELECT id, title, status, branch, worktree_id, updated_at FROM tasks WHERE id = '$TASK_ID';"
sql_project "SELECT id, task_id, path, branch, lease_status FROM worktrees WHERE task_id = '$TASK_ID';"
git -C "$TEST_REPO" log --oneline --decorate -n 5
git -C "$TEST_REPO" worktree list
```

**Pass:** merge queue row moves through `Queued` → `Running` → `Merged`, the task ends `Done`, and the task worktree is removed.

**Fail:** queue item never starts, merge leaves the branch unmerged, or worktree cleanup does not happen.

## 8. Workflow creation and workflow persistence

1. Open the **Workflow** pane.
2. Switch to **Workflows** and set **Scope** to **Project**.
3. Create a workflow named `$WORKFLOW_NAME` with two steps:
   - **Step 1**
     - title: `Workflow Step 1`
     - goal: `Append workflow-step-1 to README.md`
     - scope: `README.md`
     - acceptance criterion: `README.md contains workflow-step-1`
   - **Step 2**
     - title: `Workflow Step 2`
     - goal: `Append workflow-step-2 to NOTES.md after step 1`
     - depends on step 1
     - scope: `NOTES.md`
     - acceptance criterion: `NOTES.md contains workflow-step-2`
4. Save and run the workflow.
5. Confirm a workflow instance appears under **Active** and that step/task status is visible per stage.

**DB checks:**

```bash
sql_project "SELECT id, workflow_name, status, created_at, updated_at FROM workflow_instances WHERE workflow_name = '$WORKFLOW_NAME' ORDER BY created_at DESC LIMIT 3;"
sql_project "SELECT workflow_id, step_index, iteration, task_id FROM workflow_tasks WHERE workflow_id IN (SELECT id FROM workflow_instances WHERE workflow_name = '$WORKFLOW_NAME') ORDER BY workflow_id, step_index, iteration;"
```

If agent dispatch is configured and the steps auto-run, also confirm the first step advances before the dependent step does.

**Pass:** workflow instance row exists, step/task rows exist, and dependency ordering is preserved.

**Fail:** workflow cannot be saved/run, no instance row appears, or step linkage is missing.

## 9. Notifications and event log

1. Trigger at least one state transition that should notify the operator:
   - task enters review,
   - merge completes,
   - or a task fails.
2. Open **Notifications** and confirm entries appear.
3. Inspect the event log / daily brief surfaces and confirm task and merge transitions are represented.

**DB checks:**

```bash
sql_project "SELECT id, title, level, unread, created_at FROM notifications ORDER BY created_at DESC LIMIT 10;"
sql_project "SELECT id, task_id, session_id, source, event_type, timestamp FROM events ORDER BY timestamp DESC LIMIT 20;"
```

**Pass:** notifications exist for recent lifecycle events and the events table shows the matching transitions.

**Fail:** user-visible notifications are missing or the event log is unexpectedly sparse.

## 10. Edge cases

### 10.1 Kill an agent mid-run

1. Create a second task titled `$TASK_TITLE_2` with the same shape as the first task, but target `NOTES.md` instead of `README.md`.
2. Move it to **Ready** and dispatch it.
3. While it is still running, kill its agent session from the session manager.
4. Confirm the task transitions to a terminal state instead of staying stuck.

**DB checks:**

```bash
export TASK_ID_2="$(sqlite3 "$PROJECT_DB" "SELECT id FROM tasks WHERE title = '$TASK_TITLE_2' ORDER BY created_at DESC LIMIT 1;")"
sql_project "SELECT id, title, status, updated_at FROM tasks WHERE id = '$TASK_ID_2';"
sql_project "SELECT id, task_id, status, finished_at, error_message FROM automation_runs WHERE task_id = '$TASK_ID_2' ORDER BY created_at DESC LIMIT 3;"
```

**Pass:** task becomes `Failed` or another terminal state and the automation run records completion/error details.

**Fail:** task remains stuck in `InProgress` with no recoverable path.

### 10.2 Two active tasks on one repo use separate worktrees

1. Create two fresh tasks titled `$TASK_TITLE_3` and `$TASK_TITLE_4`, each with a real scope file and acceptance criterion (for example, one scoped to `README.md` and one scoped to `NOTES.md`).
2. Move both fresh tasks to **Ready**.
3. Dispatch both before merging either one.
4. Confirm they receive different branches/worktrees.

**DB checks:**

```bash
export TASK_ID_3="$(sqlite3 "$PROJECT_DB" "SELECT id FROM tasks WHERE title = '$TASK_TITLE_3' ORDER BY created_at DESC LIMIT 1;")"
export TASK_ID_4="$(sqlite3 "$PROJECT_DB" "SELECT id FROM tasks WHERE title = '$TASK_TITLE_4' ORDER BY created_at DESC LIMIT 1;")"
sql_project "SELECT task_id, branch, path, lease_status FROM worktrees WHERE task_id IN ('$TASK_ID_3', '$TASK_ID_4') ORDER BY task_id;"
```

**Pass:** each task has its own branch/worktree path.

**Fail:** worktree paths or branches collide.

### 10.3 Offline and rapid reopen resilience

1. Disconnect the network.
2. Reopen the app, switch panes, and inspect existing local state.
3. Reconnect the network.
4. Rapidly close and reopen the workspace several times.
5. Confirm the app stays responsive and local data is intact.

**DB checks:**

```bash
sql_project "PRAGMA integrity_check;"
sql_project "SELECT id, name, status FROM sessions ORDER BY started_at DESC LIMIT 10;"
```

**Pass:** no crash, SQLite integrity remains `ok`, and no obvious orphan-session explosion appears.

**Fail:** crash, corruption, or repeated orphan sessions accumulate.

## 11. Cleanup

1. Confirm the repo is back on `main`.
2. Confirm no task worktrees remain unless a failure intentionally left one behind for debugging:

   ```bash
   git -C "$TEST_REPO" worktree list
   ```

3. Quit Pnevma.
4. Confirm no zombie app process remains:

   ```bash
   ps aux | grep '[P]nevma'
   ```

5. Remove the throwaway repo:

   ```bash
   rm -rf "$TEST_REPO"
   ```

**Pass:** app exits cleanly, no unexpected worktrees remain, and the test repo can be deleted without cleanup surprises.

**Fail:** zombie processes remain, worktrees linger unexpectedly, or the repo cannot be removed cleanly.
