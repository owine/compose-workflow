#!/usr/bin/env bash
#
# Dockge Deployment Script
# Deploys or rolls back the Dockge container management interface
#
# Usage:
#   deploy-dockge.sh --ssh-user USER --ssh-host HOST --op-token TOKEN \
#                    --image-timeout 300 --startup-timeout 120 [--compose-args "args"]
#
# Exit codes:
#   0 - Dockge deployed successfully
#   1 - Deployment failed
#

set -euo pipefail

# Get script directory and source libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ssh-helpers.sh
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/ssh-helpers.sh"
source "$SCRIPT_DIR/lib/common.sh"

# Default values
SSH_USER=""
SSH_HOST=""
OP_TOKEN=""
IMAGE_PULL_TIMEOUT="300"
SERVICE_STARTUP_TIMEOUT="120"
COMPOSE_ARGS=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
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
    --image-timeout)
      IMAGE_PULL_TIMEOUT="$2"
      shift 2
      ;;
    --startup-timeout)
      SERVICE_STARTUP_TIMEOUT="$2"
      shift 2
      ;;
    --compose-args)
      COMPOSE_ARGS="$2"
      shift 2
      ;;
    *)
      log_error "Unknown argument: $1"
      exit 1
      ;;
  esac
done

# Validate required arguments
require_var SSH_USER || exit 1
require_var SSH_HOST || exit 1
require_var OP_TOKEN || exit 1

log_info "🚀 Deploying Dockge..."
log_info "Image pull timeout: ${IMAGE_PULL_TIMEOUT}s"
log_info "Service startup timeout: ${SERVICE_STARTUP_TIMEOUT}s"

# Execute Dockge deployment via SSH
ssh_retry 3 5 "ssh -o \"StrictHostKeyChecking no\" $SSH_USER@$SSH_HOST env OP_SERVICE_ACCOUNT_TOKEN=\"$OP_TOKEN\" IMAGE_PULL_TIMEOUT=\"$IMAGE_PULL_TIMEOUT\" SERVICE_STARTUP_TIMEOUT=\"$SERVICE_STARTUP_TIMEOUT\" COMPOSE_ARGS=\"$COMPOSE_ARGS\" /bin/bash -s" << 'EOF'
  set -e

  # Change to Dockge directory
  if ! cd /opt/dockge; then
    echo "❌ Failed to change to /opt/dockge directory"
    exit 1
  fi

  echo "Pulling Dockge images..."
  # shellcheck disable=SC2086
  if ! timeout "$IMAGE_PULL_TIMEOUT" op run --env-file=/opt/compose/compose.env -- docker compose pull; then
    echo "❌ Dockge image pull timed out after ${IMAGE_PULL_TIMEOUT}s"
    exit 1
  fi

  echo "Starting Dockge services..."
  # shellcheck disable=SC2086
  if ! timeout "$SERVICE_STARTUP_TIMEOUT" op run --env-file=/opt/compose/compose.env -- docker compose up -d --remove-orphans $COMPOSE_ARGS; then
    echo "❌ Dockge startup timed out after ${SERVICE_STARTUP_TIMEOUT}s"
    exit 1
  fi

  echo "✅ Dockge deployed successfully"
EOF

# Check SSH command exit status
SSH_EXIT=$?
if [ "$SSH_EXIT" -eq 0 ]; then
  log_success "Dockge deployed successfully"
  exit 0
else
  log_error "Dockge deployment failed"
  exit 1
fi
