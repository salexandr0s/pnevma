#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/release-common.sh"

APP_PATH="${APP_PATH:-}"
DMG_PATH="${DMG_PATH:-}"
VERSION="${VERSION:-}"
ENTITLEMENTS_PATH="${ENTITLEMENTS_PATH:-$ROOT_DIR/native/Pnevma/Pnevma.entitlements}"
EVIDENCE_DIR="${EVIDENCE_DIR:-$ROOT_DIR/release-evidence}"
PROBE_ROOT="$EVIDENCE_DIR/probes/disable-library-validation"
BASELINE_APP_PATH=""
BASELINE_SOURCE_LABEL=""

if [[ -z "${APPLE_SIGNING_IDENTITY:-}" ]]; then
  echo "APPLE_SIGNING_IDENTITY is required"
  exit 1
fi

resolve_version() {
  "$ROOT_DIR/scripts/release-version.sh" check
}

default_packaged_dmg_path() {
  local version="${VERSION:-$(resolve_version)}"
  local candidates=(
    "$ROOT_DIR/artifacts/Pnevma-${version}-macos-arm64.dmg"
    "$ROOT_DIR/Pnevma-${version}-macos-arm64.dmg"
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  printf '%s\n' "${candidates[0]}"
}

if [[ -z "$APP_PATH" ]]; then
  APP_PATH="$(default_app_path)"
fi

if [[ ! -f "$ENTITLEMENTS_PATH" ]]; then
  echo "Entitlements file not found at $ENTITLEMENTS_PATH"
  exit 1
fi

tmp_root="$(mktemp -d -t pnevma-disable-library-validation.XXXXXX)"
trap 'rm -rf "$tmp_root"' EXIT

probe_entitlements="$tmp_root/probe.entitlements"
cp "$ENTITLEMENTS_PATH" "$probe_entitlements"
/usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$probe_entitlements"

mkdir -p "$PROBE_ROOT"

prepare_baseline_app() {
  if [[ -d "$APP_PATH" ]] && codesign --verify --deep --strict --verbose=2 "$APP_PATH" >/dev/null 2>&1; then
    BASELINE_APP_PATH="$APP_PATH"
    BASELINE_SOURCE_LABEL="existing-signed-app"
    return 0
  fi

  local dmg_path="$DMG_PATH"
  if [[ -z "$dmg_path" ]]; then
    dmg_path="$(default_packaged_dmg_path)"
  fi

  if [[ ! -f "$dmg_path" ]]; then
    echo "Signed baseline app not found at $APP_PATH and packaged DMG not found at $dmg_path"
    exit 1
  fi

  local mounted_dir="$tmp_root/baseline-mounted-dmg"
  local copied_app_dir="$tmp_root/baseline-packaged-app"
  mkdir -p "$mounted_dir" "$copied_app_dir"

  hdiutil attach "$dmg_path" -mountpoint "$mounted_dir" -nobrowse -readonly -quiet
  local mounted_app
  mounted_app="$(find "$mounted_dir" -maxdepth 1 -type d -name 'Pnevma.app' -print -quit)"
  if [[ -z "$mounted_app" ]]; then
    hdiutil detach "$mounted_dir" -quiet >/dev/null 2>&1 || true
    echo "Mounted disk image did not contain Pnevma.app: $dmg_path"
    exit 1
  fi

  BASELINE_APP_PATH="$copied_app_dir/Pnevma.app"
  ditto "$mounted_app" "$BASELINE_APP_PATH"
  hdiutil detach "$mounted_dir" -quiet >/dev/null 2>&1 || true

  if ! codesign --verify --deep --strict --verbose=2 "$BASELINE_APP_PATH" >/dev/null 2>&1; then
    echo "Signed app copied from DMG failed verification: $BASELINE_APP_PATH"
    exit 1
  fi

  BASELINE_SOURCE_LABEL="packaged-dmg:$dmg_path"
}

write_result() {
  local mode_dir="$1"
  local label="$2"
  local launch_status="$3"
  local ghostty_status="$4"

  cat > "$mode_dir/result.env" <<EOF
label=$label
launch_status=$launch_status
ghostty_status=$ghostty_status
EOF
}

run_baseline_mode() {
  local mode_dir="$PROBE_ROOT/baseline"
  local launch_status=1
  local ghostty_status=1

  mkdir -p "$mode_dir"
  cp "$ENTITLEMENTS_PATH" "$mode_dir/used-entitlements.plist"
  cat > "$mode_dir/app-sign.txt" <<EOF
Using existing signed app for baseline validation:
$BASELINE_APP_PATH
Source: $BASELINE_SOURCE_LABEL
No re-sign performed for baseline mode.
EOF

  codesign -d --entitlements :- "$BASELINE_APP_PATH" > "$mode_dir/app-entitlements.plist" 2>/dev/null
  codesign --verify --deep --strict --verbose=2 "$BASELINE_APP_PATH" > "$mode_dir/app-codesign-verify.txt" 2>&1

  if "$ROOT_DIR/scripts/run-app-smoke.sh" --app "$BASELINE_APP_PATH" --mode launch --log "$mode_dir/app-launch-smoke.log"; then
    launch_status=0
  fi

  if "$ROOT_DIR/scripts/run-app-smoke.sh" --app "$BASELINE_APP_PATH" --mode ghostty --log "$mode_dir/app-ghostty-smoke.log"; then
    ghostty_status=0
  fi

  write_result "$mode_dir" "baseline" "$launch_status" "$ghostty_status"
}

run_probe_mode() {
  local label="probe-with-disable-library-validation"
  local entitlement_plist="$probe_entitlements"
  local mode_dir="$PROBE_ROOT/$label"
  local mode_app_dir="$tmp_root/$label"
  local mode_app="$mode_app_dir/Pnevma.app"
  local launch_status=1
  local ghostty_status=1

  mkdir -p "$mode_dir" "$mode_app_dir"
  ditto "$BASELINE_APP_PATH" "$mode_app"
  codesign --remove-signature "$mode_app" >/dev/null 2>&1 || true
  cp "$entitlement_plist" "$mode_dir/used-entitlements.plist"

  CODESIGN_TIMESTAMP=0 \
  ENTITLEMENTS_PATH="$entitlement_plist" \
  APP_PATH="$mode_app" \
  "$ROOT_DIR/scripts/release-macos-sign.sh" > "$mode_dir/app-sign.txt" 2>&1

  codesign -d --entitlements :- "$mode_app" > "$mode_dir/app-entitlements.plist" 2>/dev/null
  codesign --verify --deep --strict --verbose=2 "$mode_app" > "$mode_dir/app-codesign-verify.txt" 2>&1

  if "$ROOT_DIR/scripts/run-app-smoke.sh" --app "$mode_app" --mode launch --log "$mode_dir/app-launch-smoke.log"; then
    launch_status=0
  fi

  if "$ROOT_DIR/scripts/run-app-smoke.sh" --app "$mode_app" --mode ghostty --log "$mode_dir/app-ghostty-smoke.log"; then
    ghostty_status=0
  fi

  write_result "$mode_dir" "$label" "$launch_status" "$ghostty_status"
}

prepare_baseline_app
run_baseline_mode

baseline_launch_status="$(awk -F= '/^launch_status=/{print $2}' "$PROBE_ROOT/baseline/result.env")"
baseline_ghostty_status="$(awk -F= '/^ghostty_status=/{print $2}' "$PROBE_ROOT/baseline/result.env")"
probe_launch_status="not-run"
probe_ghostty_status="not-run"

if [[ "$baseline_launch_status" != "0" || "$baseline_ghostty_status" != "0" ]]; then
  run_probe_mode
  probe_launch_status="$(awk -F= '/^launch_status=/{print $2}' "$PROBE_ROOT/probe-with-disable-library-validation/result.env")"
  probe_ghostty_status="$(awk -F= '/^ghostty_status=/{print $2}' "$PROBE_ROOT/probe-with-disable-library-validation/result.env")"
fi

cat > "$PROBE_ROOT/summary.md" <<EOF
# disable-library-validation probe summary

- Baseline launch smoke exit: $baseline_launch_status
- Baseline Ghostty smoke exit: $baseline_ghostty_status
- Probe launch smoke exit: $probe_launch_status
- Probe Ghostty smoke exit: $probe_ghostty_status

Interpretation:
- Baseline pass means the checked-in entitlement policy is sufficient on a signed build.
- Probe-only pass suggests \`com.apple.security.cs.disable-library-validation\` is likely still required.
- If both modes fail, collect additional signed-build diagnostics before changing the shipping allowlist.
- Probe status may be \`not-run\` when the baseline already passes.
EOF

if [[ "$baseline_launch_status" == "0" && "$baseline_ghostty_status" == "0" ]]; then
  echo "Baseline signed-build probe passed without disable-library-validation"
  exit 0
fi

if [[ "$probe_launch_status" == "0" && "$probe_ghostty_status" == "0" ]]; then
  echo "Baseline failed but probe passed; disable-library-validation is likely required"
  exit 2
fi

echo "Both baseline and probe modes failed; inspect $PROBE_ROOT"
exit 1
