# Desktop Latency Validation Protocol

This protocol closes the manual latency acceptance check for xterm split-pane interaction.

## Scope

- Scenario: active typing in terminal pane with at least one additional pane visible.
- Target: perceived input latency under 50ms.
- Platform: macOS desktop release build.

## Procedure

1. Build release app:

```bash
cargo tauri build --manifest-path crates/pnevma-app/Cargo.toml
```

2. Open a project and create at least two panes (`terminal` + one non-terminal pane).
3. In terminal pane, run:

```bash
for i in {1..200}; do printf "ping-%03d\n" "$i"; done
```

4. While output is active, type continuously for 30 seconds and record observed lag.
5. Capture one proxy benchmark run (for supporting evidence):

```bash
./scripts/latency_proxy.sh
```

6. Record machine profile, sample size, and observed latencies in:

- `spike/tauri-terminal/latency-notes.md`

## Acceptance

- PASS: no sustained lag perceived above 50ms while typing.
- FAIL: repeated perceived lag events above threshold.
