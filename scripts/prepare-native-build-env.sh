#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
derived_data_path="${1:-$repo_root/native/DerivedData}"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "error: xcodebuild not found; install Xcode command line tools" >&2
  exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
  echo "error: xcrun not found; install/select Xcode first" >&2
  exit 1
fi

developer_dir="$(xcode-select -p 2>/dev/null || true)"
if [[ -z "$developer_dir" ]]; then
  echo "error: xcode-select has no active developer directory" >&2
  exit 1
fi

clang_bin="$(xcrun --find clang)"
clangxx_bin="$(xcrun --find clang++)"
sdk_root="$(xcrun --sdk macosx --show-sdk-path)"

echo "Using developer dir: $developer_dir"
echo "Using clang: $clang_bin"
echo "Using clang++: $clangxx_bin"
echo "Using macOS SDK: $sdk_root"

mkdir -p "$(dirname "$derived_data_path")" "$repo_root/native/build/logs"
rm -rf "$derived_data_path"
