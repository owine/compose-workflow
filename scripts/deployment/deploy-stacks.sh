#!/usr/bin/env bash
# Script Name: deploy-stacks.sh
# Purpose: Deploy Docker Compose stacks with parallel execution and comprehensive error handling
# Usage: ./deploy-stacks.sh --stacks "stack1 stack2" --target-ref abc123 --ssh-user user --ssh-host host --op-token token

set -euo pipefail

# Get script directory and source libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ssh-helpers.sh
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/ssh-helpers.sh"
source "$SCRIPT_DIR/lib/common.sh"

# Default values
STACKS=""
TARGET_REF=""
COMPOSE_ARGS=""
SSH_USER=""
SSH_HOST=""
OP_TOKEN=""
GIT_FETCH_TIMEOUT="60"
GIT_CHECKOUT_TIMEOUT="30"
IMAGE_PULL_TIMEOUT="300"
SERVICE_STARTUP_TIMEOUT="120"
VALIDATION_ENV_TIMEOUT="30"
VALIDATION_SYNTAX_TIMEOUT="30"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --stacks)
      STACKS="$2"
      shift 2
      ;;
    --target-ref)
      TARGET_REF="$2"
      shift 2
      ;;
    --compose-args)
      COMPOSE_ARGS="$2"
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
    --git-fetch-timeout)
      GIT_FETCH_TIMEOUT="$2"
      shift 2
      ;;
    --git-checkout-timeout)
      GIT_CHECKOUT_TIMEOUT="$2"
      shift 2
      ;;
    --image-pull-timeout)
      IMAGE_PULL_TIMEOUT="$2"
      shift 2
      ;;
    --service-startup-timeout)
      SERVICE_STARTUP_TIMEOUT="$2"
      shift 2
      ;;
    --validation-env-timeout)
      VALIDATION_ENV_TIMEOUT="$2"
      shift 2
      ;;
    --validation-syntax-timeout)
      VALIDATION_SYNTAX_TIMEOUT="$2"
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
require_var TARGET_REF || exit 1
require_var SSH_USER || exit 1
require_var SSH_HOST || exit 1
require_var OP_TOKEN || exit 1

log_info "Starting deployment for stacks: $STACKS"
log_info "Target ref: $TARGET_REF"

# Execute deployment via SSH with retry
# Use 'env' on remote side to set environment variables for the remote bash session
# Use printf %q to properly escape arguments for eval in ssh_retry
# Empty COMPOSE_ARGS uses placeholder to survive eval
# shellcheck disable=SC2086 # Word splitting is intentional for printf to process each stack
STACKS_ESCAPED=$(printf '%q ' $STACKS)
TARGET_REF_ESCAPED=$(printf '%q' "$TARGET_REF")

if [ -z "$COMPOSE_ARGS" ]; then
  COMPOSE_ARGS_ESCAPED="__EMPTY__"
else
  COMPOSE_ARGS_ESCAPED=$(printf '%q' "$COMPOSE_ARGS")
fi

