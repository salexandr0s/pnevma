# Product Tour

Pnevma is a native macOS operator workspace for running CLI coding agents against real repositories without reducing the workflow to a pile of terminals and ad hoc scripts.

This guide walks through the main surfaces that exist in the app today and points to the deeper docs for setup, security, and release work.

## 1. Open Work The Way You Actually Find It

The **Workspace Opener** is the front door.

You can start from:

- an existing local folder
- a prompt-driven workspace draft
- GitHub issues
- GitHub pull requests
- GitHub branches
- a remote SSH target

If the repository is missing Pnevma scaffolding, the app can initialize `pnevma.toml` and the `.pnevma/` support files during setup.

## 2. Get Project Context Before You Dispatch

Once a workspace is open, Pnevma gives you a native overview of the project and current operator state instead of dropping you straight into a terminal.

That includes:

- workspace and repository metadata
- task and automation status
- session and notification counts
- GitHub-backed workspace opener context for issue, PR, and branch driven flows

The **Task Board** is then the main dispatch and triage surface for work that is ready, running, in review, or done.

## 3. Run Agents In Managed Terminals

Pnevma embeds [Ghostty](https://ghostty.org) for the terminal layer, but the app does more than render a shell.

The backend supervises sessions, captures scrollback, persists state, and supports replay and restore behavior so agent runs are durable enough to survive normal desktop usage. Managed session restore across relaunch is part of the current product surface.

Pnevma also keeps the repository discipline explicit:

- one task maps to one git worktree
- agent execution is tied to that worktree
- state changes and artifacts are recorded in the backend

## 4. Review Before You Merge

Pnevma treats review as a first-class workflow, not an afterthought.

Current review surfaces include:

- diff inspection
- review packs
- checks and status feedback
- merge queue mechanics
- protected actions around high-impact operations

The goal is simple: agent output should become easier to inspect and accept, not easier to merge blindly.

## 5. Operate Across Local And Remote Machines

The **SSH** surface is not just a saved-connection list.

Today it covers:

- SSH profile management
- key handling and validation
- Tailscale device discovery
- remote durable SSH sessions
- packaged remote helper install, health, and compatibility flows on supported targets

For remote-enabled release work, the repository already includes operator docs for packaged remote helper validation and durable reconnect or relaunch scenarios.

## 6. Watch The Rest Of The System

Beyond terminals and tasks, Pnevma already includes broader operator surfaces:

- **Command Center** for higher-level cross-workspace supervision
- **Tool Drawer** and surrounding chrome for faster pivots between tools
- **Notifications** for attention management
- **Daily Brief** for a compact operational summary
- **Analytics** and provider-usage views
- **Ports**, **Rules**, **Secrets**, and **Settings** panes for ongoing project and app management

This is the part of the product that recent native polish work has been improving: better chrome, better workspace opening flows, cleaner tab behavior, and sharper settings and tool interactions.

## 7. Know The Boundaries

Pnevma is structured to keep workflow logic in Rust and the macOS layer thin.

- Swift/AppKit renders the desktop UI and calls into the backend through the C FFI bridge.
- Rust owns tasks, sessions, worktrees, persistence, automation, remote access, SSH flows, and redaction.
- Agents are isolated by worktree, not by OS sandbox.

That means Pnevma is opinionated about workflow control, not about pretending agents are running in a separate security boundary.

## Go Deeper

- [Getting Started](./getting-started.md) for local setup and the first workspace flow
- [Architecture Overview](./architecture-overview.md) for the Swift/Rust boundary and runtime paths
- [`pnevma.toml` Reference](./pnevma-toml-reference.md) for project and global configuration
- [Security Deployment Guide](./security-deployment.md) for remote posture and secret handling
- [Remote Access Guide](./remote-access.md) for HTTPS and WebSocket behavior
- [macOS Release Runbook](./macos-release.md) for signing, DMG packaging, first-launch instructions, and release evidence
- [Documentation Index](./README.md) for the broader doc set
