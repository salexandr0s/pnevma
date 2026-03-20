#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUST_TOOL="$ROOT_DIR/scripts/with-rust-toolchain.sh"
OUTPUT_DIR="$ROOT_DIR/artifacts/remote-helper"
BUILD_MODE="debug"
BUNDLE_APP_PATH=""
LINUX_TARGETS=(
  "x86_64-unknown-linux-musl"
  "aarch64-unknown-linux-musl"
)
DARWIN_TARGETS=(
  "x86_64-apple-darwin"
  "aarch64-apple-darwin"
)
TARGETS=("${LINUX_TARGETS[@]}" "${DARWIN_TARGETS[@]}")

fail() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: build-remote-helper-artifacts.sh [--release] [--output-dir DIR] [--bundle-app PATH]

Builds packaged remote helper artifacts for the supported Linux and macOS targets and
emits a manifest at artifacts/remote-helper/manifest.json by default.

Options:
  --release           Build release artifacts
  --output-dir DIR    Override the artifact output directory
  --bundle-app PATH   Copy the built artifact bundle into PATH/Contents/Resources/remote-helper
  -h, --help          Show this help
EOF
}

parse_toolchain() {
  sed -n 's/^channel = "\(.*\)"/\1/p' "$ROOT_DIR/rust-toolchain.toml" | head -n 1
}

ensure_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || fail "$cmd is required"
}

ensure_cargo_zigbuild() {
  if "$RUST_TOOL" cargo zigbuild --version >/dev/null 2>&1; then
    return 0
  fi
  echo "Installing cargo-zigbuild..." >&2
  "$RUST_TOOL" cargo install cargo-zigbuild --locked
}

ensure_targets() {
  local toolchain
  toolchain="$(parse_toolchain)"
  [[ -n "$toolchain" ]] || fail "could not resolve pinned Rust toolchain"
  rustup target add --toolchain "$toolchain" "${TARGETS[@]}" >/dev/null
}

workspace_version() {
  sed -n 's/^version = "\(.*\)"/\1/p' "$ROOT_DIR/Cargo.toml" | head -n 1
}

protocol_version() {
  sed -n 's/^const REMOTE_HELPER_PROTOCOL_VERSION: &str = "\(.*\)";/\1/p' \
    "$ROOT_DIR/crates/pnevma-ssh/src/remote_helper.rs" | head -n 1
}

sha256_file() {
  local path="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
    return 0
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
    return 0
  fi
  fail "shasum or sha256sum is required"
}

filesize_bytes() {
  local path="$1"
  if stat -f '%z' "$path" >/dev/null 2>&1; then
    stat -f '%z' "$path"
    return 0
  fi
  stat -c '%s' "$path"
}

copy_into_bundle() {
  local bundle_app="$1"
  local bundle_dir="$bundle_app/Contents/Resources/remote-helper"
  [[ -d "$bundle_app" ]] || fail "app bundle not found: $bundle_app"
  rm -rf "$bundle_dir"
  mkdir -p "$bundle_dir"
  cp -R "$OUTPUT_DIR"/. "$bundle_dir"/
}

build_target() {
  local target="$1"
  local mode="$2"
  local -a build_args

  build_args=(-p pnevma-remote-helper --target "$target")
  if [[ "$mode" == "release" ]]; then
    build_args+=(--release)
  fi

  case "$target" in
    *-unknown-linux-musl)
      "$RUST_TOOL" cargo zigbuild "${build_args[@]}"
      ;;
    *-apple-darwin)
      if [[ "$(uname -s)" != "Darwin" ]]; then
        fail "building packaged Darwin helper artifacts requires macOS (target: $target)"
      fi
      "$RUST_TOOL" cargo build "${build_args[@]}"
      ;;
    *)
      fail "unsupported remote helper build target: $target"
      ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release)
      BUILD_MODE="release"
      shift
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || fail "missing value for --output-dir"
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --bundle-app)
      [[ $# -ge 2 ]] || fail "missing value for --bundle-app"
      BUNDLE_APP_PATH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      fail "unknown argument: $1"
      ;;
  esac
done

ensure_cmd rustup
ensure_cmd zig
ensure_cmd python3
ensure_cargo_zigbuild
ensure_targets

mkdir -p "$OUTPUT_DIR"
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

artifact_rows=""
version="$(workspace_version)"
protocol="$(protocol_version)"
[[ -n "$version" ]] || fail "could not resolve workspace version"
[[ -n "$protocol" ]] || fail "could not resolve remote helper protocol version"

profile_dir="$BUILD_MODE"

for target in "${TARGETS[@]}"; do
  echo "Building pnevma-remote-helper for $target ($BUILD_MODE)..." >&2
  build_target "$target" "$BUILD_MODE"

  built_path="$ROOT_DIR/target/$target/$profile_dir/pnevma-remote-helper"
  [[ -f "$built_path" ]] || fail "expected built helper at $built_path"

  target_dir="$OUTPUT_DIR/$target"
  target_rel="$target/pnevma-remote-helper"
  target_out="$target_dir/pnevma-remote-helper"
  mkdir -p "$target_dir"
  cp "$built_path" "$target_out"
  chmod 755 "$target_out"

  artifact_rows+="${target}|${target_rel}|$(sha256_file "$target_out")|$(filesize_bytes "$target_out")"$'\n'
done

ARTIFACT_ROWS="$artifact_rows" OUTPUT_DIR="$OUTPUT_DIR" VERSION="$version" PROTOCOL="$protocol" \
python3 - <<'PY'
import json
import os
from pathlib import Path

rows = []
for raw in os.environ["ARTIFACT_ROWS"].splitlines():
    target, relative_path, sha256, size = raw.split("|")
    rows.append(
        {
            "target_triple": target,
            "relative_path": relative_path,
            "sha256": sha256,
            "size": int(size),
        }
    )

manifest = {
    "schema_version": 1,
    "package_version": os.environ["VERSION"],
    "protocol_version": os.environ["PROTOCOL"],
    "artifacts": rows,
}

manifest_path = Path(os.environ["OUTPUT_DIR"]) / "manifest.json"
manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
PY

if [[ -n "$BUNDLE_APP_PATH" ]]; then
  copy_into_bundle "$BUNDLE_APP_PATH"
fi
