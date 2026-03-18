# Documentation

This directory contains the current operator, developer, and release documentation for Pnevma.

## Start Here

- [Getting Started](./getting-started.md): bootstrap the repository, verify the native build, and walk through the first project flow.
- [Architecture Overview](./architecture-overview.md): understand the Rust and Swift boundary, the FFI bridge, and how state moves through the system.
- [`pnevma.toml` Reference](./pnevma-toml-reference.md): configure a project for task execution, retention, automation, and remote access.

## Status & Release

- [Implementation Status](./implementation-status.md): current project status, release target, and active priorities.
- [Release Readiness](./release-readiness.md): release quality gates, CI expectations, and validation checks for the next public macOS release.
- [macOS Release Runbook](./macos-release.md): signing, notarization, stapling, and packaged launch verification for the public macOS release.
- [Manual Smoke Tests](./manual-smoke-tests.md): ordered v0.2.0 operator checks for DMG install, project/task/session flows, DB verification, and cleanup.
- [macOS Website Release Plan](./macos-website-release-plan.md): release sequencing and the execution plan for the website distribution path.

## Security and Operations

- [Security Deployment Guide](./security-deployment.md): remote access posture, credential handling, and production-safe configuration rules.
- [Remote Access Guide](./remote-access.md): TLS, CORS, rate limiting, and runtime behavior for the remote API surface.
- [Threat Model](./threat-model.md): documented trust boundaries, risks, and mitigations.

## Additional References

- [Definition of Done](./definition-of-done.md): quality gates for individual changes.
- [Keyboard Shortcuts](./keyboard-shortcuts.md): current app shortcuts and pane navigation.
- [Agent Command Center Gap Analysis](./agent-command-center-gap-analysis.md): what Pnevma still needs before it can honestly claim a true multi-agent command-center experience.
- [Agent Command Center Implementation Plan](./plans/agent-command-center-implementation-plan.md): phased implementation plan for the native command-center window, store, and action routing.
- [Design Notes](./design/): remediation planning and supporting design material.
- [Archived Planning Docs](./archive/): superseded comparisons and older implementation plans retained for historical context.
