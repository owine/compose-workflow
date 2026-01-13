#!/usr/bin/env bash
# Script Name: detect-stack-changes.sh
# Purpose: Detect removed, existing, and new Docker Compose stacks using multiple detection methods
# Usage: ./detect-stack-changes.sh --current-sha abc123 --target-ref main --input-stacks '["stack1"]' --removed-files '[]' --ssh-user user --ssh-host host

set -euo pipefail

# Get script directory and source libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ssh-helpers.sh
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/ssh-helpers.sh"
source "$SCRIPT_DIR/lib/common.sh"

# Default values
CURRENT_SHA=""
TARGET_REF=""
INPUT_STACKS="[]"
REMOVED_FILES="[]"
SSH_USER=""
SSH_HOST=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --current-sha)
      CURRENT_SHA="$2"
      shift 2
      ;;
    --target-ref)
      TARGET_REF="$2"
      shift 2
      ;;
    --input-stacks)
      INPUT_STACKS="$2"
      shift 2
      ;;
    --removed-files)
      REMOVED_FILES="$2"
      shift 2
      ;;
    --ssh-user)
      SSH_USER="$2"
      shift 2
      ;;
    --ssh-host)
      SSH_HOST="$2"
      shift 2
      ;;
    *)
      log_error "Unknown argument: $1"
      exit 1
      ;;
  esac
done

# Validate required arguments
require_var CURRENT_SHA || exit 1
require_var TARGET_REF || exit 1
require_var INPUT_STACKS || exit 1
require_var SSH_USER || exit 1
require_var SSH_HOST || exit 1

# Parse input stacks JSON to space-delimited list
INPUT_STACKS_LIST=$(echo "$INPUT_STACKS" | jq -r '.[]' | tr '\n' ' ')
log_info "Input stacks: $INPUT_STACKS_LIST"

# Skip detection if this is the first deployment
if [ "$CURRENT_SHA" = "unknown" ]; then
  log_info "First deployment detected - all input stacks are new"

  # All input stacks are new, no removed or existing stacks
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

# === DETECTION FUNCTION: GIT DIFF (REMOVED) ===
detect_removed_stacks_gitdiff() {
  local current_sha="$1"
  local target_ref="$2"

  log_info "Running git diff detection for removed stacks..."

  local detect_script
  detect_script=$(cat << 'DETECT_EOF'
  set -e
  CURRENT_SHA="$1"
  TARGET_REF="$2"

  cd /opt/compose

  # Fetch target ref to ensure we have it
  if ! git fetch origin "$TARGET_REF" 2>/dev/null; then
    echo "⚠️ Failed to fetch target ref, trying general fetch..." >&2
    if ! git fetch 2>/dev/null; then
      echo "::error::Failed to fetch repository updates" >&2
      exit 1
    fi
  fi

  # Resolve target ref to SHA for comparison
  TARGET_SHA=$(git rev-parse "$TARGET_REF" 2>/dev/null || echo "$TARGET_REF")

  # Validate both SHAs exist
  if ! git cat-file -e "$CURRENT_SHA" 2>/dev/null; then
    echo "::warning::Current SHA $CURRENT_SHA not found in repository (may have been replaced by force-push)" >&2
    exit 1
  fi

  if ! git cat-file -e "$TARGET_SHA" 2>/dev/null; then
    echo "::warning::Target SHA $TARGET_SHA not found in repository" >&2
    exit 1
  fi

  # Find deleted compose.yaml files between current and target
  git diff --diff-filter=D --name-only "$CURRENT_SHA" "$TARGET_SHA" 2>/dev/null | \
    grep -E '^[^/]+/compose\.yaml$' | \
    sed 's|/compose\.yaml||' || echo ""
DETECT_EOF
  )

  echo "$detect_script" | ssh_retry 3 5 "ssh -o \"StrictHostKeyChecking no\" $SSH_USER@$SSH_HOST /bin/bash -s \"$current_sha\" \"$target_ref\""
}

