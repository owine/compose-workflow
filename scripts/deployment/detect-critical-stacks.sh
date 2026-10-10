#!/usr/bin/env bash
# Script Name: detect-critical-stacks.sh
# Purpose: Detect critical stacks based on compose file labels
# Usage: ./detect-critical-stacks.sh --stacks "stack1 stack2 stack3" --repo-dir /path/to/repo

set -euo pipefail

# Get script directory and source libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# Default values
STACKS=""
REPO_DIR=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --stacks)
      STACKS="$2"
      shift 2
      ;;
    --repo-dir)
      REPO_DIR="$2"
      shift 2
      ;;
    *)
      log_error "Unknown argument: $1"
      exit 1
      ;;
  esac
done

# Validate required arguments
require_var STACKS || exit 1
require_var REPO_DIR || exit 1

log_info "Detecting critical stacks from compose file labels..."
log_info "Scanning stacks: $STACKS"

# has_label <compose_file> <key_regex> <value_regex>
# Returns 0 if the file declares the label <key>=<value> on any service.
# Accepts every way the label can legitimately be written:
#   map form:   com.compose.tier: infrastructure
#               com.compose.tier: "infrastructure"   (house style, quoted)
#               com.compose.tier: 'infrastructure'
#   list form:  - com.compose.tier=infrastructure
#               - "com.compose.tier=infrastructure"
# with arbitrary leading/trailing whitespace and an optional trailing
# `# comment`. The whole line is anchored, so commented-out labels
# (`# com.compose.tier: infrastructure`) and other values
# (`infrastructure-extra`, `application`) do NOT match.
has_label() {
  local file="$1" key="$2" value="$3"
  local q="[\"']?"
  grep -qE "^[[:space:]]*(-[[:space:]]*)?${q}${key}${q}[[:space:]]*[:=][[:space:]]*${q}${value}${q}[[:space:]]*(#.*)?$" \
    "$file" 2>/dev/null
}

# Critical stack detection logic
CRITICAL_STACKS=()

# Process each stack from local checkout
# shellcheck disable=SC2086  # Word splitting intended
for stack in $STACKS; do
  COMPOSE_FILE="$REPO_DIR/$stack/compose.yaml"

  # Skip if compose file doesn't exist
  if [ ! -f "$COMPOSE_FILE" ]; then
    log_warning "Compose file not found for stack: $stack"
    continue
  fi

  # Check for critical tier labels
  # Supported labels (value may be unquoted, "double-" or 'single-quoted';
  # map form or list form `- key=value`, see has_label above):
  #   - com.compose.tier: "infrastructure"
  #   - com.compose.critical: "true"

  IS_CRITICAL=false

  # Method 1: Check for tier=infrastructure label
  if has_label "$COMPOSE_FILE" 'com\.compose\.tier' 'infrastructure'; then
    IS_CRITICAL=true
  fi

  # Method 2: Check for critical=true label
  if has_label "$COMPOSE_FILE" 'com\.compose\.critical' 'true'; then
    IS_CRITICAL=true
  fi

  # Add to critical stacks array
  if [ "$IS_CRITICAL" = "true" ]; then
    CRITICAL_STACKS+=("$stack")
    echo "🚨 Detected critical stack: $stack" >&2
  else
    echo "✓ Non-critical stack: $stack" >&2
  fi
done

# Output JSON array of critical stacks
if [ ${#CRITICAL_STACKS[@]} -eq 0 ]; then
  CRITICAL_STACKS_JSON="[]"
else
  CRITICAL_STACKS_JSON=$(printf '%s\n' "${CRITICAL_STACKS[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')
fi

# Output for GitHub Actions
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "critical_stacks=$CRITICAL_STACKS_JSON" >> "$GITHUB_OUTPUT"
fi

# Also output to stdout for workflow capture
echo "CRITICAL_STACKS=$CRITICAL_STACKS_JSON"

# Log results
CRITICAL_COUNT=$(echo "$CRITICAL_STACKS_JSON" | jq '. | length')
if [ "$CRITICAL_COUNT" -eq 0 ]; then
  log_info "No critical stacks detected"
else
  log_success "Detected $CRITICAL_COUNT critical stack(s): $(echo "$CRITICAL_STACKS_JSON" | jq -r 'join(", ")')"
fi

exit 0
