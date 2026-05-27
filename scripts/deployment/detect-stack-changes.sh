#!/usr/bin/env bash
# Script Name: detect-stack-changes.sh
# Purpose: Detect removed, existing, and new Docker Compose stacks using multiple detection methods
# Usage: ./detect-stack-changes.sh \
#          --current-sha <sha> --target-ref <ref> \
#          --input-stacks '["stack1","stack2"]' \
#          --removed-files '[]' \
#          --live-repo-path <path>
#
# All git/filesystem ops execute locally against $LIVE_REPO_PATH on the
# runner host.
#
# Cleanup of removed stacks is the *workflow's* responsibility — deploy.yml
# has a dedicated `Teardown removed stacks` step that uses the
# has_removed_stacks output. This script only emits classifications, it does
# not execute teardown.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

CURRENT_SHA=""
TARGET_REF=""
INPUT_STACKS="[]"
REMOVED_FILES="[]"
ADDED_FILES="[]"
LIVE_REPO_PATH="${LIVE_REPO_PATH:-}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --current-sha)      CURRENT_SHA="$2"; shift 2 ;;
    --target-ref)       TARGET_REF="$2"; shift 2 ;;
    --input-stacks)     INPUT_STACKS="$2"; shift 2 ;;
    --removed-files)    REMOVED_FILES="$2"; shift 2 ;;
    --added-files)      ADDED_FILES="$2"; shift 2 ;;
    --live-repo-path)   LIVE_REPO_PATH="$2"; shift 2 ;;
    *)
      log_error "Unknown argument: $1"
      exit 1
      ;;
  esac
done

require_var CURRENT_SHA || exit 1
require_var TARGET_REF || exit 1
require_var INPUT_STACKS || exit 1
if [[ -z "$LIVE_REPO_PATH" ]]; then
  log_error "--live-repo-path (or LIVE_REPO_PATH env) is required"
  exit 1
fi

# HELPER_FUNCS: shared bash helpers prepended into each detector's heredoc body.
# Defined once script-side so the same logic powers all six detectors without
# duplicating the function bodies inside each heredoc.
# shellcheck disable=SC2016  # single quotes intentional - body is injected into a subshell heredoc verbatim
HELPER_FUNCS='
is_effectively_present_at_sha() {
  local sha="$1" stack="$2"
  git cat-file -e "$sha:$stack/compose.yaml" 2>/dev/null || return 1
  if git cat-file -e "$sha:$stack/.disabled" 2>/dev/null; then
    return 1
  fi
  return 0
}
is_effectively_present_on_disk() {
  local root="$1" stack="$2"
  [[ -f "$root/$stack/compose.yaml" ]] || return 1
  [[ ! -f "$root/$stack/.disabled" ]]
}
'

# run_local: dispatches a bash script body (stdin) with LIVE_REPO_PATH
# propagated as an env var, so heredoc bodies can reference "$LIVE_REPO_PATH"
# without the parent needing to interpolate it.
run_local() {
  if [[ $# -gt 0 ]]; then
    LIVE_REPO_PATH="$LIVE_REPO_PATH" bash -s "$@"
  else
    LIVE_REPO_PATH="$LIVE_REPO_PATH" bash -s
  fi
}

INPUT_STACKS_LIST=$(echo "$INPUT_STACKS" | jq -r '.[]' | tr '\n' ' ')
log_info "Input stacks: $INPUT_STACKS_LIST"

# First-deployment shortcut: nothing to compare against, all input stacks are new.
if [ "$CURRENT_SHA" = "unknown" ]; then
  log_info "First deployment detected - all input stacks are new"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
      echo "removed_stacks=[]"
      echo "existing_stacks=[]"
      echo "new_stacks=$INPUT_STACKS"
      echo "has_removed_stacks=false"
      echo "has_existing_stacks=false"
      echo "has_new_stacks=true"
    } >> "$GITHUB_OUTPUT"
  fi
  exit 0
fi

log_info "Detecting stack changes..."
log_info "Current SHA: $CURRENT_SHA"
log_info "Target ref: $TARGET_REF"

# ================================================================
# REMOVED STACK DETECTION
# ================================================================

detect_removed_stacks_gitdiff() {
  local current_sha="$1" target_ref="$2"
  log_info "Running git diff detection for removed stacks..."

  local detect_script
  detect_script="$HELPER_FUNCS"$'\n'"$(cat << 'DETECT_EOF'
  set -e
  CURRENT_SHA="$1"
  TARGET_REF="$2"

  cd "$LIVE_REPO_PATH"

  if ! git fetch origin "$TARGET_REF" 2>/dev/null; then
    echo "⚠️ Failed to fetch target ref, trying general fetch..." >&2
    if ! git fetch 2>/dev/null; then
      echo "::error::Failed to fetch repository updates" >&2
      exit 1
    fi
  fi

  TARGET_SHA=$(git rev-parse "$TARGET_REF" 2>/dev/null || echo "$TARGET_REF")

  if ! git cat-file -e "$CURRENT_SHA" 2>/dev/null; then
    echo "::warning::Current SHA $CURRENT_SHA not found in repository (may have been replaced by force-push)" >&2
    exit 1
  fi

  if ! git cat-file -e "$TARGET_SHA" 2>/dev/null; then
    echo "::warning::Target SHA $TARGET_SHA not found in repository" >&2
    exit 1
  fi

  {
    git diff --diff-filter=D --name-only "$CURRENT_SHA" "$TARGET_SHA" 2>/dev/null \
      | grep -E '^[^/]+/compose\.yaml$' | sed 's|/compose\.yaml||' || true
    git diff --diff-filter=A --name-only "$CURRENT_SHA" "$TARGET_SHA" 2>/dev/null \
      | grep -E '^[^/]+/\.disabled$' | sed 's|/\.disabled||' || true
  } | sort -u | while read -r candidate; do
    [[ -z "$candidate" ]] && continue
    if is_effectively_present_at_sha "$CURRENT_SHA" "$candidate"; then
      echo "$candidate"
    fi
  done
DETECT_EOF
)"

  echo "$detect_script" | run_local "$current_sha" "$target_ref"
}

