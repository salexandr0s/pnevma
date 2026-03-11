#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
XCODEGEN_VERSION="$(tr -d '\n' < "$ROOT_DIR/.xcodegen-version")"
XCODEGEN_INSTALL_ROOT="${XCODEGEN_INSTALL_ROOT:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/pnevma-tools}"
VERIFY_ONLY=0

fail() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: install-xcodegen-ci.sh [--verify-only]

Installs the XcodeGen version pinned in .xcodegen-version from the official GitHub release.
Use --verify-only to validate the resolved download URL without installing.
EOF
}

xcodegen_download_url() {
  printf 'https://github.com/yonaskolb/XcodeGen/releases/download/%s/xcodegen.zip\n' "$XCODEGEN_VERSION"
}

verify_url() {
  local url
  url="$(xcodegen_download_url)"
  echo "Resolved XcodeGen archive: $url" >&2
  curl -sSfI "$url" >/dev/null
}

verify_version() {
  local xcodegen_bin actual
  xcodegen_bin="$1"
  actual="$("$xcodegen_bin" version | sed 's/^Version: //')"
  [[ "$actual" == "$XCODEGEN_VERSION" ]] || fail "expected XcodeGen $XCODEGEN_VERSION, got $actual"
}

install_xcodegen() {
  local url install_dir tmpdir archive_path
  url="$(xcodegen_download_url)"
  install_dir="$XCODEGEN_INSTALL_ROOT/xcodegen-$XCODEGEN_VERSION"

  if [[ -x "$install_dir/bin/xcodegen" ]]; then
    verify_version "$install_dir/bin/xcodegen"
    printf '%s\n' "$install_dir/bin"
    return
  fi

  mkdir -p "$XCODEGEN_INSTALL_ROOT"
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/pnevma-xcodegen.XXXXXX")"
  archive_path="$tmpdir/xcodegen.zip"

  echo "Downloading XcodeGen from $url" >&2
  curl -sSfL "$url" -o "$archive_path"
  unzip -q "$archive_path" -d "$tmpdir"

  rm -rf "$install_dir"
  mkdir -p "$install_dir"
  mv "$tmpdir/bin" "$install_dir/bin"
  verify_version "$install_dir/bin/xcodegen"

  rm -rf "$tmpdir"
  printf '%s\n' "$install_dir/bin"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify-only)
      VERIFY_ONLY=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      fail "unknown argument: $1"
      ;;
  esac
done

verify_url

if [[ "$VERIFY_ONLY" -eq 1 ]]; then
  exit 0
fi

install_dir="$(install_xcodegen)"
echo "Installed XcodeGen $XCODEGEN_VERSION at $install_dir"
if [[ -n "${GITHUB_PATH:-}" ]]; then
  printf '%s\n' "$install_dir" >> "$GITHUB_PATH"
else
  echo "Add XcodeGen to PATH with: export PATH=\"$install_dir:\$PATH\""
fi
