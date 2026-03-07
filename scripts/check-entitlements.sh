#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENTITLEMENTS_PATH="${ENTITLEMENTS_PATH:-$ROOT_DIR/native/Pnevma/Pnevma.entitlements}"
APP_PATH="${APP_PATH:-}"

allowed_keys=(
  "com.apple.security.cs.disable-library-validation"
  "com.apple.security.network.client"
)

tmp_plist=""

cleanup() {
  if [[ -n "$tmp_plist" && -f "$tmp_plist" ]]; then
    rm -f "$tmp_plist"
  fi
}
trap cleanup EXIT

extract_keys() {
  local plist_path="$1"
  /usr/libexec/PlistBuddy -c Print "$plist_path" 2>/dev/null \
    | awk '/ = / { gsub(/^[[:space:]]+/, "", $0); sub(/ = .*/, "", $0); print }' \
    | sort -u
}

print_value() {
  local plist_path="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$plist_path" 2>/dev/null
}

if [[ -n "$APP_PATH" ]]; then
  if [[ ! -d "$APP_PATH" ]]; then
    echo "App bundle not found: $APP_PATH"
    exit 1
  fi
  tmp_plist="$(mktemp -t pnevma-entitlements.XXXXXX.plist)"
  if ! codesign -d --entitlements :- "$APP_PATH" >"$tmp_plist" 2>/dev/null; then
    echo "Failed to extract effective entitlements from $APP_PATH"
    exit 1
  fi
  if [[ ! -s "$tmp_plist" ]]; then
    echo "No effective entitlements were embedded in $APP_PATH"
    exit 1
  fi
  plist_to_check="$tmp_plist"
  echo "Checking effective entitlements for $APP_PATH"
else
  if [[ ! -f "$ENTITLEMENTS_PATH" ]]; then
    echo "Entitlements file not found: $ENTITLEMENTS_PATH"
    exit 1
  fi
  plist_to_check="$ENTITLEMENTS_PATH"
  echo "Checking entitlements source file $ENTITLEMENTS_PATH"
fi

actual_keys="$(extract_keys "$plist_to_check")"
expected_keys="$(printf '%s\n' "${allowed_keys[@]}" | sort -u)"

if [[ "$actual_keys" != "$expected_keys" ]]; then
  echo "Entitlements drift detected."
  echo "Expected keys:"
  printf '%s\n' "$expected_keys"
  echo
  echo "Actual keys:"
  printf '%s\n' "$actual_keys"
  exit 1
fi

for key in "${allowed_keys[@]}"; do
  value="$(print_value "$plist_to_check" "$key")"
  if [[ "$value" != "true" ]]; then
    echo "Entitlement $key must be true, got: ${value:-<missing>}"
    exit 1
  fi
done

echo "Entitlements match the checked-in allowlist:"
printf ' - %s\n' "${allowed_keys[@]}"
