#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CARGO_TOML_PATH="$ROOT_DIR/Cargo.toml"
INFO_PLIST_PATH="$ROOT_DIR/native/Info.plist"

usage() {
  cat <<'EOF'
Usage: release-version.sh <command> [tag]

Commands:
  workspace      Print the workspace package version from Cargo.toml
  bundle         Print CFBundleShortVersionString from native/Info.plist
  bundle-build   Print CFBundleVersion from native/Info.plist
  check [tag]    Verify workspace and bundle versions match; if tag is provided,
                 also verify it matches after stripping an optional leading "v"
EOF
}

workspace_version() {
  awk '
    /^\[workspace\.package\]/ { in_block=1; next }
    /^\[/ { if (in_block) exit; in_block=0 }
    in_block && $1 == "version" {
      gsub(/"/, "", $3)
      print $3
      exit
    }
  ' "$CARGO_TOML_PATH"
}

bundle_version() {
  /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST_PATH"
}

bundle_build_version() {
  /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST_PATH"
}

normalize_tag_version() {
  local raw="${1:-}"
  raw="${raw#refs/tags/}"
  raw="${raw#v}"
  printf '%s\n' "$raw"
}

command_name="${1:-}"
tag_arg="${2:-}"

case "$command_name" in
  workspace)
    version="$(workspace_version)"
    [[ -n "$version" ]] || {
      echo "failed to resolve workspace version from $CARGO_TOML_PATH" >&2
      exit 1
    }
    printf '%s\n' "$version"
    ;;
  bundle)
    printf '%s\n' "$(bundle_version)"
    ;;
  bundle-build)
    printf '%s\n' "$(bundle_build_version)"
    ;;
  check)
    workspace="$(workspace_version)"
    bundle="$(bundle_version)"

    [[ -n "$workspace" ]] || {
      echo "failed to resolve workspace version from $CARGO_TOML_PATH" >&2
      exit 1
    }
    [[ -n "$bundle" ]] || {
      echo "failed to resolve bundle version from $INFO_PLIST_PATH" >&2
      exit 1
    }

    if [[ "$workspace" != "$bundle" ]]; then
      echo "release version mismatch: Cargo.toml has $workspace but native/Info.plist has $bundle" >&2
      exit 1
    fi

    if [[ -n "$tag_arg" ]]; then
      normalized_tag="$(normalize_tag_version "$tag_arg")"
      if [[ -z "$normalized_tag" ]]; then
        echo "tag version is empty after normalization: $tag_arg" >&2
        exit 1
      fi

      if [[ "$workspace" != "$normalized_tag" ]]; then
        echo "release version mismatch: metadata has $workspace but tag resolves to $normalized_tag ($tag_arg)" >&2
        exit 1
      fi
    fi

    printf '%s\n' "$workspace"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
