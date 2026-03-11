#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GHOSTTY_DIR="${GHOSTTY_DIR:-$ROOT_DIR/vendor/ghostty}"
GHOSTTY_REPO_URL="${GHOSTTY_REPO_URL:-https://github.com/ghostty-org/ghostty.git}"
GHOSTTY_REF="${GHOSTTY_REF:-v1.2.0}"
GHOSTTY_COMMIT="${GHOSTTY_COMMIT:-3e38e284ca593b601fb70e877c3155fedf42e2e5}"
PATCH_DIR="$ROOT_DIR/patches/ghostty"

fail() {
  echo "error: $*" >&2
  exit 1
}

working_tree_dirty() {
  ! git -C "$GHOSTTY_DIR" diff --quiet --ignore-submodules --no-ext-diff ||
    ! git -C "$GHOSTTY_DIR" diff --cached --quiet --ignore-submodules --no-ext-diff
}

patch_touched_files() {
  if [[ ! -d "$PATCH_DIR" ]]; then
    return
  fi

  local patch
  for patch in "$PATCH_DIR"/*.patch; do
    [[ -e "$patch" ]] || continue
    awk '/^\+\+\+ b\// { path=substr($0, 7); if (path != "/dev/null") print path }' "$patch"
  done | sort -u
}

dirty_tree_matches_expected_patches() {
  patches_already_applied || return 1

  local expected_paths tracked_paths untracked_paths
  expected_paths="$(patch_touched_files)"
  [[ -n "$expected_paths" ]] || return 1

  tracked_paths="$(
    {
      git -C "$GHOSTTY_DIR" diff --name-only --ignore-submodules --no-ext-diff
      git -C "$GHOSTTY_DIR" diff --cached --name-only --ignore-submodules --no-ext-diff
    } | sed '/^$/d' | sort -u
  )"
  untracked_paths="$(git -C "$GHOSTTY_DIR" ls-files --others --exclude-standard | sort -u)"

  [[ -z "$untracked_paths" ]] || return 1
  [[ "$tracked_paths" == "$expected_paths" ]]
}

fetch_expected_refs() {
  if git -C "$GHOSTTY_DIR" ls-remote --exit-code --tags origin "refs/tags/$GHOSTTY_REF" >/dev/null 2>&1; then
    git -C "$GHOSTTY_DIR" fetch origin \
      "$GHOSTTY_COMMIT" \
      "refs/tags/$GHOSTTY_REF:refs/tags/$GHOSTTY_REF"
  else
    git -C "$GHOSTTY_DIR" fetch origin "$GHOSTTY_REF" "$GHOSTTY_COMMIT"
  fi
}

verify_ref_provenance() {
  local resolved_commit
  resolved_commit="$(git -C "$GHOSTTY_DIR" rev-list -n 1 "$GHOSTTY_REF" 2>/dev/null || true)"
  [[ -n "$resolved_commit" ]] || fail "unable to resolve $GHOSTTY_REF from $GHOSTTY_REPO_URL"
  [[ "$resolved_commit" == "$GHOSTTY_COMMIT" ]] || fail \
    "Ghostty ref $GHOSTTY_REF resolved to $resolved_commit, expected $GHOSTTY_COMMIT"
}

verify_checkout_commit() {
  local stage="$1"
  local actual_commit
  actual_commit="$(git -C "$GHOSTTY_DIR" rev-parse HEAD 2>/dev/null || true)"
  [[ "$actual_commit" == "$GHOSTTY_COMMIT" ]] || fail \
    "$stage: Ghostty checkout is $actual_commit, expected $GHOSTTY_COMMIT"
}

patches_already_applied() {
  if [[ ! -d "$PATCH_DIR" ]]; then
    return 0
  fi

  local patch
  for patch in "$PATCH_DIR"/*.patch; do
    [[ -e "$patch" ]] || continue
    if ! git -C "$GHOSTTY_DIR" apply --reverse --check "$patch" >/dev/null 2>&1; then
      return 1
    fi
  done

  return 0
}

apply_local_patches() {
  if [[ ! -d "$PATCH_DIR" ]]; then
    return
  fi

  local patch
  for patch in "$PATCH_DIR"/*.patch; do
    [[ -e "$patch" ]] || continue

    if git -C "$GHOSTTY_DIR" apply --reverse --check "$patch" >/dev/null 2>&1; then
      continue
    fi

    git -C "$GHOSTTY_DIR" apply "$patch"
  done
}

checkout_expected_base() {
  if working_tree_dirty; then
    fail "unexpected local changes in $GHOSTTY_DIR; clean the vendor checkout before refetching"
  fi

  git -C "$GHOSTTY_DIR" checkout --detach "$GHOSTTY_COMMIT"
  verify_checkout_commit "base checkout"
}

if [[ ! -d "$GHOSTTY_DIR/.git" ]]; then
  mkdir -p "$(dirname "$GHOSTTY_DIR")"
  git clone --no-checkout "$GHOSTTY_REPO_URL" "$GHOSTTY_DIR"
fi

fetch_expected_refs
verify_ref_provenance

if [[ "$(git -C "$GHOSTTY_DIR" rev-parse HEAD 2>/dev/null || true)" == "$GHOSTTY_COMMIT" ]] &&
  patches_already_applied; then
  if ! working_tree_dirty || dirty_tree_matches_expected_patches; then
    verify_checkout_commit "existing patched checkout"
    exit 0
  fi
fi

checkout_expected_base
apply_local_patches
verify_checkout_commit "post-patch checkout"
