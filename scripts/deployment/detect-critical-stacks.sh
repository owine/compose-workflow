#!/usr/bin/env bash
# Script Name: detect-critical-stacks.sh
# Purpose: Detect critical stacks based on compose file labels
# Usage: ./detect-critical-stacks.sh --stacks "stack1 stack2 stack3" --ssh-user user --ssh-host host --op-token token

set -euo pipefail

# Get script directory and source libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ssh-helpers.sh
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/ssh-helpers.sh"
source "$SCRIPT_DIR/lib/common.sh"

# Default values
STACKS=""
SSH_USER=""
SSH_HOST=""
OP_TOKEN=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --stacks)
      STACKS="$2"
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
      # shellcheck disable=SC2034  # Reserved for future use, validated for API consistency
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
require_var STACKS || exit 1
require_var SSH_USER || exit 1
require_var SSH_HOST || exit 1
require_var OP_TOKEN || exit 1

log_info "Detecting critical stacks from compose file labels..."
log_info "Scanning stacks: $STACKS"

# Escape stacks for positional argument
# shellcheck disable=SC2086  # Word splitting intended - each stack becomes separate argument to printf
STACKS_ESCAPED=$(printf '%q ' $STACKS)

# Execute detection script on remote server
RESULT=$(cat << 'DETECT_EOF' | ssh_retry 3 5 "ssh -o \"StrictHostKeyChecking no\" $SSH_USER@$SSH_HOST /bin/bash -s $STACKS_ESCAPED"
set -e

# Critical stack detection logic
CRITICAL_STACKS=()

# Process each stack
for stack in "$@"; do
  COMPOSE_FILE="/opt/compose/$stack/compose.yaml"

  # Skip if compose file doesn't exist
  if [ ! -f "$COMPOSE_FILE" ]; then
    echo "⚠️  Compose file not found for stack: $stack" >&2
    continue
  fi

  # Check for critical tier labels
  # Supported labels:
  #   - com.compose.tier: infrastructure
  #   - com.compose.critical: true
  #   - com.compose.critical: "true"

  IS_CRITICAL=false

  # Method 1: Check for tier=infrastructure label
  if grep -q "com.compose.tier: infrastructure" "$COMPOSE_FILE" 2>/dev/null; then
    IS_CRITICAL=true
  fi

  # Method 2: Check for critical=true label
  if grep -E "com.compose.critical: (true|\"true\")" "$COMPOSE_FILE" 2>/dev/null; then
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
  echo "[]"
else
  printf '%s\n' "${CRITICAL_STACKS[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))'
fi
DETECT_EOF
)

# Parse result
CRITICAL_STACKS_JSON="$RESULT"

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
