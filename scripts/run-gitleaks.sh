#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GITLEAKS_VERSION="${GITLEAKS_VERSION:-8.30.0}"
GITLEAKS_INSTALL_ROOT="${GITLEAKS_INSTALL_ROOT:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/pnevma-tools}"
GITLEAKS_REPORT_PATH="${GITLEAKS_REPORT_PATH:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/gitleaks-results.sarif}"
LOG_OPTS="${GITLEAKS_LOG_OPTS:-}"
VERIFY_ONLY=0
SCAN_MODE="auto"

fail() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: run-gitleaks.sh [--latest-commit] [--working-tree] [--log-opts=<git log opts>] [--verify-only]

Runs gitleaks with the pinned CLI version. By default, local runs scan the
working tree and pull_request/push runs scan Git history like GitHub Actions.
EOF
}

detect_platform() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"

  case "$os/$arch" in
    Darwin/arm64) printf '%s\n' "darwin_arm64" ;;
    Darwin/x86_64) printf '%s\n' "darwin_x64" ;;
    Linux/aarch64 | Linux/arm64) printf '%s\n' "linux_arm64" ;;
    Linux/x86_64) printf '%s\n' "linux_x64" ;;
    *) fail "unsupported platform: $os/$arch" ;;
  esac
}

version_of() {
  "$1" version | awk 'NR == 1 { sub(/^v/, "", $1); print $1 }'
}

ensure_gitleaks() {
  local platform install_dir bin tmpdir archive url actual_version
  platform="$(detect_platform)"
  install_dir="$GITLEAKS_INSTALL_ROOT/gitleaks-$GITLEAKS_VERSION-$platform"
  bin="$install_dir/gitleaks"

  if [[ -x "$bin" ]]; then
    actual_version="$(version_of "$bin" || true)"
    if [[ "$actual_version" == "$GITLEAKS_VERSION" ]]; then
      printf '%s\n' "$bin"
      return
    fi
  fi

  mkdir -p "$GITLEAKS_INSTALL_ROOT"
  rm -rf "$install_dir"
  mkdir -p "$install_dir"

  archive="gitleaks_${GITLEAKS_VERSION}_${platform}.tar.gz"
  url="https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/${archive}"
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/pnevma-gitleaks.XXXXXX")"

  echo "Downloading gitleaks from $url" >&2
  curl -sSfL "$url" -o "$tmpdir/$archive"
  tar -xzf "$tmpdir/$archive" -C "$install_dir"
  rm -rf "$tmpdir"

  [[ -x "$bin" ]] || fail "expected gitleaks binary at $bin"
  actual_version="$(version_of "$bin" || true)"
  [[ "$actual_version" == "$GITLEAKS_VERSION" ]] || fail \
    "expected gitleaks $GITLEAKS_VERSION, got $actual_version"
  printf '%s\n' "$bin"
}

ensure_pr_base_ref() {
  if [[ "${GITHUB_EVENT_NAME:-}" != "pull_request" || -z "${GITHUB_BASE_REF:-}" ]]; then
    return
  fi

  if git rev-parse --verify "origin/${GITHUB_BASE_REF}" >/dev/null 2>&1; then
    return
  fi

  git fetch --no-tags origin \
    "${GITHUB_BASE_REF}:refs/remotes/origin/${GITHUB_BASE_REF}"
}

resolve_log_opts() {
  if [[ -n "$LOG_OPTS" ]]; then
    printf '%s\n' "$LOG_OPTS"
    return
  fi

  if [[ "${GITHUB_EVENT_NAME:-}" == "pull_request" && -n "${GITHUB_BASE_REF:-}" ]]; then
    printf 'origin/%s..HEAD\n' "$GITHUB_BASE_REF"
    return
  fi

  printf '%s\n' '-1'
}

resolve_scan_mode() {
  if [[ "$SCAN_MODE" != "auto" ]]; then
    printf '%s\n' "$SCAN_MODE"
    return
  fi

  if [[ -n "${GITHUB_EVENT_NAME:-}" ]]; then
    printf '%s\n' "git"
    return
  fi

  printf '%s\n' "dir"
}

collect_changed_paths() {
  {
    git diff --name-only --relative HEAD --
    git diff --cached --name-only --relative --
    git ls-files --others --exclude-standard
  } | sed '/^$/d' | sort -u
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --latest-commit)
      SCAN_MODE='git'
      LOG_OPTS='-1'
      shift
      ;;
    --working-tree)
      SCAN_MODE='dir'
      shift
      ;;
    --log-opts=*)
      SCAN_MODE='git'
      LOG_OPTS="${1#*=}"
      shift
      ;;
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

bin="$(ensure_gitleaks)"

if [[ "$VERIFY_ONLY" -eq 1 ]]; then
  echo "gitleaks $("$bin" version)"
  exit 0
fi

ensure_pr_base_ref
scan_mode="$(resolve_scan_mode)"
mkdir -p "$(dirname "$GITLEAKS_REPORT_PATH")"

cd "$ROOT_DIR"
if [[ "$scan_mode" == "git" ]]; then
  log_opts="$(resolve_log_opts)"
  echo "Running gitleaks $("$bin" version) with log opts: $log_opts"
  "$bin" detect \
    --redact \
    -v \
    --exit-code=2 \
    --report-format=sarif \
    --report-path="$GITLEAKS_REPORT_PATH" \
    --log-level=debug \
    --log-opts="$log_opts"
else
  scan_root="$(mktemp -d "${TMPDIR:-/tmp}/pnevma-gitleaks-tree.XXXXXX")"
  while IFS= read -r path; do
    [[ -f "$ROOT_DIR/$path" ]] || continue
    mkdir -p "$scan_root/$(dirname "$path")"
    cp "$ROOT_DIR/$path" "$scan_root/$path"
  done < <(collect_changed_paths)

  if [[ -z "$(find "$scan_root" -type f -print -quit)" ]]; then
    echo "No modified files to scan with gitleaks"
    rm -rf "$scan_root"
    exit 0
  fi

  echo "Running gitleaks $("$bin" version) against modified files"
  "$bin" detect \
    --redact \
    -v \
    --exit-code=2 \
    --report-format=sarif \
    --report-path="$GITLEAKS_REPORT_PATH" \
    --log-level=debug \
    --no-git \
    --source="$scan_root"
  rm -rf "$scan_root"
fi
