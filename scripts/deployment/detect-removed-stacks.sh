#!/usr/bin/env bash
# Script Name: detect-removed-stacks.sh
# Purpose: Detect and clean up removed Docker Compose stacks using three detection methods
# Usage: ./detect-removed-stacks.sh --current-sha abc123 --target-ref main --deleted-files '[]' --ssh-user user --ssh-host host --op-token token

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
DELETED_FILES="[]"
SSH_USER=""
SSH_HOST=""
OP_TOKEN=""

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
    --deleted-files)
      DELETED_FILES="$2"
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
    --op-token)
      OP_TOKEN="$2"
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
require_var SSH_USER || exit 1
require_var SSH_HOST || exit 1
require_var OP_TOKEN || exit 1

# Skip detection if this is the first deployment
if [ "$CURRENT_SHA" = "unknown" ]; then
  log_info "First deployment detected - no previous stacks to remove"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "removed_stacks=" >> "$GITHUB_OUTPUT"
    echo "has_removed_stacks=false" >> "$GITHUB_OUTPUT"
  fi
  exit 0
fi

log_info "Detecting removed stacks..."
log_info "Current SHA: $CURRENT_SHA"
log_info "Target ref: $TARGET_REF"

# === DETECTION FUNCTION: GIT DIFF ===
# Purpose: Detect stacks removed between two git commits
detect_removed_stacks_gitdiff() {
  local current_sha="$1"
  local target_ref="$2"

  log_info "Running git diff detection..."

  # Build detection script
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
    echo "     Skipping git diff detection, will rely on tree comparison method" >&2
    exit 1
  fi

  if ! git cat-file -e "$TARGET_SHA" 2>/dev/null; then
    echo "::warning::Target SHA $TARGET_SHA not found in repository" >&2
    echo "     Skipping git diff detection, will rely on tree comparison method" >&2
    exit 1
  fi

  # Find deleted compose.yaml files between current and target
  git diff --diff-filter=D --name-only "$CURRENT_SHA" "$TARGET_SHA" 2>/dev/null | \
    grep -E '^[^/]+/compose\.yaml$' | \
    sed 's|/compose\.yaml||' || echo ""
DETECT_EOF
  )

  # Execute detection script on remote server
  echo "$detect_script" | ssh_retry 3 5 "ssh -o \"StrictHostKeyChecking no\" $SSH_USER@$SSH_HOST /bin/bash -s \"$current_sha\" \"$target_ref\""
}

# === DETECTION FUNCTION: TREE COMPARISON ===
# Purpose: Detect stacks on server filesystem missing from target commit tree
detect_removed_stacks_tree() {
  local target_ref="$1"

  log_info "Running tree comparison detection..."

  # Build detection script
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

  # Execute detection script on remote server
  echo "$detect_script" | ssh_retry 3 5 "ssh -o \"StrictHostKeyChecking no\" $SSH_USER@$SSH_HOST /bin/bash -s \"$target_ref\""
}

# === DETECTION FUNCTION: DISCOVERY ANALYSIS ===
# Purpose: Analyze deleted files from tj-actions/changed-files output
detect_removed_stacks_discovery() {
  local deleted_files_json="$1"

  log_info "Running discovery analysis detection..."

  # Build detection script
  local detect_script
  detect_script=$(cat << 'DETECT_DISCOVERY_EOF'
  set -e
  DELETED_FILES_JSON="$1"

  # Parse JSON array and filter for compose.yaml deletions
  # Pattern: one level deep only (stack-name/compose.yaml)
  echo "$DELETED_FILES_JSON" | jq -r '.[]' 2>/dev/null | \
    grep -E '^[^/]+/compose\.yaml$' | \
    sed 's|/compose\.yaml||' || echo ""
DETECT_DISCOVERY_EOF
  )

  # Execute detection script on remote server
  # Escape JSON to prevent shell glob expansion of [] characters
  local deleted_files_escaped
  deleted_files_escaped=$(printf '%q' "$deleted_files_json")

  echo "$detect_script" | ssh_retry 3 5 "ssh -o 'StrictHostKeyChecking no' $SSH_USER@$SSH_HOST /bin/bash -s $deleted_files_escaped"
}

