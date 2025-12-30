#!/usr/bin/env bash
# Script Name: cleanup-stack.sh
# Purpose: Clean up a single removed Docker Compose stack
# Usage: ./cleanup-stack.sh --stack-name stackname --ssh-user user --ssh-host host

set -euo pipefail

# Get script directory and source libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ssh-helpers.sh
source "$SCRIPT_DIR/lib/ssh-helpers.sh"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# Default values
STACK_NAME=""
SSH_USER=""
SSH_HOST=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --stack-name)
      STACK_NAME="$2"
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
require_var STACK_NAME || exit 1
require_var SSH_USER || exit 1
require_var SSH_HOST || exit 1

# Validate stack name format
validate_stack_name "$STACK_NAME" || exit 1

log_info "Cleaning up stack: $STACK_NAME"

# Execute cleanup via SSH with retry
# Use printf %q to properly escape argument for eval in ssh_retry
STACK_NAME_ESCAPED=$(printf '%q' "$STACK_NAME")

# Stack cleanup doesn't require 1Password since we're just shutting down containers
{
  cat << 'EOF'
  set -e

  STACK="$1"

  # Check if stack directory exists
  if [ ! -d "/opt/compose/$STACK" ]; then
    echo "⚠️ Stack directory not found for $STACK - already fully removed"
    exit 0
  fi

  cd "/opt/compose/$STACK"

  # Check if compose.yaml exists
  if [ ! -f compose.yaml ]; then
    echo "⚠️ compose.yaml not found for $STACK - may have been manually removed"
    exit 0
  fi

  # Run docker compose down without 1Password (no env vars needed for cleanup)
  if docker compose -f ./compose.yaml down; then
    echo "✅ Successfully cleaned up $STACK"
  else
    echo "❌ Failed to clean up $STACK"
    exit 1
  fi
EOF
} | ssh_retry 3 5 "ssh $SSH_USER@$SSH_HOST /bin/bash -s $STACK_NAME_ESCAPED"

log_success "Stack $STACK_NAME cleaned up successfully"
exit 0
