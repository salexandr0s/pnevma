#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REMOTE_HOST="${REMOTE_HOST:-}"
REMOTE_USER="${REMOTE_USER:-}"
REMOTE_PORT="${REMOTE_PORT:-22}"
REMOTE_IDENTITY_FILE="${REMOTE_IDENTITY_FILE:-}"
REMOTE_PROXY_JUMP="${REMOTE_PROXY_JUMP:-}"
SCENARIO="${SCENARIO:-fresh}"
EXPECTED_TARGET_TRIPLE="${EXPECTED_TARGET_TRIPLE:-}"
EXPECTED_PACKAGE_VERSION="${EXPECTED_PACKAGE_VERSION:-0.0.0-fixture}"
EXPECTED_PROTOCOL_VERSION="${EXPECTED_PROTOCOL_VERSION:-1}"
EXPECTED_ARTIFACT_SHA="${EXPECTED_ARTIFACT_SHA:-fixture-sha}"
REMOTE_HELPER_PATH="\$HOME/.local/share/pnevma/bin/pnevma-remote-helper"
REMOTE_METADATA_PATH="\$HOME/.local/share/pnevma/bin/pnevma-remote-helper.metadata"

usage() {
  cat >&2 <<'EOF'
usage: REMOTE_HOST=... REMOTE_USER=... [REMOTE_PORT=22] [REMOTE_IDENTITY_FILE=...] \
       [REMOTE_PROXY_JUMP=...] EXPECTED_TARGET_TRIPLE=... SCENARIO=... \
       ./scripts/seed-remote-helper-fixture.sh

Supported scenarios:
  fresh
  legacy_shell
  legacy_binary_version_mismatch
  legacy_binary_digest_mismatch
  legacy_binary_protocol_mismatch
EOF
  exit 2
}

require_env() {
  local name="$1"
  local value="$2"
  if [[ -z "$value" ]]; then
    echo "error: $name is required" >&2
    usage
  fi
}

require_target_for_binary_scenarios() {
  case "$SCENARIO" in
    legacy_binary_*)
      require_env "EXPECTED_TARGET_TRIPLE" "$EXPECTED_TARGET_TRIPLE"
      ;;
  esac
}

require_numeric_port() {
  if [[ ! "$REMOTE_PORT" =~ ^[0-9]+$ ]]; then
    echo "error: REMOTE_PORT must be an integer, got '$REMOTE_PORT'" >&2
    exit 1
  fi
}

build_ssh_args() {
  SSH_ARGS=()
  if [[ -n "$REMOTE_PORT" ]]; then
    SSH_ARGS+=("-p" "$REMOTE_PORT")
  fi
  if [[ -n "$REMOTE_IDENTITY_FILE" ]]; then
    if [[ ! -f "$REMOTE_IDENTITY_FILE" ]]; then
      echo "error: REMOTE_IDENTITY_FILE not found: $REMOTE_IDENTITY_FILE" >&2
      exit 1
    fi
    SSH_ARGS+=("-i" "$REMOTE_IDENTITY_FILE")
  fi
  if [[ -n "$REMOTE_PROXY_JUMP" ]]; then
    SSH_ARGS+=("-J" "$REMOTE_PROXY_JUMP")
  fi
}

run_remote() {
  local command="$1"
  # shellcheck disable=SC2029
  ssh "${SSH_ARGS[@]}" "${REMOTE_USER}@${REMOTE_HOST}" "$command"
}

install_remote_fixture() {
  local source_path="$1"
  local destination_path="$2"
  local mode="$3"
  # shellcheck disable=SC2029
  ssh "${SSH_ARGS[@]}" "${REMOTE_USER}@${REMOTE_HOST}" \
    "umask 077; mkdir -p \"\$(dirname ${destination_path})\"; cat > ${destination_path}; chmod ${mode} ${destination_path}" \
    <"$source_path"
}

install_remote_metadata() {
  local body="$1"
  # shellcheck disable=SC2029
  printf '%s' "$body" | ssh "${SSH_ARGS[@]}" "${REMOTE_USER}@${REMOTE_HOST}" \
    "umask 077; mkdir -p \"\$(dirname ${REMOTE_METADATA_PATH})\"; cat > ${REMOTE_METADATA_PATH}; chmod 600 ${REMOTE_METADATA_PATH}"
}

remove_remote_fixture() {
  run_remote "rm -f ${REMOTE_HELPER_PATH} ${REMOTE_METADATA_PATH}"
}

write_binary_metadata() {
  local version="$1"
  local protocol_version="$2"
  local artifact_sha="$3"
  cat <<EOF
version=${version}
protocol_version=${protocol_version}
controller_id=legacy-binary-fixture
target_triple=${EXPECTED_TARGET_TRIPLE}
artifact_source=bundle_relative
artifact_sha256=${artifact_sha}
missing_dependencies=
healthy=true
EOF
}

main() {
  require_env "REMOTE_HOST" "$REMOTE_HOST"
  require_env "REMOTE_USER" "$REMOTE_USER"
  require_numeric_port

  case "$SCENARIO" in
    fresh|legacy_shell|legacy_binary_version_mismatch|legacy_binary_digest_mismatch|legacy_binary_protocol_mismatch)
      ;;
    *)
      echo "error: unsupported SCENARIO '$SCENARIO'" >&2
      usage
      ;;
  esac

  require_target_for_binary_scenarios
  build_ssh_args

  case "$SCENARIO" in
    fresh)
      echo "Seeding remote helper scenario: fresh"
      remove_remote_fixture
      ;;
    legacy_shell)
      echo "Seeding remote helper scenario: legacy_shell"
      install_remote_fixture \
        "$ROOT_DIR/scripts/fixtures/remote-helper/legacy-shell-helper.sh" \
        "$REMOTE_HELPER_PATH" \
        700
      run_remote "rm -f ${REMOTE_METADATA_PATH}"
      ;;
    legacy_binary_version_mismatch)
      echo "Seeding remote helper scenario: legacy_binary_version_mismatch"
      install_remote_fixture \
        "$ROOT_DIR/scripts/fixtures/remote-helper/legacy-binary-helper.sh" \
        "$REMOTE_HELPER_PATH" \
        700
      install_remote_metadata "$(write_binary_metadata "pnevma-remote-helper/${EXPECTED_PACKAGE_VERSION}-legacy" "$EXPECTED_PROTOCOL_VERSION" "$EXPECTED_ARTIFACT_SHA")"
      ;;
    legacy_binary_digest_mismatch)
      echo "Seeding remote helper scenario: legacy_binary_digest_mismatch"
      install_remote_fixture \
        "$ROOT_DIR/scripts/fixtures/remote-helper/legacy-binary-helper.sh" \
        "$REMOTE_HELPER_PATH" \
        700
      install_remote_metadata "$(write_binary_metadata "pnevma-remote-helper/${EXPECTED_PACKAGE_VERSION}" "$EXPECTED_PROTOCOL_VERSION" "digest-mismatch-${EXPECTED_ARTIFACT_SHA}")"
      ;;
    legacy_binary_protocol_mismatch)
      echo "Seeding remote helper scenario: legacy_binary_protocol_mismatch"
      install_remote_fixture \
        "$ROOT_DIR/scripts/fixtures/remote-helper/legacy-binary-helper.sh" \
        "$REMOTE_HELPER_PATH" \
        700
      install_remote_metadata "$(write_binary_metadata "pnevma-remote-helper/${EXPECTED_PACKAGE_VERSION}" "999" "$EXPECTED_ARTIFACT_SHA")"
      ;;
  esac
}

main "$@"
