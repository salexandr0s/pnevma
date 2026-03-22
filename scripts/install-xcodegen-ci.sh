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

verify_checksum() {
  local file="$1" expected="$2"
  local actual
  actual="$(shasum -a 256 "$file" | cut -d' ' -f1)"
  if [ "$actual" != "$expected" ]; then
    echo "ERROR: SHA256 checksum mismatch for $file" >&2
    echo "  Expected: $expected" >&2
    echo "  Got:      $actual" >&2
    exit 1
  fi
  echo "Checksum verified: $file" >&2
}

# SHA256 checksum for XcodeGen release archive. Update when changing XCODEGEN_VERSION.
# Obtain by downloading xcodegen.zip from the release and running: shasum -a 256 xcodegen.zip
XCODEGEN_SHA256="b1c92c5213884ed3c4282d99126832feb9a36e9e036b93ca4b47261833faed90"

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
  local url install_dir tmpdir archive_path extracted_root
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
  verify_checksum "$archive_path" "$XCODEGEN_SHA256"
  unzip -q "$archive_path" -d "$tmpdir"
  extracted_root="$tmpdir/xcodegen"
  [[ -d "$extracted_root" ]] || fail "unexpected XcodeGen archive layout"

  rm -rf "$install_dir"
  mkdir -p "$XCODEGEN_INSTALL_ROOT"
  mv "$extracted_root" "$install_dir"
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
