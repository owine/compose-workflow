#!/usr/bin/env bash
# Script Name: rollback-stacks.sh
# Purpose: Rollback Docker Compose stacks to previous commit with parallel execution
# Usage: ./rollback-stacks.sh --previous-sha abc123 --compose-args "" --critical-services '[]' --ssh-user user --ssh-host host --op-token token

set -euo pipefail

# Get script directory and source libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ssh-helpers.sh
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/ssh-helpers.sh"
source "$SCRIPT_DIR/lib/common.sh"

# Default values
PREVIOUS_SHA=""
COMPOSE_ARGS=""
CRITICAL_SERVICES="[]"
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
    --previous-sha)
      PREVIOUS_SHA="$2"
      shift 2
      ;;
    --compose-args)
      COMPOSE_ARGS="$2"
      shift 2
      ;;
    --critical-services)
      CRITICAL_SERVICES="$2"
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
require_var PREVIOUS_SHA || exit 1
require_var SSH_USER || exit 1
require_var SSH_HOST || exit 1
require_var OP_TOKEN || exit 1

# Validate PREVIOUS_SHA before attempting rollback
if [ "$PREVIOUS_SHA" = "unknown" ] || [ -z "$PREVIOUS_SHA" ]; then
  log_error "Cannot rollback: No previous deployment exists (first deployment)"
  exit 1
fi

# Validate SHA format (full 40-char SHA)
validate_sha "$PREVIOUS_SHA" || exit 1

log_success "Previous SHA validation passed: $PREVIOUS_SHA"
log_info "Initiating rollback to $PREVIOUS_SHA"

# Execute rollback via SSH with retry
# Use printf %q to properly escape arguments for eval in ssh_retry
# Empty strings use placeholder to survive eval
PREVIOUS_SHA_ESCAPED=$(printf '%q' "$PREVIOUS_SHA")

if [ -z "$COMPOSE_ARGS" ]; then
  COMPOSE_ARGS_ESCAPED="__EMPTY__"
else
  COMPOSE_ARGS_ESCAPED=$(printf '%q' "$COMPOSE_ARGS")
fi

if [ -z "$CRITICAL_SERVICES" ]; then
  CRITICAL_SERVICES_ESCAPED="__EMPTY__"
else
  CRITICAL_SERVICES_ESCAPED=$(printf '%q' "$CRITICAL_SERVICES")
fi

