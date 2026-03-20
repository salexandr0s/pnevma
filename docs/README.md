# Documentation

This directory contains the current public, operator, contributor, and release documentation for Pnevma.

## Evaluate Pnevma

- [Product Tour](./product-tour.md): walk through the current operator surfaces and the overall product shape.
- [Architecture Overview](./architecture-overview.md): understand the Swift and Rust boundary, runtime paths, and persistence model.
- [Implementation Status](./implementation-status.md): current repo status, release target, and active priorities.
- [Keyboard Shortcuts](./keyboard-shortcuts.md): current app shortcuts and pane navigation.

## Build And Configure

- [Getting Started](./getting-started.md): bootstrap the repository, verify the native build, and walk through the first workspace flow.
- [`pnevma.toml` Reference](./pnevma-toml-reference.md): configure project, automation, remote, redaction, tracker, and global settings.
- [Definition of Done](./definition-of-done.md): quality gates for individual changes.

## Operate And Secure

- [Security Deployment Guide](./security-deployment.md): remote access posture, credential handling, and production-safe configuration rules.
- [Remote Access Guide](./remote-access.md): TLS, CORS, rate limiting, and runtime behavior for the remote API surface.
- [Manual Smoke Tests](./manual-smoke-tests.md): ordered operator checks for project, task, session, review, and cleanup flows.
- [Manual Security Tests](./manual-security-tests.md): targeted validation for auth, rate limits, allowlists, and secret handling.
- [Threat Model](./threat-model.md): documented trust boundaries, risks, and mitigations.

## Release

- [Release Readiness](./release-readiness.md): release quality gates, CI expectations, and validation checks for the next public macOS release.
- [macOS Release Runbook](./macos-release.md): signing, DMG packaging, first-launch bypass instructions, and evidence preservation for the current public release path.
- [macOS Website Release Plan](./macos-website-release-plan.md): the target follow-up plan for the fully notarized website distribution path.
- [Remote SSH Helper Smoke Tests](./manual-remote-ssh-tests.md): packaged remote helper install and upgrade validation on real hosts.
- [Remote Durable Lifecycle Validation](./manual-remote-durable-lifecycle-tests.md): packaged remote durable session validation for detach, relaunch, reconnect, and evidence capture.

## Additional References

- [Agent Command Center Gap Analysis](./agent-command-center-gap-analysis.md): what Pnevma still needs before it can honestly claim a true multi-agent command-center experience.
- [Agent Command Center Implementation Plan](./plans/agent-command-center-implementation-plan.md): phased implementation plan for the native command-center window, store, and action routing.
- [Design Notes](./design/): remediation planning and supporting design material.
- [Archived Planning Docs](./archive/): superseded comparisons and older implementation plans retained for historical context.