# === AGGREGATION FUNCTION ===
# Purpose: Merge and deduplicate results from all three detection methods
aggregate_removed_stacks() {
  local gitdiff_stacks="$1"
  local tree_stacks="$2"
  local discovery_stacks="$3"

  # Concatenate all three lists, remove empty lines, sort and deduplicate
  {
    echo "$gitdiff_stacks"
    echo "$tree_stacks"
    echo "$discovery_stacks"
  } | \
    grep -v '^$' | \
    sort -u | \
    grep -E '^[a-zA-Z0-9_-]+$' || echo ""
}

# === MAIN EXECUTION ===
log_info "Running three detection methods..."

# Execute all three detection methods independently
GITDIFF_EXIT=0
TREE_EXIT=0
DISCOVERY_EXIT=0

GITDIFF_STACKS=$(detect_removed_stacks_gitdiff "$CURRENT_SHA" "$TARGET_REF") || GITDIFF_EXIT=$?
TREE_STACKS=$(detect_removed_stacks_tree "$TARGET_REF") || TREE_EXIT=$?

# Handle discovery analysis based on deleted files input
if [ "$DELETED_FILES" = "[]" ] || [ -z "$DELETED_FILES" ]; then
  log_info "No deleted files detected - skipping discovery analysis"
  DISCOVERY_STACKS=""
  DISCOVERY_EXIT=0
else
  DISCOVERY_STACKS=$(detect_removed_stacks_discovery "$DELETED_FILES") || DISCOVERY_EXIT=$?
fi

# Fail deployment if any detection method failed (fail-safe)
if [ "$GITDIFF_EXIT" -ne 0 ]; then
  log_error "Git diff detection failed (exit code: $GITDIFF_EXIT)"
  exit 1
fi
if [ "$TREE_EXIT" -ne 0 ]; then
  log_error "Tree comparison detection failed (exit code: $TREE_EXIT)"
  exit 1
fi
if [ "$DISCOVERY_EXIT" -ne 0 ]; then
  log_error "Discovery analysis detection failed (exit code: $DISCOVERY_EXIT)"
  exit 1
fi

log_success "All detection methods completed successfully"

# Aggregate results (union of all three methods)
log_info "Aggregating results..."
REMOVED_STACKS=$(aggregate_removed_stacks "$GITDIFF_STACKS" "$TREE_STACKS" "$DISCOVERY_STACKS")

# Debug logging
if [ -n "$GITDIFF_STACKS" ]; then
  echo "  Git diff found: $(echo "$GITDIFF_STACKS" | tr '\n' ', ' | sed 's/,$//')"
fi
if [ -n "$TREE_STACKS" ]; then
  echo "  Tree comparison found: $(echo "$TREE_STACKS" | tr '\n' ', ' | sed 's/,$//')"
fi
if [ -n "$DISCOVERY_STACKS" ]; then
  echo "  Discovery analysis found: $(echo "$DISCOVERY_STACKS" | tr '\n' ', ' | sed 's/,$//')"
fi

# Process results
if [ -z "$REMOVED_STACKS" ]; then
  log_success "No stacks to remove"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "removed_stacks=" >> "$GITHUB_OUTPUT"
    echo "has_removed_stacks=false" >> "$GITHUB_OUTPUT"
  fi
else
  log_warning "Found stacks to remove:"
  echo "$REMOVED_STACKS" | while read -r stack; do
    echo "  - $stack"
  done

  # Convert to JSON array for output
  REMOVED_JSON=$(echo "$REMOVED_STACKS" | jq -R -s -c 'split("\n") | map(select(length > 0))')
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "removed_stacks=$REMOVED_JSON" >> "$GITHUB_OUTPUT"
    echo "has_removed_stacks=true" >> "$GITHUB_OUTPUT"
  fi

  # Cleanup each removed stack using the helper script
  log_info "Cleaning up removed stacks..."
  CLEANUP_FAILED=false

  while IFS= read -r stack; do
    [ -z "$stack" ] && continue

    log_info "Cleaning up stack: $stack"

    # Call cleanup-stack.sh helper script
    if ! "$SCRIPT_DIR/cleanup-stack.sh" \
      --stack-name "$stack" \
      --ssh-user "$SSH_USER" \
      --ssh-host "$SSH_HOST" \
      --op-token "$OP_TOKEN"; then
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

exit 0