detect_removed_stacks_tree() {
  local target_ref="$1"
  log_info "Running tree comparison detection for removed stacks..."

  local detect_script
  detect_script="$HELPER_FUNCS"$'\n'"$(cat << 'DETECT_TREE_EOF'
  set -e
  TARGET_REF="$1"

  cd "$LIVE_REPO_PATH"

  if ! git fetch origin "$TARGET_REF" 2>/dev/null; then
    echo "⚠️ Failed to fetch target ref, trying general fetch..." >&2
    if ! git fetch 2>/dev/null; then
      echo "::error::Failed to fetch repository updates" >&2
      exit 1
    fi
  fi

  TARGET_SHA=$(git rev-parse "$TARGET_REF" 2>/dev/null || echo "$TARGET_REF")

  if ! git cat-file -e "$TARGET_SHA" 2>/dev/null; then
    echo "::error::Target SHA $TARGET_SHA not found in repository" >&2
    exit 1
  fi

  ALL_DIRS=$( {
    git ls-tree --name-only "$TARGET_SHA" 2>/dev/null
    find "$LIVE_REPO_PATH" -maxdepth 1 -mindepth 1 -type d ! -name '.*' -exec basename {} \;
  } | sort -u )

  for dir in $ALL_DIRS; do
    if is_effectively_present_on_disk "$LIVE_REPO_PATH" "$dir" \
       && ! is_effectively_present_at_sha "$TARGET_SHA" "$dir"; then
      echo "$dir"
    fi
  done
DETECT_TREE_EOF
)"

  echo "$detect_script" | run_local "$target_ref"
}

detect_removed_stacks_discovery() {
  local removed_files_json="$1" added_files_json="$2" current_sha="$3"
  log_info "Running discovery analysis detection for removed stacks..."
  local removed_b64 added_b64
  removed_b64=$(echo -n "$removed_files_json" | base64 -w 0 2>/dev/null || echo -n "$removed_files_json" | base64)
  added_b64=$(echo -n "$added_files_json" | base64 -w 0 2>/dev/null || echo -n "$added_files_json" | base64)

  local detect_script
  detect_script="$HELPER_FUNCS"$'\n'"$(cat << 'DETECT_DISCOVERY_EOF'
  set -e
  CURRENT_SHA="$3"
  REMOVED_JSON=$(echo "$1" | base64 -d)
  ADDED_JSON=$(echo "$2" | base64 -d)
  cd "$LIVE_REPO_PATH"
  {
    echo "$REMOVED_JSON" | jq -r '.[]?' | grep -E '^[^/]+/compose\.yaml$' | sed 's|/compose\.yaml||' || true
    echo "$ADDED_JSON"   | jq -r '.[]?' | grep -E '^[^/]+/\.disabled$'    | sed 's|/\.disabled||'    || true
  } | sort -u | while read -r candidate; do
    [[ -z "$candidate" ]] && continue
    if is_effectively_present_at_sha "$CURRENT_SHA" "$candidate"; then
      echo "$candidate"
    fi
  done
DETECT_DISCOVERY_EOF
)"
  echo "$detect_script" | run_local "$removed_b64" "$added_b64" "$current_sha"
}

