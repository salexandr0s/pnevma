# pnevma-sim — Agent Simulation & Orchestration Testing

**Status:** Draft
**Author:** SavorgBot (design), Alexandros (implementation)
**Date:** 2026-03-05

---

## Problem

Pnevma orchestrates real coding agents (Claude Code, Codex) against real repos.
Testing orchestration logic today means burning API credits and waiting for LLM
round trips. There's no way to:

- Verify dispatch ordering, concurrency limits, and failure policies without live agents
- Regression-test orchestration changes across scenarios
- Reproduce specific failure modes (agent crash, timeout, partial output)
- Run CI checks on the orchestration layer itself

## Solution

A simulation layer that replaces real agents with scripted behaviors, running
full orchestration flows in seconds with deterministic, reproducible outcomes.

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                  pnevma-sim (new crate)              │
│                                                      │
│  ┌──────────┐  ┌──────────────┐  ┌───────────────┐  │
│  │ Scenario │  │  Simulated   │  │   Assertion    │  │
│  │  Loader  │──│   Adapter    │──│    Engine      │  │
│  └──────────┘  └──────────────┘  └───────────────┘  │
│       │              │                    │           │
│       │         implements               │           │
│       ▼         AgentAdapter             ▼           │
│  scenarios/          │           SimReport (pass/    │
│  *.toml              │           fail + event log)   │
└──────────────────────┼───────────────────────────────┘
                       │
          ┌────────────┼────────────┐
          │   Existing pnevma stack │
          │                         │
          │  AdapterRegistry        │
          │  DispatchPool           │
          │  WorkflowInstance       │
          │  EventStore             │
          │  TaskContract           │
          └─────────────────────────┘
```

The simulated adapter plugs into `AdapterRegistry` exactly like `ClaudeCodeAdapter`
and `CodexAdapter`. No changes to core orchestration code.

---

## Crate: `pnevma-sim`

### Dependencies

```toml
[dependencies]
pnevma-core = { path = "../pnevma-core" }
pnevma-agents = { path = "../pnevma-agents" }
pnevma-git = { path = "../pnevma-git" }
async-trait = "0.1"
tokio = { version = "1", features = ["full"] }
serde = { version = "1", features = ["derive"] }
toml = "0.8"
chrono = { version = "0.4", features = ["serde"] }
uuid = { version = "1", features = ["v4", "serde"] }
tracing = "0.1"
```

---

## Component 1: Simulated Adapter

File: `src/adapter.rs`

```rust
pub struct SimulatedAdapter {
    scripts: Arc<RwLock<HashMap<String, AgentScript>>>,
    channels: Arc<RwLock<HashMap<Uuid, broadcast::Sender<AgentEvent>>>>,
}
```

### AgentScript

A script defines the sequence of events an agent will emit:

```rust
pub struct AgentScript {
    pub name: String,
    pub steps: Vec<ScriptStep>,
    pub final_status: ScriptOutcome,
}

pub struct ScriptStep {
    pub delay: Duration,
    pub event: ScriptEvent,
}

pub enum ScriptEvent {
    Output(String),
    ToolUse { name: String, input: String, output: String },
    Error(String),
    Usage { tokens_in: u64, tokens_out: u64, cost_usd: f64 },
}

pub enum ScriptOutcome {
    Complete { summary: String },
    Fail { error: String },
    Hang,       // never completes — tests timeout handling
    Crash,      // drops mid-stream — tests cleanup
    Panic,      // emits error then exits — tests error recovery
}
```

### AgentAdapter impl

```rust
#[async_trait]
impl AgentAdapter for SimulatedAdapter {
    async fn spawn(&self, config: AgentConfig) -> Result<AgentHandle, AgentError> {
        // Create channel, return handle — same as real adapters
    }

    async fn send(&self, handle: &AgentHandle, input: TaskPayload) -> Result<(), AgentError> {
        // Match input.objective to a script name (or use a default script)
        // Spawn tokio task that walks script steps with delays
        // Emit AgentEvents through the broadcast channel
    }