ROLLBACK_RESULT=$(ssh_retry 3 10 "ssh -o \"StrictHostKeyChecking no\" $SSH_USER@$SSH_HOST env OP_SERVICE_ACCOUNT_TOKEN=\"$OP_TOKEN\" GIT_FETCH_TIMEOUT=\"$GIT_FETCH_TIMEOUT\" GIT_CHECKOUT_TIMEOUT=\"$GIT_CHECKOUT_TIMEOUT\" IMAGE_PULL_TIMEOUT=\"$IMAGE_PULL_TIMEOUT\" SERVICE_STARTUP_TIMEOUT=\"$SERVICE_STARTUP_TIMEOUT\" VALIDATION_ENV_TIMEOUT=\"$VALIDATION_ENV_TIMEOUT\" VALIDATION_SYNTAX_TIMEOUT=\"$VALIDATION_SYNTAX_TIMEOUT\" /bin/bash -s $PREVIOUS_SHA_ESCAPED $COMPOSE_ARGS_ESCAPED $CRITICAL_SERVICES_ESCAPED" << 'EOF'
  set -e

  # Get arguments passed to script (excluding sensitive OP_TOKEN)
  PREVIOUS_SHA="$1"
  COMPOSE_ARGS="$2"
  CRITICAL_SERVICES="$3"

  # Convert __EMPTY__ placeholders back to empty strings
  [ "$COMPOSE_ARGS" = "__EMPTY__" ] && COMPOSE_ARGS=""
  [ "$CRITICAL_SERVICES" = "__EMPTY__" ] && CRITICAL_SERVICES=""

  # OP_SERVICE_ACCOUNT_TOKEN and timeouts are passed via 'env' command on remote side
  # They are already in the environment, no need to export again

  # Consolidate timeout values for easier maintenance
  GIT_FETCH_TIMEOUT=${GIT_FETCH_TIMEOUT:-60}
  GIT_CHECKOUT_TIMEOUT=${GIT_CHECKOUT_TIMEOUT:-30}
  IMAGE_PULL_TIMEOUT=${IMAGE_PULL_TIMEOUT:-300}
  SERVICE_STARTUP_TIMEOUT=${SERVICE_STARTUP_TIMEOUT:-120}
  VALIDATION_ENV_TIMEOUT=${VALIDATION_ENV_TIMEOUT:-30}
  VALIDATION_SYNTAX_TIMEOUT=${VALIDATION_SYNTAX_TIMEOUT:-30}

  echo "🔄 Rolling back to $PREVIOUS_SHA..."

  # Add timeout protection to git operations
  if ! timeout $GIT_FETCH_TIMEOUT git -C /opt/compose/ fetch; then
    echo "❌ Git fetch timed out after ${GIT_FETCH_TIMEOUT}s"
    exit 1
  fi

  if ! timeout $GIT_CHECKOUT_TIMEOUT git -C /opt/compose/ checkout $PREVIOUS_SHA; then
    echo "❌ Git checkout timed out after ${GIT_CHECKOUT_TIMEOUT}s"
    exit 1
  fi

  echo "✅ Repository rolled back to $PREVIOUS_SHA"

  # Dynamically discover stacks based on the previous commit's structure
  echo "🔍 Discovering stacks in previous commit..."
  ROLLBACK_STACKS_ARRAY=()
  cd /opt/compose
  for dir in */; do
    if [[ -d "$dir" && (-f "$dir/compose.yml" || -f "$dir/compose.yaml") ]]; then
      STACK_NAME=$(basename "$dir")
      ROLLBACK_STACKS_ARRAY+=("$STACK_NAME")
      echo "  Found stack: $STACK_NAME"
    fi
  done

  if [ ${#ROLLBACK_STACKS_ARRAY[@]} -eq 0 ]; then
    echo "⚠️ No stacks found in previous commit - rollback cannot proceed"
    exit 1
  fi

  # Use null character as delimiter to support stack names with spaces and special characters
  # Note: Null delimiter is used only within this SSH script execution
  # The rollback-health step will convert it to space-delimited before passing between workflow steps
  ROLLBACK_STACKS=$(printf "%s\0" "${ROLLBACK_STACKS_ARRAY[@]}")
  echo "📋 Stacks to rollback: ${ROLLBACK_STACKS_ARRAY[*]}"

  # Output discovered stacks for rollback-health step (null-delimited)
  # Will be converted to space-delimited in rollback-health step for compatibility
  echo "DISCOVERED_ROLLBACK_STACKS=$ROLLBACK_STACKS"

  # Note: Dockge rollback is now handled by deploy-dockge.sh before this SSH session

  # Shared function to deploy or rollback a single stack
  # This eliminates code duplication between deploy and rollback operations
  process_stack() {
    local STACK=$1
    local OPERATION=$2  # "deploy" or "rollback"
    local LOGFILE="/tmp/${OPERATION}_${STACK}.log"
    local EXITCODEFILE="/tmp/${OPERATION}_${STACK}.exitcode"

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
    } > "$LOGFILE" 2>&1

    # Capture and save exit code for robust error detection
    local exit_code=$?
    echo "$exit_code" > "$EXITCODEFILE"
    return $exit_code
  }

  # Wrapper function for rollback (uses shared process_stack)
  rollback_stack() {
    process_stack "$1" "rollback"
  }

  # Cleanup function for rollback logs
  cleanup_rollback_logs() {
    # Parse null-delimited stacks into array
    readarray -d $'\0' -t ROLLBACK_STACKS_ARRAY <<< "$ROLLBACK_STACKS"
    for STACK in "${ROLLBACK_STACKS_ARRAY[@]}"; do
      rm -f "/tmp/rollback_${STACK}.log" 2>/dev/null
    done
  }

  # Pre-rollback validation function
  validate_all_rollback_stacks() {
    echo "🔍 Pre-rollback validation of all stacks..."
    local validation_failed=false

    # Parse null-delimited stacks into array
    readarray -d $'\0' -t ROLLBACK_STACKS_ARRAY <<< "$ROLLBACK_STACKS"
    for STACK in "${ROLLBACK_STACKS_ARRAY[@]}"; do
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

      # Check if compose.yaml or compose.yml exists and determine which to use
      COMPOSE_FILE=""
      if [ -f "compose.yaml" ]; then
        COMPOSE_FILE="compose.yaml"
      elif [ -f "compose.yml" ]; then
        COMPOSE_FILE="compose.yml"
      else
        echo "❌ $STACK: neither compose.yaml nor compose.yml found"
        validation_failed=true
        continue
      fi

      # Validate 1Password environment access and Docker Compose config
      if ! timeout $VALIDATION_ENV_TIMEOUT op run --env-file=/opt/compose/compose.env -- docker compose -f "$COMPOSE_FILE" config --services >/dev/null 2>&1; then
        echo "❌ $STACK: Environment validation failed (1Password or compose config error)"
        validation_failed=true
        continue
      fi

      # Quick syntax validation
      if ! timeout $VALIDATION_SYNTAX_TIMEOUT op run --env-file=/opt/compose/compose.env -- docker compose -f "$COMPOSE_FILE" config --quiet 2>/dev/null; then
        echo "❌ $STACK: Docker Compose syntax validation failed"
        validation_failed=true
        continue
      fi

      echo "✅ $STACK: Pre-rollback validation passed"
    done

    if [ "$validation_failed" = true ]; then
      echo "❌ Pre-rollback validation failed for one or more stacks"
      echo "   Stopping rollback to prevent extended failures"
      return 1
    fi

    echo "✅ All stacks passed pre-rollback validation"
    return 0
  }

  # Set trap for cleanup on exit
  trap cleanup_rollback_logs EXIT

  # Run pre-rollback validation
  if ! validate_all_rollback_stacks; then
    echo "ROLLBACK_STATUS=failed_validation"
    exit 1
  fi

  # Start all rollback deployments in parallel
  echo "🔄 Starting parallel rollback of all stacks..."
  ROLLBACK_PIDS=""

  # Map each PID to its stack name for improved error reporting
  # Note: Requires Bash 4.0+ for associative arrays (GitHub Actions runners use Bash 5.x)
  declare -A ROLLBACK_PID_TO_STACK

  # Parse null-delimited stacks into array
  readarray -d $'\0' -t ROLLBACK_STACKS_ARRAY <<< "$ROLLBACK_STACKS"

  for STACK in "${ROLLBACK_STACKS_ARRAY[@]}"; do
    echo "🔄 Rolling back $STACK..."
    rollback_stack "$STACK" &
    PID=$!
    ROLLBACK_PIDS="$ROLLBACK_PIDS $PID"
    ROLLBACK_PID_TO_STACK[$PID]=$STACK
    echo "Started rollback of $STACK (PID: $PID)"
  done

  # Wait for all rollback deployments and collect results
  echo "⏳ Waiting for all rollbacks to complete..."
  FAILED_ROLLBACKS=""
  ROLLBACK_ERRORS=""

  # Enhanced parallel job monitoring with proper error propagation
  echo "⏳ Monitoring parallel rollback operations..."

  # Wait for jobs individually to capture exit codes and report stack names
  for PID in $ROLLBACK_PIDS; do
    STACK_NAME="${ROLLBACK_PID_TO_STACK[$PID]}"
    if wait "$PID"; then
      echo "✅ Rollback process $PID for stack $STACK_NAME completed successfully"
    else
      EXIT_CODE=$?
      # Check if process was terminated by signal (exit code > 128)
      if [ "$EXIT_CODE" -gt 128 ]; then
        SIGNAL_NUM=$((EXIT_CODE - 128))
        # Try to get signal name (works on most systems)
        if command -v kill >/dev/null 2>&1; then
          SIGNAL_NAME=$(kill -l $SIGNAL_NUM 2>/dev/null || echo "SIG$SIGNAL_NUM")
        else
          SIGNAL_NAME="SIG$SIGNAL_NUM"
        fi
        echo "❌ Rollback process $PID for stack $STACK_NAME was terminated by signal $SIGNAL_NUM ($SIGNAL_NAME)"
        ROLLBACK_ERRORS="$ROLLBACK_ERRORS STACK:$STACK_NAME:PID:$PID:TERMINATED_BY_SIGNAL:$SIGNAL_NUM:$SIGNAL_NAME"
      else
        echo "❌ Rollback process $PID for stack $STACK_NAME failed with exit code $EXIT_CODE"
        ROLLBACK_ERRORS="$ROLLBACK_ERRORS STACK:$STACK_NAME:PID:$PID:EXIT_CODE:$EXIT_CODE"
      fi
    fi
  done

  # Enhanced result analysis using exit code files (more robust than log parsing)
  ROLLED_BACK_STACKS=""
  SUCCESSFUL_ROLLBACKS=""
  # Parse null-delimited stacks into array
  readarray -d $'\0' -t ROLLBACK_STACKS_ARRAY <<< "$ROLLBACK_STACKS"
  for STACK in "${ROLLBACK_STACKS_ARRAY[@]}"; do
    if [ -f "/tmp/rollback_${STACK}.log" ]; then
      ROLLED_BACK_STACKS="$ROLLED_BACK_STACKS $STACK"

      # Primary: Check exit code file for robust error detection
      if [ -f "/tmp/rollback_${STACK}.exitcode" ]; then
        EXIT_CODE=$(cat "/tmp/rollback_${STACK}.exitcode")
        if [ "$EXIT_CODE" -eq 0 ]; then
          SUCCESSFUL_ROLLBACKS="$SUCCESSFUL_ROLLBACKS $STACK"
        else
          FAILED_ROLLBACKS="$FAILED_ROLLBACKS $STACK"
          echo "🔍 $STACK Rollback Error: Non-zero exit code ($EXIT_CODE)"
        fi
      else
        # Fallback: Log-based error detection if exit code file is missing
        echo "⚠️ $STACK: Exit code file missing - using less reliable log-based detection"
        if grep -q "❌.*$STACK\|CRITICAL.*$STACK\|Failed.*$STACK\|Error.*$STACK" "/tmp/rollback_${STACK}.log"; then
          FAILED_ROLLBACKS="$FAILED_ROLLBACKS $STACK"
          # Extract specific error for reporting
          STACK_ERROR=$(grep -E "❌.*$STACK|CRITICAL.*$STACK|Failed.*$STACK|Error.*$STACK" "/tmp/rollback_${STACK}.log" | head -1)
          echo "🔍 $STACK Rollback Error: $STACK_ERROR"
        elif grep -q "✅.*$STACK\|Successfully.*$STACK" "/tmp/rollback_${STACK}.log"; then
          SUCCESSFUL_ROLLBACKS="$SUCCESSFUL_ROLLBACKS $STACK"
        else
          echo "⚠️ $STACK: No clear success/failure indicator in logs - treating as potential failure"
          FAILED_ROLLBACKS="$FAILED_ROLLBACKS $STACK"
        fi
      fi
    else
      echo "⚠️ $STACK: No rollback log found - possible early failure"
      FAILED_ROLLBACKS="$FAILED_ROLLBACKS $STACK"
    fi
  done

  # Summary of rollback results
  echo ""
  echo "📊 Rollback Summary:"
  echo "  Successful: $(echo $SUCCESSFUL_ROLLBACKS | wc -w | tr -d ' ') stacks"
  echo "  Failed: $(echo $FAILED_ROLLBACKS | wc -w | tr -d ' ') stacks"
  if [ -n "$ROLLBACK_ERRORS" ]; then
    echo "  Process errors: $ROLLBACK_ERRORS"
  fi

  # Parse critical services list
  # Note: CRITICAL_SERVICES contains stack names (not individual Docker service names)
  # This matches stacks that are considered critical for the deployment
  # Example: ["portainer", "dockge"] identifies these stacks as critical
  CRITICAL_SERVICES_ARRAY=()
  CRITICAL_FAILURE=false
  if [ -n "$CRITICAL_SERVICES" ] && [ "$CRITICAL_SERVICES" != "[]" ]; then
    # Convert JSON array to bash array using jq for robust parsing and preserve spaces/special characters
    readarray -t CRITICAL_SERVICES_ARRAY < <(echo "$CRITICAL_SERVICES" | jq -r '.[]')
    echo "🚨 Critical stacks configured: ${CRITICAL_SERVICES_ARRAY[*]}"

    # Check if any failed rollback stack is critical
    for FAILED_STACK in $FAILED_ROLLBACKS; do
      for CRITICAL_STACK in "${CRITICAL_SERVICES_ARRAY[@]}"; do
        if [ "$FAILED_STACK" = "$CRITICAL_STACK" ]; then
          echo "🚨 CRITICAL STACK ROLLBACK FAILED: $FAILED_STACK"
          echo "   This is a critical stack - system may be in unsafe state"
          CRITICAL_FAILURE=true
        fi
      done
    done
  fi

  # Display all rollback logs
  echo ""
  echo "📋 Rollback Results:"
  echo "════════════════════════════════════════════════════════════════"
  # Parse null-delimited stacks into array
  readarray -d $'\0' -t ROLLBACK_STACKS_ARRAY <<< "$ROLLBACK_STACKS"
  for STACK in "${ROLLBACK_STACKS_ARRAY[@]}"; do
    if [ -f "/tmp/rollback_${STACK}.log" ]; then
      echo ""
      echo "🔸 ROLLBACK STACK: $STACK"
      echo "────────────────────────────────────────────────────────────────"
      cat "/tmp/rollback_${STACK}.log"
      echo "────────────────────────────────────────────────────────────────"
    else
      echo ""
      echo "🔸 ROLLBACK STACK: $STACK"
      echo "────────────────────────────────────────────────────────────────"
      echo "⚠️  No rollback log found for $STACK"
      echo "────────────────────────────────────────────────────────────────"
    fi
  done
  echo "════════════════════════════════════════════════════════════════"

  # Check if any rollbacks failed
  if [ -z "$ROLLBACK_STACKS" ]; then
    echo "💥 No stacks to rollback - ROLLBACK_STACKS variable is empty!"
    exit 1
  elif [ -z "$ROLLED_BACK_STACKS" ]; then
    echo "💥 No stacks were actually rolled back - check stack discovery!"
    exit 1
  elif [ "$CRITICAL_FAILURE" = true ]; then
    echo ""
    echo "💥 CRITICAL SERVICE ROLLBACK FAILURE"
    echo "   One or more critical services failed to rollback"
    echo "   System may be in an unsafe state - manual intervention required"
    echo "   Failed critical services:$FAILED_ROLLBACKS"
    exit 1
  elif [ -n "$FAILED_ROLLBACKS" ]; then
    echo "💥 Rollbacks failed for:$FAILED_ROLLBACKS"
    exit 1
  fi

  echo "🎉 All stacks rolled back successfully!"
EOF
)

# Extract rollback result and discovered stacks
echo "$ROLLBACK_RESULT"

# Parse discovered stacks output for rollback-health step
if echo "$ROLLBACK_RESULT" | grep -q "DISCOVERED_ROLLBACK_STACKS="; then
  DISCOVERED_STACKS=$(echo "$ROLLBACK_RESULT" | grep "DISCOVERED_ROLLBACK_STACKS=" | cut -d'=' -f2-)
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "discovered_rollback_stacks=$DISCOVERED_STACKS" >> "$GITHUB_OUTPUT"
  fi
  log_success "Captured discovered rollback stacks"
else
  log_warning "Could not parse discovered stacks from rollback output"
fi

log_success "Rollback completed successfully"
exit 0
