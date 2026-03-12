# Security Policy

## Supported Versions

| Version | Supported |
| ------- | --------- |
| 0.1.x   | Yes       |

## Reporting a Vulnerability

**Please do not open public issues for security vulnerabilities.**

Use [GitHub's private vulnerability reporting](https://github.com/pnevma/pnevma/security/advisories/new) to report security issues. This ensures the report stays confidential until a fix is available.

### What to include

- Description of the vulnerability
- Steps to reproduce
- Impact assessment
- Suggested fix (if any)

### Response timeline

- **Acknowledgement**: within 48 hours
- **Initial assessment**: within 1 week
- **Fix or mitigation**: depends on severity, but we aim for 30 days for critical issues

### Scope

The following areas are of particular interest:

- Remote access server (HTTP/WebSocket, TLS, authentication)
- SSH key management and credential storage
- FFI bridge between Rust and Swift
- Session supervisor (tmux/PTY handling)
- Context pack compiler (file access, secret redaction)

### Out of scope

- Vulnerabilities in third-party dependencies that are not reachable from Pnevma's code paths
- Issues requiring physical access to the machine
- Social engineering attacks

## Security Design

Pnevma follows these security principles:

- Secrets never appear in logs, scrollback, or context packs
- All remote access requires authentication and TLS
- SSH keys are managed through the system keychain
- Rate limiting on all external-facing endpoints
