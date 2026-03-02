# Design Partner Readiness Checklist

## Intake baseline

1. Verify telemetry opt-in defaults to `false`.
2. Verify in-app feedback submission works (`Settings -> Feedback`).
3. Verify partner metrics command returns data:
4. Verify keyboard quick actions execute:
   - `task.new`
   - `task.dispatch_next_ready`
   - `review.approve_next`
5. Verify recovery harness passes:

```bash
cargo run -p pnevma-app --bin pnevma -- ctl partner.metrics.report --params-json '{"days":14}'
./scripts/ipc-e2e-recovery.sh
```

## Weekly operating loop

1. Export metrics report (`partner.metrics.report`) for each active partner project.
2. Export feedback artifacts from `.pnevma/data/feedback/`.
3. Review counts:
   - `sessions_started`
   - `tasks_done`
   - `merges_completed`
   - `knowledge_captures`
   - `feedback_count`
4. Flag friction if any partner has:
   - low sessions + high feedback count
   - stalled onboarding (`onboarding_completed = false`)
   - no merges after multiple dispatches
   - heavy command-palette use but low quick-action use (keyboard flow discoverability gap)

## Triage taxonomy

- `ux`: interaction friction, discoverability, keyboard flow.
- `reliability`: restore failures, session errors, merge queue surprises.
- `performance`: latency, slow pane operations, slow search.
- `workflow`: missing commands, awkward sequencing.

## SLA targets

- Acknowledge feedback within 1 business day.
- Classify/triage within 2 business days.
- Provide fix plan or workaround within 5 business days.
