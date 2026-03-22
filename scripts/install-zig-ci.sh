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

# SHA256 checksums for Zig archives. Update when changing ZIG_VERSION.
# Obtain from https://ziglang.org/download/index.json
ZIG_SHA256_AARCH64_MACOS="3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b"
ZIG_SHA256_X86_64_MACOS="375b6909fc1495d16fc2c7db9538f707456bfc3373b14ee83fdd3e22b3d43f7f"
ZIG_SHA256_AARCH64_LINUX="958ed7d1e00d0ea76590d27666efbf7a932281b3d7ba0c6b01b0ff26498f667f"
ZIG_SHA256_X86_64_LINUX="02aa270f183da276e5b5920b1dac44a63f1a49e55050ebde3aecc9eb82f93239"

expected_zig_checksum() {
  local platform
  platform="$(detect_platform)"
  case "$platform" in
    aarch64-macos) printf '%s\n' "$ZIG_SHA256_AARCH64_MACOS" ;;
    x86_64-macos)  printf '%s\n' "$ZIG_SHA256_X86_64_MACOS" ;;
    aarch64-linux) printf '%s\n' "$ZIG_SHA256_AARCH64_LINUX" ;;
    x86_64-linux)  printf '%s\n' "$ZIG_SHA256_X86_64_LINUX" ;;
    *) fail "no checksum for platform: $platform" ;;
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
  verify_checksum "$archive_path" "$(expected_zig_checksum)"
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
