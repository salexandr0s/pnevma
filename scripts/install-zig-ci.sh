#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ZIG_VERSION="$(tr -d '\n' < "$ROOT_DIR/.zig-version")"
ZIG_INSTALL_ROOT="${ZIG_INSTALL_ROOT:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/pnevma-tools}"
VERIFY_ONLY=0

fail() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: install-zig-ci.sh [--verify-only]

Installs the Zig version pinned in .zig-version for the current OS/arch.
Use --verify-only to validate the resolved download URL without installing.
EOF
}

detect_platform() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"

  case "$os/$arch" in
    Darwin/arm64) printf '%s\n' "aarch64-macos" ;;
    Darwin/x86_64) printf '%s\n' "x86_64-macos" ;;
    Linux/aarch64 | Linux/arm64) printf '%s\n' "aarch64-linux" ;;
    Linux/x86_64) printf '%s\n' "x86_64-linux" ;;
    *) fail "unsupported platform: $os/$arch" ;;
  esac
}

zig_archive_stem() {
  local platform
  platform="$(detect_platform)"
  printf 'zig-%s-%s\n' "$platform" "$ZIG_VERSION"
}

zig_download_url() {
  local stem
  stem="$(zig_archive_stem)"
  printf 'https://ziglang.org/download/%s/%s.tar.xz\n' "$ZIG_VERSION" "$stem"
}

verify_url() {
  local url
  url="$(zig_download_url)"
  echo "Resolved Zig archive: $url" >&2
  curl -sSfI "$url" >/dev/null
}

verify_version() {
  local zig_bin actual
  zig_bin="$1"
  actual="$("$zig_bin" version)"
  [[ "$actual" == "$ZIG_VERSION" ]] || fail "expected Zig $ZIG_VERSION, got $actual"
}

install_zig() {
  local stem url install_dir tmpdir archive_path
  stem="$(zig_archive_stem)"
  url="$(zig_download_url)"
  install_dir="$ZIG_INSTALL_ROOT/$stem"

  if [[ -x "$install_dir/zig" ]]; then
    verify_version "$install_dir/zig"
    printf '%s\n' "$install_dir"
    return
  fi

  mkdir -p "$ZIG_INSTALL_ROOT"
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/pnevma-zig.XXXXXX")"
  archive_path="$tmpdir/$stem.tar.xz"

  echo "Downloading Zig from $url" >&2
  curl -sSfL "$url" -o "$archive_path"
  tar -xf "$archive_path" -C "$tmpdir"

  rm -rf "$install_dir"
  mv "$tmpdir/$stem" "$install_dir"
  verify_version "$install_dir/zig"

  rm -rf "$tmpdir"
  printf '%s\n' "$install_dir"
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

install_dir="$(install_zig)"
echo "Installed Zig $ZIG_VERSION at $install_dir"
if [[ -n "${GITHUB_PATH:-}" ]]; then
  printf '%s\n' "$install_dir" >> "$GITHUB_PATH"
else
  echo "Add Zig to PATH with: export PATH=\"$install_dir:\$PATH\""
fi