# === DETECTION FUNCTION: TREE COMPARISON (REMOVED) ===
detect_removed_stacks_tree() {
  local target_ref="$1"

  log_info "Running tree comparison detection for removed stacks..."

  local detect_script
  detect_script=$(cat << 'DETECT_TREE_EOF'
  set -e
  TARGET_REF="$1"

  cd /opt/compose

  # Fetch target ref to ensure we have it
  if ! git fetch origin "$TARGET_REF" 2>/dev/null; then
    echo "⚠️ Failed to fetch target ref, trying general fetch..." >&2
    if ! git fetch 2>/dev/null; then
      echo "::error::Failed to fetch repository updates" >&2
      exit 1
    fi
  fi

  # Resolve target ref to SHA
  TARGET_SHA=$(git rev-parse "$TARGET_REF" 2>/dev/null || echo "$TARGET_REF")

  # Validate target SHA exists
  if ! git cat-file -e "$TARGET_SHA" 2>/dev/null; then
    echo "::error::Target SHA $TARGET_SHA not found in repository" >&2
    exit 1
  fi

  # Get directories in target commit (one level deep, directories only)
  COMMIT_DIRS=$(git ls-tree --name-only "$TARGET_SHA" 2>/dev/null | sort)

  # Get directories on server filesystem (exclude .git and hidden dirs)
  SERVER_DIRS=$(find /opt/compose -maxdepth 1 -mindepth 1 -type d ! -name '.*' -exec basename {} \; 2>/dev/null | sort)

  # Find directories on server but not in commit
  MISSING_IN_COMMIT=$(comm -13 <(echo "$COMMIT_DIRS") <(echo "$SERVER_DIRS"))

  # Filter for directories with compose.yaml files
  for dir in $MISSING_IN_COMMIT; do
    if [ -f "/opt/compose/$dir/compose.yaml" ]; then
      echo "$dir"
    fi
  done
DETECT_TREE_EOF
  )

  echo "$detect_script" | ssh_retry 3 5 "ssh -o \"StrictHostKeyChecking no\" $SSH_USER@$SSH_HOST /bin/bash -s \"$target_ref\""
}

# === DETECTION FUNCTION: DISCOVERY ANALYSIS (REMOVED) ===
detect_removed_stacks_discovery() {
  local removed_files_json="$1"

  log_info "Running discovery analysis detection for removed stacks..."

  # Base64 encode JSON to avoid shell glob expansion issues
  local removed_files_b64
  removed_files_b64=$(echo -n "$removed_files_json" | base64 -w 0 2>/dev/null || echo -n "$removed_files_json" | base64)

  local detect_script
  detect_script=$(cat << 'DETECT_DISCOVERY_EOF'
  set -e
  # Decode base64 JSON
  REMOVED_FILES_JSON=$(echo "$1" | base64 -d)

  # Parse JSON array and filter for compose.yaml deletions
  echo "$REMOVED_FILES_JSON" | jq -r '.[]' 2>/dev/null | \
    grep -E '^[^/]+/compose\.yaml$' | \
    sed 's|/compose\.yaml||' || echo ""
DETECT_DISCOVERY_EOF
  )

  echo "$detect_script" | ssh_retry 3 5 "ssh -o \"StrictHostKeyChecking no\" $SSH_USER@$SSH_HOST /bin/bash -s \"$removed_files_b64\""
}

# ================================================================
# NEW STACK DETECTION
# ================================================================

# === DETECTION FUNCTION: GIT DIFF (NEW) ===
detect_new_stacks_gitdiff() {
  local current_sha="$1"
  local target_ref="$2"

  log_info "Running git diff detection for new stacks..."

  local detect_script
  detect_script=$(cat << 'DETECT_NEW_EOF'
  set -e
  CURRENT_SHA="$1"
  TARGET_REF="$2"

  cd /opt/compose

  # Fetch target ref to ensure we have it
  if ! git fetch origin "$TARGET_REF" 2>/dev/null; then
    if ! git fetch 2>/dev/null; then
      echo "::error::Failed to fetch repository updates" >&2
      exit 1
    fi
  fi

  # Resolve target ref to SHA for comparison
  TARGET_SHA=$(git rev-parse "$TARGET_REF" 2>/dev/null || echo "$TARGET_REF")

  # Validate both SHAs exist
  if ! git cat-file -e "$CURRENT_SHA" 2>/dev/null; then
    echo "::warning::Current SHA $CURRENT_SHA not found in repository" >&2
    exit 1
  fi

  if ! git cat-file -e "$TARGET_SHA" 2>/dev/null; then
    echo "::warning::Target SHA $TARGET_SHA not found in repository" >&2
    exit 1
  fi

  # Find added compose.yaml files between current and target
  git diff --diff-filter=A --name-only "$CURRENT_SHA" "$TARGET_SHA" 2>/dev/null | \
    grep -E '^[^/]+/compose\.yaml$' | \
    sed 's|/compose\.yaml||' || echo ""
DETECT_NEW_EOF
  )

  echo "$detect_script" | ssh_retry 3 5 "ssh -o \"StrictHostKeyChecking no\" $SSH_USER@$SSH_HOST /bin/bash -s \"$current_sha\" \"$target_ref\""
}