# ================================================================
# NEW STACK DETECTION
# ================================================================

detect_new_stacks_gitdiff() {
  local current_sha="$1" target_ref="$2"
  log_info "Running git diff detection for new stacks..."

  local detect_script
  detect_script="$HELPER_FUNCS"$'\n'"$(cat << 'DETECT_NEW_EOF'
  set -e
  CURRENT_SHA="$1"
  TARGET_REF="$2"

  cd "$LIVE_REPO_PATH"

  if ! git fetch origin "$TARGET_REF" 2>/dev/null; then
    if ! git fetch 2>/dev/null; then
      echo "::error::Failed to fetch repository updates" >&2
      exit 1
    fi
  fi

  TARGET_SHA=$(git rev-parse "$TARGET_REF" 2>/dev/null || echo "$TARGET_REF")

  if ! git cat-file -e "$CURRENT_SHA" 2>/dev/null; then
    echo "::warning::Current SHA $CURRENT_SHA not found in repository" >&2
    exit 1
  fi

  if ! git cat-file -e "$TARGET_SHA" 2>/dev/null; then
    echo "::warning::Target SHA $TARGET_SHA not found in repository" >&2
    exit 1
  fi

  git diff --diff-filter=A --name-only "$CURRENT_SHA" "$TARGET_SHA" 2>/dev/null | \
    grep -E '^[^/]+/compose\.yaml$' | \
    sed 's|/compose\.yaml||' || echo ""
DETECT_NEW_EOF
)"

  echo "$detect_script" | run_local "$current_sha" "$target_ref"
}

detect_new_stacks_tree() {
  local target_ref="$1"
  log_info "Running tree comparison detection for new stacks..."

  local detect_script
  detect_script="$HELPER_FUNCS"$'\n'"$(cat << 'DETECT_NEW_TREE_EOF'
  set -e
  TARGET_REF="$1"

  cd "$LIVE_REPO_PATH"

  if ! git fetch origin "$TARGET_REF" 2>/dev/null; then
    if ! git fetch 2>/dev/null; then
      echo "::error::Failed to fetch repository updates" >&2
      exit 1
    fi
  fi

  TARGET_SHA=$(git rev-parse "$TARGET_REF" 2>/dev/null || echo "$TARGET_REF")

  if ! git cat-file -e "$TARGET_SHA" 2>/dev/null; then
    echo "::error::Target SHA $TARGET_SHA not found in repository" >&2
    exit 1
  fi

  COMMIT_STACKS=$(git ls-tree --name-only "$TARGET_SHA" 2>/dev/null | while read -r dir; do
    if git cat-file -e "$TARGET_SHA:$dir/compose.yaml" 2>/dev/null; then
      echo "$dir"
    fi
  done | sort)

  SERVER_STACKS=$(find "$LIVE_REPO_PATH" -maxdepth 1 -mindepth 1 -type d ! -name '.*' -exec basename {} \; 2>/dev/null | while read -r dir; do
    if [ -f "$LIVE_REPO_PATH/$dir/compose.yaml" ]; then
      echo "$dir"
    fi
  done | sort)

  comm -23 <(echo "$COMMIT_STACKS") <(echo "$SERVER_STACKS")
DETECT_NEW_TREE_EOF
)"

  echo "$detect_script" | run_local "$target_ref"
}

detect_new_stacks_input() {
  local input_stacks="$1"
  log_info "Running input filter detection for new stacks..."

  local detect_script
  detect_script=$(cat << 'DETECT_INPUT_EOF'
  set -e
  cd "$LIVE_REPO_PATH"
  find "$LIVE_REPO_PATH" -maxdepth 1 -mindepth 1 -type d ! -name '.*' -exec basename {} \; 2>/dev/null | while read -r dir; do
    if [ -f "$LIVE_REPO_PATH/$dir/compose.yaml" ]; then
      echo "$dir"
    fi
  done | sort
DETECT_INPUT_EOF
  )

  DEPLOYED_STACKS=$(echo "$detect_script" | run_local)

  echo "$input_stacks" | jq -r '.[]' | while read -r stack; do
    if ! echo "$DEPLOYED_STACKS" | grep -q "^${stack}$"; then
      echo "$stack"
    fi
  done
}

# ================================================================
# AGGREGATION
# ================================================================

aggregate_stacks() {
  local method1="$1" method2="$2" method3="$3"
  {
    echo "$method1"
    echo "$method2"
    echo "$method3"
  } | grep -v '^$' | sort -u | grep -E '^[a-zA-Z0-9_-]+$' || echo ""
}

