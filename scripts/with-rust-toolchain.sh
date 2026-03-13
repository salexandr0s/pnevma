#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
toolchain_file="$repo_root/rust-toolchain.toml"
cargo_home="${CARGO_HOME:-$HOME/.cargo}"

if [[ ! -f "$toolchain_file" ]]; then
  echo "error: rust-toolchain.toml not found at $toolchain_file" >&2
  exit 1
fi

rustup_bin=""
if command -v rustup >/dev/null 2>&1; then
  rustup_bin="$(command -v rustup)"
elif [[ -x "$cargo_home/bin/rustup" ]]; then
  rustup_bin="$cargo_home/bin/rustup"
fi

if [[ -z "$rustup_bin" ]]; then
  cat >&2 <<EOF
error: rustup is required to use the repo-pinned Rust toolchain.
Install rustup from https://rustup.rs/ and rerun scripts/bootstrap-dev.sh.
EOF
  exit 1
fi

toolchain="$(
  sed -n 's/^channel = "\(.*\)"/\1/p' "$toolchain_file" | head -n 1
)"

if [[ -z "$toolchain" ]]; then
  echo "error: could not parse Rust toolchain channel from $toolchain_file" >&2
  exit 1
fi

export CARGO_HOME="$cargo_home"
export PATH="$CARGO_HOME/bin:$PATH"

if [[ "$(uname -s)" == "Darwin" ]] && command -v xcrun >/dev/null 2>&1; then
  if clang_bin="$(xcrun --find clang 2>/dev/null)"; then
    export CC="${CC:-$clang_bin}"
    export CARGO_TARGET_AARCH64_APPLE_DARWIN_LINKER="${CARGO_TARGET_AARCH64_APPLE_DARWIN_LINKER:-$clang_bin}"
  fi
  if clangxx_bin="$(xcrun --find clang++ 2>/dev/null)"; then
    export CXX="${CXX:-$clangxx_bin}"
  fi
  if sdk_root="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null)"; then
    export SDKROOT="${SDKROOT:-$sdk_root}"
  fi
fi

exec "$rustup_bin" run "$toolchain" "$@"