# === DETECTION FUNCTION: TREE COMPARISON (NEW) ===
detect_new_stacks_tree() {
  local target_ref="$1"

  log_info "Running tree comparison detection for new stacks..."

  local detect_script
  detect_script=$(cat << 'DETECT_NEW_TREE_EOF'
  set -e
  TARGET_REF="$1"

  cd /opt/compose

  # Fetch target ref to ensure we have it
  if ! git fetch origin "$TARGET_REF" 2>/dev/null; then
    if ! git fetch 2>/dev/null; then
      echo "::error::Failed to fetch repository updates" >&2
      exit 1
    fi
  fi

  # Resolve target ref to SHA
  TARGET_SHA=$(git rev-parse "$TARGET_REF" 2>/dev/null || echo "$TARGET_REF")

  # Validate target SHA exists
  if ! git cat-file -e "$TARGET_SHA" 2>/dev/null; then
    echo "::error::Target SHA $TARGET_SHA not found in repository" >&2
    exit 1
  fi

  # Get directories in target commit that have compose.yaml
  COMMIT_STACKS=$(git ls-tree --name-only "$TARGET_SHA" 2>/dev/null | while read -r dir; do
    if git cat-file -e "$TARGET_SHA:$dir/compose.yaml" 2>/dev/null; then
      echo "$dir"
    fi
  done | sort)

  # Get directories on server filesystem with compose.yaml
  SERVER_STACKS=$(find /opt/compose -maxdepth 1 -mindepth 1 -type d ! -name '.*' -exec basename {} \; 2>/dev/null | while read -r dir; do
    if [ -f "/opt/compose/$dir/compose.yaml" ]; then
      echo "$dir"
    fi
  done | sort)

  # Find directories in commit but not on server
  comm -23 <(echo "$COMMIT_STACKS") <(echo "$SERVER_STACKS")
DETECT_NEW_TREE_EOF
  )

  echo "$detect_script" | ssh_retry 3 5 "ssh -o \"StrictHostKeyChecking no\" $SSH_USER@$SSH_HOST /bin/bash -s \"$target_ref\""
}

# === DETECTION FUNCTION: INPUT FILTER (NEW) ===
detect_new_stacks_input() {
  local input_stacks="$1"

  log_info "Running input filter detection for new stacks..."

  # Get currently deployed stacks on server
  local detect_script
  detect_script=$(cat << 'DETECT_INPUT_EOF'
  set -e
  cd /opt/compose

  # Get directories with compose.yaml files
  find /opt/compose -maxdepth 1 -mindepth 1 -type d ! -name '.*' -exec basename {} \; 2>/dev/null | while read -r dir; do
    if [ -f "/opt/compose/$dir/compose.yaml" ]; then
      echo "$dir"
    fi
  done | sort
DETECT_INPUT_EOF
  )

  DEPLOYED_STACKS=$(echo "$detect_script" | ssh_retry 3 5 "ssh -o \"StrictHostKeyChecking no\" $SSH_USER@$SSH_HOST /bin/bash")

  # Filter input stacks - those not in deployed stacks are new
  echo "$input_stacks" | jq -r '.[]' | while read -r stack; do
    if ! echo "$DEPLOYED_STACKS" | grep -q "^${stack}$"; then
      echo "$stack"
    fi
  done
}

# ================================================================
# AGGREGATION FUNCTIONS
# ================================================================

aggregate_stacks() {
  local method1="$1"
  local method2="$2"
  local method3="$3"

  # Concatenate all lists, remove empty lines, sort and deduplicate
  {
    echo "$method1"
    echo "$method2"
    echo "$method3"
  } | \
    grep -v '^$' | \
    sort -u | \
    grep -E '^[a-zA-Z0-9_-]+$' || echo ""
}

# ================================================================
# MAIN EXECUTION
# ================================================================

log_info "Running detection methods for all stack categories..."

# Execute removed stack detection
REMOVED_GITDIFF_EXIT=0
REMOVED_TREE_EXIT=0
REMOVED_DISCOVERY_EXIT=0