    async fn subscribe(&self, handle: &AgentHandle) -> Result<broadcast::Receiver<AgentEvent>, AgentError> {
        // Return receiver from channel map
    }

    async fn kill(&self, handle: &AgentHandle) -> Result<(), AgentError> {
        // Drop channel, mark complete
    }
}
```

The adapter matches scripts to tasks by name or pattern. If a task has no
matching script, use a default "happy path" script that completes in 100ms.

---

## Component 2: Scenario Format

File: `scenarios/*.toml`

```toml
[scenario]
name = "concurrent-dispatch-with-failure"
description = "4 tasks, 2 slots, task 3 fails and triggers retry"
max_concurrent = 2

[[tasks]]
title = "Setup database schema"
goal = "Create initial migration"
priority = "P0"
script = "fast-success"

[[tasks]]
title = "Implement user model"
goal = "CRUD for users"
priority = "P1"
depends_on = [0]
script = "medium-success"

[[tasks]]
title = "Add auth middleware"
goal = "JWT auth"
priority = "P1"
depends_on = [0]
script = "fail-then-retry"
on_failure = "retry_once"

[[tasks]]
title = "Write integration tests"
goal = "Test all endpoints"
priority = "P2"
depends_on = [1, 2]
script = "slow-success"

# Script definitions (inline or reference external files)

[scripts.fast-success]
final_status = "complete"
summary = "Schema created successfully"

[[scripts.fast-success.steps]]
delay_ms = 50
event = { type = "output", text = "Creating migration file..." }

[[scripts.fast-success.steps]]
delay_ms = 100
event = { type = "tool_use", name = "write_file", input = "migrations/001.sql", output = "ok" }

[[scripts.fast-success.steps]]
delay_ms = 50
event = { type = "usage", tokens_in = 1200, tokens_out = 800, cost_usd = 0.003 }

[scripts.medium-success]
final_status = "complete"
summary = "User model implemented"

[[scripts.medium-success.steps]]
delay_ms = 200
event = { type = "output", text = "Analyzing schema..." }

[[scripts.medium-success.steps]]
delay_ms = 300
event = { type = "tool_use", name = "write_file", input = "src/models/user.rs", output = "ok" }

[scripts.fail-then-retry]
final_status = "fail"
error = "compilation error in auth.rs"

[[scripts.fail-then-retry.steps]]
delay_ms = 100
event = { type = "output", text = "Generating JWT middleware..." }

[[scripts.fail-then-retry.steps]]
delay_ms = 200
event = { type = "error", text = "cannot find crate jsonwebtoken" }

# On retry, the orchestrator re-dispatches — a second script handles the retry:
[scripts.fail-then-retry.retry]
final_status = "complete"
summary = "Auth middleware working after adding dependency"

[[scripts.fail-then-retry.retry.steps]]
delay_ms = 150
event = { type = "tool_use", name = "edit_file", input = "Cargo.toml", output = "ok" }

[scripts.slow-success]
final_status = "complete"
summary = "Integration tests passing"

[[scripts.slow-success.steps]]
delay_ms = 500
event = { type = "output", text = "Writing test suite..." }

[[scripts.slow-success.steps]]
delay_ms = 1000
event = { type = "tool_use", name = "write_file", input = "tests/integration.rs", output = "ok" }
```

### Assertions Block

```toml
[[assertions]]
type = "dispatch_order"
expected = ["Setup database schema", "Implement user model", "Add auth middleware", "Write integration tests"]

[[assertions]]
type = "max_concurrent_active"
max = 2

[[assertions]]
type = "task_retried"
task = "Add auth middleware"
times = 1

[[assertions]]
type = "all_completed"

[[assertions]]
type = "total_cost_below"
max_usd = 0.02

[[assertions]]
type = "event_sequence"
events = [
    "TaskDispatched:Setup database schema",
    "TaskCompleted:Setup database schema",
    "TaskDispatched:Implement user model",
    "TaskDispatched:Add auth middleware",
    "TaskFailed:Add auth middleware",
    "TaskDispatched:Add auth middleware",  # retry
    "TaskCompleted:Implement user model",
    "TaskCompleted:Add auth middleware",
    "TaskDispatched:Write integration tests",
    "TaskCompleted:Write integration tests",
]
```

---

## Component 3: Scenario Runner

File: `src/runner.rs`

```rust
pub struct SimRunner {
    event_store: InMemoryEventStore,
    pool: DispatchPool,
    adapter: SimulatedAdapter,
    registry: AdapterRegistry,
}

impl SimRunner {
    pub async fn run(scenario: Scenario) -> SimReport {
        // 1. Build in-memory event store
        // 2. Register SimulatedAdapter with scripts from scenario
        // 3. Create TaskContracts from scenario tasks
        // 4. Create WorkflowDef from task list + dependencies
        // 5. Instantiate WorkflowInstance
        // 6. Run the orchestration loop (real code, simulated agents)
        // 7. Collect all events from the store
        // 8. Evaluate assertions against collected events
        // 9. Return SimReport
    }
}
```

### SimReport

```rust
pub struct SimReport {
    pub scenario_name: String,
    pub passed: bool,
    pub assertions: Vec<AssertionResult>,
    pub events: Vec<EventRecord>,
    pub timeline: Vec<TimelineEntry>,
    pub total_sim_time: Duration,
    pub total_simulated_cost: f64,
}

pub struct AssertionResult {
    pub assertion_type: String,
    pub passed: bool,
    pub message: String,
}

pub struct TimelineEntry {
    pub offset: Duration,
    pub event_type: EventType,
    pub task_title: Option<String>,
    pub detail: String,
}
```

---

## Component 4: Chaos Mode

Optional fault injection, configured per-scenario:

```toml
[chaos]
enabled = true
seed = 42  # deterministic randomness

# Probabilities (0.0 - 1.0)
random_delay_factor = 0.5      # multiply step delays by 0.5x - 2.0x
crash_probability = 0.05       # 5% chance any step crashes the agent
timeout_probability = 0.02     # 2% chance agent hangs forever
partial_output = 0.1           # 10% chance output gets truncated
```

Implementation: wrap `ScriptStep` execution in a chaos layer that rolls dice
before each step. The seed makes failures reproducible.

---

## Component 5: CLI Interface

```
pnevma sim run scenarios/concurrent-dispatch.toml
pnevma sim run scenarios/ --all
pnevma sim run scenarios/concurrent-dispatch.toml --chaos --seed 42
pnevma sim list                              # list available scenarios
pnevma sim report <run-id> --format json     # export last run
pnevma sim replay <run-id>                   # replay timeline to stdout
```

Add as a subcommand in `pnevma-commands`:

```rust
#[derive(Subcommand)]
enum SimCommands {
    Run {
        #[arg(value_name = "SCENARIO")]
        path: PathBuf,
        #[arg(long)]
        all: bool,
        #[arg(long)]
        chaos: bool,
        #[arg(long)]
        seed: Option<u64>,
    },
    List,
    Report {
        run_id: String,
        #[arg(long, default_value = "text")]
        format: String,
    },
    Replay {
        run_id: String,
    },
}
```

---

## Component 6: Git Simulation (optional, phase 2)

For testing worktree isolation and merge flows without touching real repos:

```rust
pub struct SimGitBackend {
    // In-memory representation of branches, worktrees, and files
    worktrees: HashMap<String, SimWorktree>,
    branches: HashMap<String, Vec<SimCommit>>,
}
```

Implements the same trait interface as the real git backend. Allows testing:

- Worktree creation/cleanup
- Branch conflicts between concurrent agents
- Merge queue serialization
- Conflict detection and resolution flows

---

## Integration Points

### 1. AdapterRegistry

No changes needed. Register `SimulatedAdapter` alongside real adapters:

```rust
registry.register("simulated", Box::new(SimulatedAdapter::new(scripts)));
```

Tasks in simulation mode use `provider: "simulated"` in their config.

### 2. EventStore

Use `InMemoryEventStore` (already exists). Assertions query it after the run.

### 3. WorkflowDef

Scenarios compile directly to `WorkflowDef` — the steps, dependencies, and
failure policies are 1:1.

### 4. DispatchPool

Real pool with real concurrency limits. The simulation just swaps the agent
behind it.

---

## Testing Strategy

### Unit tests (in pnevma-sim)

- Script parsing and validation
- Assertion evaluation against mock event lists
- Chaos layer determinism (same seed = same failures)

### Integration tests (in pnevma-sim)

- Full scenario runs against real orchestration code
- Verify event sequences, concurrency, retry behavior

### CI scenarios (in scenarios/)

Ship a standard set:

| Scenario                   | Tests                                                    |
| -------------------------- | -------------------------------------------------------- |
| `single-task-success.toml` | Happy path, one task completes                           |
| `single-task-failure.toml` | Task fails, proper status transition                     |
| `concurrent-dispatch.toml` | N tasks, M slots, correct queuing                        |
| `dependency-chain.toml`    | Linear A→B→C, correct ordering                           |
| `diamond-dependency.toml`  | A→(B,C)→D, parallel B/C                                  |
| `retry-on-failure.toml`    | Fail once, retry succeeds                                |
| `retry-exhausted.toml`     | Fail twice, workflow fails                               |
| `timeout-handling.toml`    | Agent hangs, timeout triggers                            |
| `crash-recovery.toml`      | Agent crashes, cleanup runs                              |
| `priority-preemption.toml` | P0 arrives while P2 is queued                            |
| `max-concurrency.toml`     | Verify N+1th agent queues                                |
| `chaos-resilience.toml`    | Random faults, workflow still completes or fails cleanly |

---

## Phasing

### Phase 1: Core sim (est. 3-4 days)

- `SimulatedAdapter` implementing `AgentAdapter`
- TOML scenario loader
- `SimRunner` wiring to real orchestration
- Basic assertions (dispatch order, all completed, task retried)
- CLI: `pnevma sim run`

### Phase 2: Rich assertions + reporting (est. 2-3 days)

- Event sequence assertions
- Concurrency assertions (max active at any point)
- Cost/token budget assertions
- Timeline report output (text + JSON)
- CLI: `pnevma sim report`, `pnevma sim replay`

### Phase 3: Chaos mode (est. 2 days)

- Fault injection layer with seeded RNG
- Crash, timeout, partial output, random delay
- Chaos-specific assertions (e.g. "workflow completes despite 10% crash rate")

### Phase 4: Git simulation (est. 3-4 days)

- `SimGitBackend` with in-memory worktrees/branches
- Merge conflict scenarios
- Merge queue ordering tests

### Phase 5: UI integration (est. 2-3 days)

- Replay simulated runs in the Tauri UI timeline view
- Side-by-side comparison of expected vs actual event sequences
- Visual diff of assertion results

---

## Open Questions

1. **Script matching strategy** — Match by task title exact/glob, or require
   explicit `script = "name"` on every task? Leaning toward explicit for
   clarity, with a `[default_script]` fallback.

2. **Time scaling** — Should simulated delays run in real-time or compressed?
   Suggest a `time_scale` factor (default 1.0, set to 0.01 for CI).

3. **Worktree stubs** — Phase 1 can skip real/simulated git entirely and just
   use temp directories. Real git simulation only matters for merge flow testing.

4. **Snapshot testing** — Should `SimReport` support snapshot-style comparison
   (save expected output, diff against future runs)? Useful for regression but
   adds maintenance.

---

## Bonus: sqlx-mysql / rsa advisory fix

While here: `Cargo.toml` already specifies `default-features = false` with
only `sqlite` for sqlx. The `rsa` vulnerability in CI comes from `Cargo.lock`
pulling `sqlx-mysql` transitively. Two options:

1. Add to `~/GitHub/pnevma/.cargo/audit.toml`:

   ```toml
   [advisories]
   ignore = ["RUSTSEC-2023-0071"]
   ```

2. Or verify `cargo tree -i sqlx-mysql` — if it shows up despite sqlite-only
   features, run `cargo update` to refresh the lockfile.

Either unblocks CI (once Actions minutes reset).
