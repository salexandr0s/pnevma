#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EVIDENCE_DIR="${EVIDENCE_DIR:-$ROOT_DIR/release-evidence}"
AUTOMATED_DIR="$EVIDENCE_DIR/automated"
MANUAL_DIR="$EVIDENCE_DIR/manual"
TEMPLATE_DIR="$ROOT_DIR/docs/release-evidence-templates"
RELEASE_MODE="${RELEASE_MODE:-signed-only}"
VERSION="${VERSION:-$("$ROOT_DIR/scripts/release-version.sh" check)}"
APP_PATH="${APP_PATH:-}"
DMG_PATH="${DMG_PATH:-}"
CHECKSUM_PATH="${CHECKSUM_PATH:-}"

usage() {
  cat <<'EOF'
Usage: release-evidence.sh <init|collect>

Environment:
  EVIDENCE_DIR   Output directory (default: ./release-evidence)
  RELEASE_MODE   signed-only or notarized-follow-up
  VERSION        Release version (defaults to release-version.sh check)
  APP_PATH       Optional signed app bundle path for collect
  DMG_PATH       Optional signed DMG path for collect
  CHECKSUM_PATH  Optional checksum path for collect
EOF
}

copy_manual_templates() {
  mkdir -p "$MANUAL_DIR"
  if [[ -d "$TEMPLATE_DIR" ]]; then
    local template_path dest_path
    for template_path in "$TEMPLATE_DIR"/*.md; do
      [[ -f "$template_path" ]] || continue
      dest_path="$MANUAL_DIR/$(basename "$template_path")"
      if [[ ! -f "$dest_path" ]]; then
        cp "$template_path" "$dest_path"
      fi
    done
  fi
}

write_manifest() {
  EVIDENCE_DIR="$EVIDENCE_DIR" RELEASE_MODE="$RELEASE_MODE" VERSION="$VERSION" python3 - <<'PY'
import json
import os
from datetime import datetime, timezone
from pathlib import Path

root = Path(os.environ["EVIDENCE_DIR"])
automated = root / "automated"
manual = root / "manual"

manifest = {
    "schema_version": 1,
    "release_mode": os.environ["RELEASE_MODE"],
    "package_version": os.environ["VERSION"],
    "generated_at_utc": datetime.now(timezone.utc).isoformat(),
    "automated_files": sorted(str(path.relative_to(root)) for path in automated.glob("*") if path.is_file()),
    "manual_files": sorted(str(path.relative_to(root)) for path in manual.glob("*") if path.is_file()),
}

(root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
PY
}

write_checklist() {
  mark() {
    local path="$1"
    if [[ -f "$path" ]]; then
      printf '[x]'
    else
      printf '[ ]'
    fi
  }

  manual_mark() {
    local path="$1"
    if [[ -f "$path" ]] && grep -q '^- Status: complete$' "$path"; then
      printf '[x]'
    else
      printf '[ ]'
    fi
  }

  cat > "$EVIDENCE_DIR/CHECKLIST.md" <<EOF
# Release evidence checklist

Mode: \`$RELEASE_MODE\`
Version: \`$VERSION\`

## Automated

- $(mark "$AUTOMATED_DIR/entitlements-source-check.txt") Entitlement allowlist check
- $(mark "$AUTOMATED_DIR/app-entitlements-check.txt") Signed app entitlement check
- $(mark "$AUTOMATED_DIR/app-entitlements.plist") Effective entitlements plist
- $(mark "$AUTOMATED_DIR/app-codesign-verify.txt") App codesign verification
- $(mark "$AUTOMATED_DIR/dmg-codesign-verify.txt") DMG codesign verification
- $(mark "$AUTOMATED_DIR/dmg.sha256") DMG checksum
- $(mark "$AUTOMATED_DIR/packaged-launch-smoke.log") Packaged launch smoke
- $(mark "$AUTOMATED_DIR/signed-app-ghostty-smoke.log") Signed app Ghostty smoke
- $(mark "$AUTOMATED_DIR/dmg-spctl.txt") Informational DMG spctl output

## Manual

- $(manual_mark "$MANUAL_DIR/clean-machine-install-notes.md") Clean-machine install notes
- $(manual_mark "$MANUAL_DIR/manual-smoke-results.md") Manual smoke results
- $(manual_mark "$MANUAL_DIR/manual-security-results.md") Manual security results
- $(manual_mark "$MANUAL_DIR/remote-validation-results.md") Remote validation results (only if remote ships)
EOF
}

init_bundle() {
  mkdir -p "$AUTOMATED_DIR" "$MANUAL_DIR"
  copy_manual_templates
  write_manifest
  write_checklist
  echo "Initialized release evidence bundle at $EVIDENCE_DIR"
}

collect_bundle() {
  init_bundle

  "$ROOT_DIR/scripts/check-entitlements.sh" > "$AUTOMATED_DIR/entitlements-source-check.txt" 2>&1

  if [[ -n "$APP_PATH" ]]; then
    APP_PATH="$APP_PATH" "$ROOT_DIR/scripts/check-entitlements.sh" > "$AUTOMATED_DIR/app-entitlements-check.txt" 2>&1
    codesign -d --entitlements :- "$APP_PATH" > "$AUTOMATED_DIR/app-entitlements.plist" 2>/dev/null
    codesign --verify --deep --strict --verbose=2 "$APP_PATH" > "$AUTOMATED_DIR/app-codesign-verify.txt" 2>&1
  fi

  if [[ -n "$DMG_PATH" ]]; then
    codesign --verify --verbose=2 "$DMG_PATH" > "$AUTOMATED_DIR/dmg-codesign-verify.txt" 2>&1
    if [[ -n "$CHECKSUM_PATH" && -f "$CHECKSUM_PATH" ]]; then
      cp "$CHECKSUM_PATH" "$AUTOMATED_DIR/dmg.sha256"
    else
      shasum -a 256 "$DMG_PATH" > "$AUTOMATED_DIR/dmg.sha256"
    fi
    spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH" \
      > "$AUTOMATED_DIR/dmg-spctl.txt" 2>&1 || echo "spctl exited $? (informational for signed-only release)" >> "$AUTOMATED_DIR/dmg-spctl.txt"
  fi

  write_manifest
  write_checklist
  echo "Collected release evidence into $EVIDENCE_DIR"
}

case "${1:-}" in
  init)
    init_bundle
    ;;
  collect)
    collect_bundle
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
