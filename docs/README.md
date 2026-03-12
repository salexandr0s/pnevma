# Documentation

This directory contains the current operator, developer, and release
documentation for Pnevma.

## Start Here

- [Getting Started](./getting-started.md): bootstrap the repository, verify the
  native build, and walk through the first project flow.
- [Architecture Overview](./architecture-overview.md): understand the Rust and
  Swift boundary, the FFI bridge, and how state moves through the system.
- [`pnevma.toml` Reference](./pnevma-toml-reference.md): configure a project for
  task execution, retention, automation, and remote access.

## Release Hardening

- [Implementation Status](./implementation-status.md): current project status,
  active release target, and remaining hardening focus areas.
- [Hardening Exit Criteria](./hardening-exit-criteria.md): merge policy and the
  bar that must be met before feature work resumes.
- [macOS Release Runbook](./macos-release.md): signing, notarization, stapling,
  and packaged launch verification for the public macOS release.
- [macOS Website Release Plan](./macos-website-release-plan.md): release
  sequencing, scope boundaries, and the execution plan for the website
  distribution path.

## Security and Operations

- [Security Deployment Guide](./security-deployment.md): remote access posture,
  credential handling, and production-safe configuration rules.
- [Remote Access Guide](./remote-access.md): TLS, CORS, rate limiting, and
  runtime behavior for the remote API surface.
- [Threat Model](./threat-model.md): documented trust boundaries, risks, and
  mitigations.

## Additional References

- [Definition of Done](./definition-of-done.md): quality gates for changes while
  release hardening is active.
- [Keyboard Shortcuts](./keyboard-shortcuts.md): current app shortcuts and pane
  navigation.
- [Design Notes](./design/): remediation planning and supporting design
  material.
- [Archived Planning Docs](./archive/): superseded comparisons and older
  implementation plans retained for historical context.
