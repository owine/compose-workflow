#!/usr/bin/env bash
# Script Name: cleanup-stack.sh
# Purpose: Clean up a single removed Docker Compose stack
# Usage: ./cleanup-stack.sh --stack-name stackname --ssh-user user --ssh-host host --op-token token

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
OP_TOKEN=""

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
require_var STACK_NAME || exit 1
require_var SSH_USER || exit 1
require_var SSH_HOST || exit 1
require_var OP_TOKEN || exit 1

# Validate stack name format
validate_stack_name "$STACK_NAME" || exit 1

log_info "Cleaning up stack: $STACK_NAME"

# Execute cleanup via SSH with retry
# Token passed as environment variable to avoid exposure in process args
ssh_retry 3 5 "ssh -o \"StrictHostKeyChecking no\" $SSH_USER@$SSH_HOST env OP_SERVICE_ACCOUNT_TOKEN=\"$OP_TOKEN\" /bin/bash -s \"$STACK_NAME\"" << 'EOF'
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

  # Run docker compose down with 1Password
  # Note: OP_SERVICE_ACCOUNT_TOKEN is passed via 'env' command on remote side
  if op run --env-file=/opt/compose/compose.env -- docker compose -f ./compose.yaml down; then
    echo "✅ Successfully cleaned up $STACK"
  else
    echo "❌ Failed to clean up $STACK"
    exit 1
  fi
EOF

log_success "Stack $STACK_NAME cleaned up successfully"
exit 0