REMOVED_GITDIFF=$(detect_removed_stacks_gitdiff "$CURRENT_SHA" "$TARGET_REF") || REMOVED_GITDIFF_EXIT=$?
REMOVED_TREE=$(detect_removed_stacks_tree "$TARGET_REF") || REMOVED_TREE_EXIT=$?

if [ "$REMOVED_FILES" = "[]" ] || [ -z "$REMOVED_FILES" ]; then
  log_info "No removed files detected - skipping removed discovery analysis"
  REMOVED_DISCOVERY=""
  REMOVED_DISCOVERY_EXIT=0
else
  REMOVED_DISCOVERY=$(detect_removed_stacks_discovery "$REMOVED_FILES") || REMOVED_DISCOVERY_EXIT=$?
fi

# Execute new stack detection
NEW_GITDIFF_EXIT=0
NEW_TREE_EXIT=0
NEW_INPUT_EXIT=0

NEW_GITDIFF=$(detect_new_stacks_gitdiff "$CURRENT_SHA" "$TARGET_REF") || NEW_GITDIFF_EXIT=$?
NEW_TREE=$(detect_new_stacks_tree "$TARGET_REF") || NEW_TREE_EXIT=$?
NEW_INPUT=$(detect_new_stacks_input "$INPUT_STACKS") || NEW_INPUT_EXIT=$?

# Fail deployment if any detection method failed (fail-safe)
if [ "$REMOVED_GITDIFF_EXIT" -ne 0 ] || [ "$REMOVED_TREE_EXIT" -ne 0 ] || [ "$REMOVED_DISCOVERY_EXIT" -ne 0 ]; then
  log_error "Removed stack detection failed"
  exit 1
fi

if [ "$NEW_GITDIFF_EXIT" -ne 0 ] || [ "$NEW_TREE_EXIT" -ne 0 ] || [ "$NEW_INPUT_EXIT" -ne 0 ]; then
  log_error "New stack detection failed"
  exit 1
fi

log_success "All detection methods completed successfully"

# Aggregate results
log_info "Aggregating results..."
REMOVED_STACKS=$(aggregate_stacks "$REMOVED_GITDIFF" "$REMOVED_TREE" "$REMOVED_DISCOVERY")
NEW_STACKS=$(aggregate_stacks "$NEW_GITDIFF" "$NEW_TREE" "$NEW_INPUT")

# Determine existing stacks (input stacks that aren't new)
EXISTING_STACKS=$(echo "$INPUT_STACKS" | jq -r '.[]' | while read -r stack; do
  if ! echo "$NEW_STACKS" | grep -q "^${stack}$"; then
    echo "$stack"
  fi
done)

# Debug logging
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

# Convert to JSON arrays
REMOVED_JSON=$(if [ -n "$REMOVED_STACKS" ]; then echo "$REMOVED_STACKS" | jq -R -s -c 'split("\n") | map(select(length > 0))'; else echo "[]"; fi)
EXISTING_JSON=$(if [ -n "$EXISTING_STACKS" ]; then echo "$EXISTING_STACKS" | jq -R -s -c 'split("\n") | map(select(length > 0))'; else echo "[]"; fi)
NEW_JSON=$(if [ -n "$NEW_STACKS" ]; then echo "$NEW_STACKS" | jq -R -s -c 'split("\n") | map(select(length > 0))'; else echo "[]"; fi)

# Output results
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

# Cleanup removed stacks if any
if [ -n "$REMOVED_STACKS" ]; then
  log_info "Cleaning up removed stacks..."
  CLEANUP_FAILED=false

  while IFS= read -r stack; do
    [ -z "$stack" ] && continue

    log_info "Cleaning up stack: $stack"

    if ! "$SCRIPT_DIR/cleanup-stack.sh" \
      --stack-name "$stack" \
      --ssh-user "$SSH_USER" \
      --ssh-host "$SSH_HOST"; then
      log_error "Cleanup failed for stack: $stack"
      CLEANUP_FAILED=true
      break
    fi
  done <<< "$REMOVED_STACKS"

  if [ "$CLEANUP_FAILED" = "true" ]; then
    log_error "Stack cleanup failed - stopping deployment"
    exit 1
  fi

  log_success "All removed stacks cleaned successfully"
fi

log_success "Stack change detection completed"
exit 0