# ================================================================
# MAIN
# ================================================================

log_info "Running detection methods for all stack categories..."

REMOVED_GITDIFF_EXIT=0
REMOVED_TREE_EXIT=0
REMOVED_DISCOVERY_EXIT=0
REMOVED_GITDIFF=$(detect_removed_stacks_gitdiff "$CURRENT_SHA" "$TARGET_REF") || REMOVED_GITDIFF_EXIT=$?
REMOVED_TREE=$(detect_removed_stacks_tree "$TARGET_REF") || REMOVED_TREE_EXIT=$?

REMOVED_DISCOVERY=$(detect_removed_stacks_discovery "$REMOVED_FILES" "$ADDED_FILES" "$CURRENT_SHA") || REMOVED_DISCOVERY_EXIT=$?

NEW_GITDIFF_EXIT=0
NEW_TREE_EXIT=0
NEW_INPUT_EXIT=0
NEW_GITDIFF=$(detect_new_stacks_gitdiff "$CURRENT_SHA" "$TARGET_REF") || NEW_GITDIFF_EXIT=$?
NEW_TREE=$(detect_new_stacks_tree "$TARGET_REF") || NEW_TREE_EXIT=$?
NEW_INPUT=$(detect_new_stacks_input "$INPUT_STACKS") || NEW_INPUT_EXIT=$?

# Fail-safe: any detection error aborts the deploy.
if [ "$REMOVED_GITDIFF_EXIT" -ne 0 ] || [ "$REMOVED_TREE_EXIT" -ne 0 ] || [ "$REMOVED_DISCOVERY_EXIT" -ne 0 ]; then
  log_error "Removed stack detection failed"
  exit 1
fi
if [ "$NEW_GITDIFF_EXIT" -ne 0 ] || [ "$NEW_TREE_EXIT" -ne 0 ] || [ "$NEW_INPUT_EXIT" -ne 0 ]; then
  log_error "New stack detection failed"
  exit 1
fi

log_success "All detection methods completed successfully"

log_info "Aggregating results..."
REMOVED_STACKS=$(aggregate_stacks "$REMOVED_GITDIFF" "$REMOVED_TREE" "$REMOVED_DISCOVERY")
NEW_STACKS=$(aggregate_stacks "$NEW_GITDIFF" "$NEW_TREE" "$NEW_INPUT")

EXISTING_STACKS=$(echo "$INPUT_STACKS" | jq -r '.[]' | while read -r stack; do
  if ! echo "$NEW_STACKS" | grep -q "^${stack}$"; then
    echo "$stack"
  fi
done)

echo ""
log_info "Detection Results:"
if [ -n "$REMOVED_STACKS" ]; then
  echo "  🗑️  Removed: $(echo "$REMOVED_STACKS" | tr '\n' ', ' | sed 's/,$//')"
else
  echo "  🗑️  Removed: none"
fi
if [ -n "$EXISTING_STACKS" ]; then
  echo "  🔄 Existing: $(echo "$EXISTING_STACKS" | tr '\n' ', ' | sed 's/,$//')"
else
  echo "  🔄 Existing: none"
fi
if [ -n "$NEW_STACKS" ]; then
  echo "  ✨ New: $(echo "$NEW_STACKS" | tr '\n' ', ' | sed 's/,$//')"
else
  echo "  ✨ New: none"
fi
echo ""

REMOVED_JSON=$(if [ -n "$REMOVED_STACKS" ]; then echo "$REMOVED_STACKS" | jq -R -s -c 'split("\n") | map(select(length > 0))'; else echo "[]"; fi)
EXISTING_JSON=$(if [ -n "$EXISTING_STACKS" ]; then echo "$EXISTING_STACKS" | jq -R -s -c 'split("\n") | map(select(length > 0))'; else echo "[]"; fi)
NEW_JSON=$(if [ -n "$NEW_STACKS" ]; then echo "$NEW_STACKS" | jq -R -s -c 'split("\n") | map(select(length > 0))'; else echo "[]"; fi)

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "removed_stacks=$REMOVED_JSON"
    echo "existing_stacks=$EXISTING_JSON"
    echo "new_stacks=$NEW_JSON"
    echo "has_removed_stacks=$([ -n "$REMOVED_STACKS" ] && echo "true" || echo "false")"
    echo "has_existing_stacks=$([ -n "$EXISTING_STACKS" ] && echo "true" || echo "false")"
    echo "has_new_stacks=$([ -n "$NEW_STACKS" ] && echo "true" || echo "false")"
  } >> "$GITHUB_OUTPUT"
fi

log_success "Stack change detection completed"
exit 0
