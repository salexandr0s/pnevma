#!/usr/bin/env bash
set -euo pipefail

script_name="$(basename "${1:-$0}")"

cat <<EOF
$script_name is deprecated.

Pnevma does not currently ship a supported auto-updater in the native Swift/AppKit app.
The legacy updater scripts were retained only as placeholders and are intentionally disabled.

Supported release flow:
1. Build the native app.
2. Sign, notarize, and staple the .app bundle.
3. Publish the signed artifact manually with release notes.

See docs/macos-release.md and docs/security-release-gate.md for the supported release path.
EOF

exit 1