# Pass OP_TOKEN as positional argument (more secure than env vars in process list)
# Token passed as $1, appears in SSH command locally but not in remote ps output
{
  cat << 'EOF'
  set -e

  # Get OP_TOKEN from first positional argument (passed securely via SSH)
  OP_SERVICE_ACCOUNT_TOKEN="$1"
  export OP_SERVICE_ACCOUNT_TOKEN

  # Shift to get actual script arguments (stacks, target-ref, compose-args)
  shift

  # Performance optimizations
  export DOCKER_BUILDKIT=1
  export COMPOSE_DOCKER_CLI_BUILD=1

  # Enable parallel image pulls
  export COMPOSE_PARALLEL_LIMIT=8

  # Get arguments passed to script (excluding sensitive OP_TOKEN)
  # Arguments: stack1 [stack2 ...] TARGET_REF COMPOSE_ARGS
  # COMPOSE_ARGS is always passed (could be empty string "")

  TOTAL_ARGS=$#

  # Validate minimum arguments (at least 1 stack + TARGET_REF + COMPOSE_ARGS)
  if [ $TOTAL_ARGS -lt 3 ]; then
    echo "❌ Insufficient arguments: expected at least 3 (stacks, target-ref, compose-args), got $TOTAL_ARGS"
    exit 1
  fi

  # Last argument is always COMPOSE_ARGS (could be empty placeholder)
  COMPOSE_ARGS="${!TOTAL_ARGS}"

  # Convert __EMPTY__ placeholder back to empty string
  if [ "$COMPOSE_ARGS" = "__EMPTY__" ]; then
    COMPOSE_ARGS=""
  fi

  # Second-to-last argument is always TARGET_REF
  TARGET_REF="${@:$((TOTAL_ARGS-1)):1}"

  # Everything before the last 2 arguments are stack names
  STACKS="${@:1:$((TOTAL_ARGS-2))}"

  # OP_SERVICE_ACCOUNT_TOKEN was passed as $1 (more secure than long-lived env vars)
  # Timeouts are passed via 'env' command on remote side
  GIT_FETCH_TIMEOUT=${GIT_FETCH_TIMEOUT:-60}
  GIT_CHECKOUT_TIMEOUT=${GIT_CHECKOUT_TIMEOUT:-30}
  IMAGE_PULL_TIMEOUT=${IMAGE_PULL_TIMEOUT:-300}
  SERVICE_STARTUP_TIMEOUT=${SERVICE_STARTUP_TIMEOUT:-120}
  VALIDATION_ENV_TIMEOUT=${VALIDATION_ENV_TIMEOUT:-30}
  VALIDATION_SYNTAX_TIMEOUT=${VALIDATION_SYNTAX_TIMEOUT:-30}

  echo "Updating repository to $TARGET_REF..."

  # Add timeout protection to git operations
  if ! timeout $GIT_FETCH_TIMEOUT git -C /opt/compose/ fetch; then
    echo "❌ Git fetch timed out after ${GIT_FETCH_TIMEOUT}s"
    exit 1
  fi

  if ! timeout $GIT_CHECKOUT_TIMEOUT git -C /opt/compose/ checkout $TARGET_REF; then
    echo "❌ Git checkout timed out after ${GIT_CHECKOUT_TIMEOUT}s"
    exit 1
  fi

  echo "✅ Repository updated to $TARGET_REF"

  # Shared function to deploy or rollback a single stack
  # This eliminates code duplication between deploy and rollback operations
  process_stack() {
    local STACK=$1
    local OPERATION=$2  # "deploy" or "rollback"
    local LOGFILE="/tmp/${OPERATION}_${STACK}.log"
    local EXITCODEFILE="/tmp/${OPERATION}_${STACK}.exitcode"
    local exit_code=0

    # Execute deployment/rollback in subshell with output redirection
    # Capture exit code explicitly to ensure it's always written to the exit code file
    {
      if [ "$OPERATION" = "deploy" ]; then
        echo "🚀 Deploying $STACK..."
      else
        echo "🔄 Rolling back $STACK..."
      fi

      cd /opt/compose/$STACK

      echo "  Pulling images for $STACK..."
      # Add timeout protection (5 minutes for image pull)
      if ! timeout $IMAGE_PULL_TIMEOUT op run --env-file=/opt/compose/compose.env -- docker compose pull; then
        echo "❌ Failed to pull images for $STACK during $OPERATION (timeout or error)"
        exit 1
      fi

      echo "  Starting services for $STACK..."
      # Add timeout protection (2 minutes for service startup)
      if ! timeout $SERVICE_STARTUP_TIMEOUT op run --env-file=/opt/compose/compose.env -- docker compose up -d --remove-orphans $COMPOSE_ARGS; then
        echo "❌ Failed to start services for $STACK during $OPERATION (timeout or error)"
        exit 1
      fi

      if [ "$OPERATION" = "deploy" ]; then
        echo "✅ $STACK deployed successfully"
      else
        echo "✅ $STACK rolled back successfully"
      fi
    } > "$LOGFILE" 2>&1 || exit_code=$?

    # Always write exit code to file, even if operation failed
    echo "$exit_code" > "$EXITCODEFILE"
    return $exit_code
  }

  # Wrapper function for deploy (maintains backward compatibility)
  deploy_stack() {
    process_stack "$1" "deploy"
  }

  # Cleanup function for deploy logs
  cleanup_deploy_logs() {
    for STACK in $STACKS; do
      rm -f "/tmp/deploy_${STACK}.log" 2>/dev/null
    done
  }

  # Pre-deployment validation function
  validate_all_stacks() {
    echo "🔍 Pre-deployment validation of all stacks..."
    local validation_failed=false

    for STACK in $STACKS; do
      echo "  Validating $STACK..."

      # Check if stack directory exists
      if [ ! -d "/opt/compose/$STACK" ]; then
        echo "❌ $STACK: Directory /opt/compose/$STACK not found"
        validation_failed=true
        continue
      fi

      cd "/opt/compose/$STACK" || {
        echo "❌ $STACK: Cannot access directory"
        validation_failed=true
        continue
      }

      # Check if compose.yaml exists
      if [ ! -f "compose.yaml" ]; then
        echo "❌ $STACK: compose.yaml not found"
        validation_failed=true
        continue
      fi

      # Validate 1Password environment access and Docker Compose config
      if ! timeout $VALIDATION_ENV_TIMEOUT op run --env-file=/opt/compose/compose.env -- docker compose -f compose.yaml config --services >/dev/null 2>&1; then
        echo "❌ $STACK: Environment validation failed (1Password or compose config error)"
        validation_failed=true
        continue
      fi

      # Quick syntax validation
      if ! timeout $VALIDATION_SYNTAX_TIMEOUT op run --env-file=/opt/compose/compose.env -- docker compose -f compose.yaml config --quiet 2>/dev/null; then
        echo "❌ $STACK: Docker Compose syntax validation failed"
        validation_failed=true
        continue
      fi

      echo "✅ $STACK: Pre-deployment validation passed"
    done

    if [ "$validation_failed" = true ]; then
      echo "❌ Pre-deployment validation failed for one or more stacks"
      echo "   Stopping deployment to prevent extended failures"
      return 1
    fi

    echo "✅ All stacks passed pre-deployment validation"
    return 0
  }

  # Run pre-deployment validation
  if ! validate_all_stacks; then
    echo "DEPLOYMENT_STATUS=failed_validation"
    exit 1
  fi

  # Set trap for cleanup on exit
  trap cleanup_deploy_logs EXIT

  # Start all deployments in parallel
  echo "🚀 Starting parallel deployment of all stacks..."
  PIDS=""

  # Simple approach - use for loop directly with unquoted variable
  for STACK in $STACKS; do
    echo "🚀 Deploying $STACK..."
    deploy_stack "$STACK" &
    PIDS="$PIDS $!"
    echo "Started deployment of $STACK (PID: $!)"
  done

  # Wait for all deployments and collect results
  echo "⏳ Waiting for all deployments to complete..."
  FAILED_STACKS=""

  # Enhanced parallel job monitoring with better error propagation
  echo "⏳ Monitoring parallel deployments..."
  DEPLOYED_STACKS=""
  SUCCESSFUL_STACKS=""
  DEPLOYMENT_ERRORS=""

  # Wait for jobs individually to capture exit codes
  for PID in $PIDS; do
    if wait "$PID"; then
      echo "✅ Deployment process $PID completed successfully"
    else
      EXIT_CODE=$?
      echo "❌ Deployment process $PID failed with exit code $EXIT_CODE"
      DEPLOYMENT_ERRORS="$DEPLOYMENT_ERRORS PID:$PID:$EXIT_CODE"
    fi
  done

  # Enhanced result analysis using exit code files (more robust than log parsing)
  for STACK in $STACKS; do
    if [ -f "/tmp/deploy_${STACK}.log" ]; then
      DEPLOYED_STACKS="$DEPLOYED_STACKS $STACK"

      # Primary: Check exit code file for robust error detection
      if [ -f "/tmp/deploy_${STACK}.exitcode" ]; then
        EXIT_CODE=$(cat "/tmp/deploy_${STACK}.exitcode")
        if [ "$EXIT_CODE" -eq 0 ]; then
          SUCCESSFUL_STACKS="$SUCCESSFUL_STACKS $STACK"
        else
          FAILED_STACKS="$FAILED_STACKS $STACK"
          echo "🔍 $STACK Error: Non-zero exit code ($EXIT_CODE)"
        fi
      else
        # Fallback: Log-based error detection if exit code file is missing
        echo "⚠️ $STACK: Exit code file missing - using less reliable log-based detection"
        if grep -q "❌.*$STACK\|CRITICAL.*$STACK\|Failed.*$STACK\|Error.*$STACK" "/tmp/deploy_${STACK}.log"; then
          FAILED_STACKS="$FAILED_STACKS $STACK"
          # Extract specific error for reporting
          STACK_ERROR=$(grep -E "❌.*$STACK|CRITICAL.*$STACK|Failed.*$STACK|Error.*$STACK" "/tmp/deploy_${STACK}.log" | head -1)
          echo "🔍 $STACK Error: $STACK_ERROR"
        elif grep -q "✅.*$STACK\|Successfully.*$STACK" "/tmp/deploy_${STACK}.log"; then
          SUCCESSFUL_STACKS="$SUCCESSFUL_STACKS $STACK"
        else
          echo "⚠️ $STACK: No clear success/failure indicator in logs - treating as potential failure"
          FAILED_STACKS="$FAILED_STACKS $STACK"
        fi
      fi
    else
      echo "⚠️ $STACK: No deployment log found - possible early failure"
      FAILED_STACKS="$FAILED_STACKS $STACK"
    fi
  done

  # Summary of deployment results
  echo ""
  echo "📊 Deployment Summary:"
  echo "  Successful: $(echo $SUCCESSFUL_STACKS | wc -w | tr -d ' ') stacks"
  echo "  Failed: $(echo $FAILED_STACKS | wc -w | tr -d ' ') stacks"
  if [ -n "$DEPLOYMENT_ERRORS" ]; then
    echo "  Process errors: $DEPLOYMENT_ERRORS"
  fi

  # Display deployment logs with enhanced formatting
  echo ""
  echo "📋 Detailed Deployment Results:"
  echo "════════════════════════════════════════════════════════════════"
  for STACK in $STACKS; do
    if [ -f "/tmp/deploy_${STACK}.log" ]; then
      echo ""
      echo "🔸 STACK: $STACK"
      echo "────────────────────────────────────────────────────────────────"
      cat "/tmp/deploy_${STACK}.log"
      echo "────────────────────────────────────────────────────────────────"
    else
      echo ""
      echo "🔸 STACK: $STACK"
      echo "────────────────────────────────────────────────────────────────"
      echo "⚠️  No deployment log found for $STACK"
      echo "────────────────────────────────────────────────────────────────"
    fi
  done
  echo "════════════════════════════════════════════════════════════════"

  # Check if any deployments failed
  if [ -z "$STACKS" ]; then
    echo "💥 No stacks to deploy - STACKS variable is empty!"
    exit 1
  elif [ -z "$DEPLOYED_STACKS" ]; then
    echo "💥 No stacks were actually deployed - check stack discovery!"
    exit 1
  elif [ -n "$FAILED_STACKS" ]; then
    echo "💥 Deployments failed for:$FAILED_STACKS"
    exit 1
  fi

  echo "🎉 All stacks deployed successfully in parallel!"
EOF
} | ssh_retry 3 10 "ssh $SSH_USER@$SSH_HOST env GIT_FETCH_TIMEOUT=\"$GIT_FETCH_TIMEOUT\" GIT_CHECKOUT_TIMEOUT=\"$GIT_CHECKOUT_TIMEOUT\" IMAGE_PULL_TIMEOUT=\"$IMAGE_PULL_TIMEOUT\" SERVICE_STARTUP_TIMEOUT=\"$SERVICE_STARTUP_TIMEOUT\" VALIDATION_ENV_TIMEOUT=\"$VALIDATION_ENV_TIMEOUT\" VALIDATION_SYNTAX_TIMEOUT=\"$VALIDATION_SYNTAX_TIMEOUT\" /bin/bash -s \"$OP_TOKEN\" $STACKS_ESCAPED $TARGET_REF_ESCAPED $COMPOSE_ARGS_ESCAPED"

log_success "Deployment completed successfully"
exit 0
