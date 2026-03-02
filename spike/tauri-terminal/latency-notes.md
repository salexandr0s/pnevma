# Latency Notes

Date: March 1, 2026  
Environment: headless CI/dev shell (no desktop compositor)  
Display refresh rate: N/A

## Scenario 1: idle typing
- command: `./scripts/latency_proxy.sh` (pipe-based proxy benchmark)
- observed lag: `idle_p50=0.01ms`, `idle_p95=0.02ms`

## Scenario 2: heavy output + typing
- command: `./scripts/latency_proxy.sh` (64KB burst before marker)
- observed lag: `burst_p50=0.37ms`, `burst_p95=2.61ms`

## Scenario 4: re-run baseline (March 2, 2026)
- command: `./scripts/latency_proxy.sh`
- observed lag: `idle_p50=0.01ms`, `idle_p95=0.01ms`, `burst_p50=0.26ms`, `burst_p95=1.99ms`
- note: proxy benchmark remains comfortably below the 50ms perceived-latency threshold.

## Scenario 3: split panes with active task board
- command: pending manual desktop run
- observed lag: still not measurable in this environment

## Decision
- acceptable (<50ms perceived): proxy pass, manual perceived-latency check still pending
- follow-up actions:
  1. Run `cargo tauri dev` on a local desktop session.
  2. Capture perceived latency with split panes and active stream load.
  3. Update this file with measured values and gate result.
