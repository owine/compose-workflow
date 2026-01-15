#!/usr/bin/env bash
# Script Name: health-check.sh
# Purpose: Report health status of Docker Compose stacks after --wait flag deployment
# Usage: ./health-check.sh --stacks "stack1 stack2" --has-dockge true --ssh-user user --ssh-host host --op-token token --command-timeout 15
#
# Note: This script is optimized to work with Docker Compose v5 --wait flag integration.
#       The --wait flag handles waiting for services to become healthy during deployment.
#       This script performs a single-pass status check and reporting, without retry loops.

set -euo pipefail

# Get script directory and source libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ssh-helpers.sh
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/ssh-helpers.sh"
source "$SCRIPT_DIR/lib/common.sh"

# Default values
STACKS=""
HAS_DOCKGE="false"
SSH_USER=""
SSH_HOST=""
OP_TOKEN=""
COMMAND_TIMEOUT="15"
CRITICAL_SERVICES="[]"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --stacks)
      STACKS="$2"
      shift 2
      ;;
    --has-dockge)
      HAS_DOCKGE="$2"
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
    --command-timeout)
      COMMAND_TIMEOUT="$2"
      shift 2
      ;;
    --critical-services)
      CRITICAL_SERVICES="$2"
      shift 2
      ;;
    --health-timeout)
      # Deprecated parameter - ignored for backward compatibility
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

log_info "Starting health status check for stacks: $STACKS"
log_info "Command timeout: ${COMMAND_TIMEOUT}s"

# Execute health check via SSH with retry
# Use printf %q to properly escape arguments for eval in ssh_retry
# shellcheck disable=SC2086 # Word splitting is intentional for printf to process each stack
STACKS_ESCAPED=$(printf '%q ' $STACKS)
HAS_DOCKGE_ESCAPED=$(printf '%q' "$HAS_DOCKGE")

# Base64 encode CRITICAL_SERVICES to prevent shell glob expansion
# Remote shells (especially zsh) treat [] as glob patterns, causing failures
CRITICAL_SERVICES_B64=$(echo -n "$CRITICAL_SERVICES" | base64 -w 0 2>/dev/null || echo -n "$CRITICAL_SERVICES" | base64)

# Pass OP_TOKEN as positional argument (more secure than env vars in process list)
# Token passed as $1, appears in SSH command locally but not in remote ps output
# Use temporary file to capture output and avoid command substitution parsing issues
HEALTH_TMPFILE=$(mktemp)
set +e
{
  cat << 'EOF'
  set -e

  # Get OP_TOKEN from first positional argument (passed securely via SSH)
  OP_SERVICE_ACCOUNT_TOKEN="$1"

  # Decode base64-encoded CRITICAL_SERVICES
  CRITICAL_SERVICES=$(echo "$CRITICAL_SERVICES_B64" | base64 -d)
  export OP_SERVICE_ACCOUNT_TOKEN

  # Shift to get actual script arguments (stacks, has-dockge)
  shift

  # Get arguments passed to script (excluding sensitive OP_TOKEN)
  TOTAL_ARGS=$#

  # Find HAS_DOCKGE by looking for 'true' or 'false' in the args
  HAS_DOCKGE=""

  for i in $(seq 1 $TOTAL_ARGS); do
    ARG="${!i}"
    if [ "$ARG" = "true" ] || [ "$ARG" = "false" ]; then
      HAS_DOCKGE="$ARG"
      # All args before this position are stack names
      STACKS="${@:1:$((i-1))}"
      break
    fi
  done

  # Set timeout configuration with defaults
  HEALTH_CHECK_CMD_TIMEOUT=${COMMAND_TIMEOUT:-15}

  echo "🔍 Starting health status check (post --wait deployment)..."

  # Health check function - single-pass status collection
  # Note: --wait flag already ensured services are healthy during deployment
  # This function collects current status for reporting and metrics
  check_stack_health() {
    local stack=$1
    local logfile="/tmp/health_${stack}.log"

    # Create log file and redirect all output
    exec 3>&1 4>&2
    exec 1>"$logfile" 2>&1

    # Ensure file descriptors are restored on function exit
    trap 'exec 1>&3 2>&4 3>&- 4>&-' RETURN

    echo "🔍 Checking health status for $stack..."

    cd "/opt/compose/$stack" || {
      echo "❌ $stack: Directory not found"
      return 1
    }

    # Get total service count
    local total_count
    total_count=$(timeout $HEALTH_CHECK_CMD_TIMEOUT op run --no-masking --env-file=/opt/compose/compose.env -- docker compose -f compose.yaml config --services 2>/dev/null | grep -E '^[a-zA-Z0-9_-]+$' | wc -l | tr -d " " || echo "0")

    if [ "$total_count" -eq 0 ]; then
      echo "❌ $stack: No services defined in compose file"
      return 1
    fi

    # Get container state and health in one call using custom format
    # Format: Service State Health (tab-separated)
    local ps_output
    ps_output=$(timeout $HEALTH_CHECK_CMD_TIMEOUT op run --no-masking --env-file=/opt/compose/compose.env -- docker compose -f compose.yaml ps --format '{{.Service}}\t{{.State}}\t{{.Health}}' 2>/dev/null || echo "")

    # Parse output to count different states and health conditions
    local running_healthy=0
    local running_starting=0
    local running_unhealthy=0
    local running_no_health=0
    local exited_count=0
    local restarting_count=0

    while IFS=$'\t' read -r service state health; do
      # Skip empty lines
      [ -z "$service" ] && continue

      case "$state" in
        running)
          case "$health" in
            healthy)
              running_healthy=$((running_healthy + 1))
              ;;
            starting)
              running_starting=$((running_starting + 1))
              ;;
            unhealthy)
              running_unhealthy=$((running_unhealthy + 1))
              ;;
            *)
              # No health check defined
              running_no_health=$((running_no_health + 1))
              ;;
          esac
          ;;
        exited)
          exited_count=$((exited_count + 1))
          ;;
        restarting)
          restarting_count=$((restarting_count + 1))
          ;;
      esac
    done <<< "$ps_output"

    # Total running containers (all health states)
    local running_count=$((running_healthy + running_starting + running_unhealthy + running_no_health))

    echo "$stack status: $running_count/$total_count running (healthy: $running_healthy, starting: $running_starting, unhealthy: $running_unhealthy, no-check: $running_no_health), exited: $exited_count, restarting: $restarting_count"

    # Fast fail on detection of unhealthy containers
    if [ "$running_unhealthy" -gt 0 ]; then
      echo "❌ $stack: $running_unhealthy unhealthy containers detected"
      return 1
    fi

    # Calculate healthy containers (healthy + no health check defined)
    local healthy_total=$((running_healthy + running_no_health))

    # Success condition: all containers running and healthy (or no health check)
    if [ "$healthy_total" -eq "$total_count" ] && [ "$total_count" -gt 0 ] && [ "$running_starting" -eq 0 ] && [ "$exited_count" -eq 0 ] && [ "$restarting_count" -eq 0 ]; then
      echo "✅ $stack: All $total_count services healthy"
      return 0
    # Degraded but stable: all running and healthy, but fewer than expected
    elif [ "$healthy_total" -gt 0 ] && [ "$healthy_total" -eq "$running_count" ] && [ "$running_starting" -eq 0 ] && [ "$exited_count" -eq 0 ] && [ "$restarting_count" -eq 0 ]; then
      echo "⚠️ $stack: $healthy_total/$total_count services healthy (degraded but stable)"
      return 2  # Degraded but acceptable
    # Services still starting after --wait completed
    elif [ "$running_starting" -gt 0 ]; then
      echo "⚠️ $stack: $running_starting services still in 'starting' state"
      return 1
    # Other failure scenarios
    else
      echo "❌ $stack: Failed ($running_count/$total_count running, $healthy_total healthy)"
      return 1
    fi
  }

  FAILED_STACKS=""
  DEGRADED_STACKS=""
  HEALTHY_STACKS=""
  TOTAL_CONTAINERS=0
  RUNNING_CONTAINERS=0

  if [ "$HAS_DOCKGE" = "true" ]; then
    echo "🔍 Checking Dockge health status..."
    cd /opt/dockge

    # Get total services
    DOCKGE_TOTAL=$(timeout $HEALTH_CHECK_CMD_TIMEOUT op run --no-masking --env-file=/opt/compose/compose.env -- docker compose config --services 2>/dev/null | wc -l | tr -d " " || echo "0")

    # Get Dockge state and health
    dockge_ps_output=$(timeout $HEALTH_CHECK_CMD_TIMEOUT op run --no-masking --env-file=/opt/compose/compose.env -- docker compose ps --format '{{.Service}}\t{{.State}}\t{{.Health}}' 2>/dev/null || echo "")

    # Parse health states
    dockge_healthy=0
    dockge_starting=0
    dockge_unhealthy=0
    dockge_no_health=0

    while IFS=$'\t' read -r service state health; do
      [ -z "$service" ] && continue
      if [ "$state" = "running" ]; then
        case "$health" in
          healthy) dockge_healthy=$((dockge_healthy + 1)) ;;
          starting) dockge_starting=$((dockge_starting + 1)) ;;
          unhealthy) dockge_unhealthy=$((dockge_unhealthy + 1)) ;;
          *) dockge_no_health=$((dockge_no_health + 1)) ;;
        esac
      fi
    done <<< "$dockge_ps_output"

    dockge_running=$((dockge_healthy + dockge_starting + dockge_unhealthy + dockge_no_health))
    dockge_healthy_total=$((dockge_healthy + dockge_no_health))

    echo "Dockge: $dockge_running/$DOCKGE_TOTAL running (healthy: $dockge_healthy, starting: $dockge_starting, unhealthy: $dockge_unhealthy, no-check: $dockge_no_health)"

    TOTAL_CONTAINERS=$((TOTAL_CONTAINERS + DOCKGE_TOTAL))
    RUNNING_CONTAINERS=$((RUNNING_CONTAINERS + dockge_running))

    if [ "$dockge_unhealthy" -gt 0 ]; then
      echo "❌ Dockge: $dockge_unhealthy services unhealthy"
      FAILED_STACKS="$FAILED_STACKS dockge"
    elif [ "$dockge_running" -eq 0 ]; then
      echo "❌ Dockge: 0/$DOCKGE_TOTAL services running"
      FAILED_STACKS="$FAILED_STACKS dockge"
    elif [ "$dockge_healthy_total" -eq "$DOCKGE_TOTAL" ] && [ "$dockge_starting" -eq 0 ]; then
      echo "✅ Dockge: All $DOCKGE_TOTAL services healthy"
      HEALTHY_STACKS="$HEALTHY_STACKS dockge"
    else
      echo "⚠️ Dockge: $dockge_healthy_total/$DOCKGE_TOTAL services healthy (degraded)"
      DEGRADED_STACKS="$DEGRADED_STACKS dockge"
    fi
  fi


  # Parse critical services list
  # Note: CRITICAL_SERVICES contains stack names (not individual Docker service names)
  # This matches stacks that are considered critical for the deployment
  # Example: ["portainer", "dockge"] identifies these stacks as critical
  CRITICAL_SERVICES_ARRAY=()
  if [ -n "$CRITICAL_SERVICES" ] && [ "$CRITICAL_SERVICES" != "[]" ]; then
    # Convert JSON array to bash array using jq for robust parsing and preserve spaces/special characters
    readarray -t CRITICAL_SERVICES_ARRAY < <(echo "$CRITICAL_SERVICES" | jq -r '.[]')
    echo "🚨 Critical stacks configured: ${CRITICAL_SERVICES_ARRAY[*]}"
  fi

  # Function to check if a stack is critical
  # Parameter: stack name to check
  # Returns: 0 if critical, 1 if not critical
  is_critical_service() {
    local stack_name=$1
    for critical in "${CRITICAL_SERVICES_ARRAY[@]}"; do
      if [ "$stack_name" = "$critical" ]; then
        return 0
      fi
    done
    return 1
  }

  # Health status checks with early exit for critical failures
  echo "🔍 Checking health status for all stacks..."
  CRITICAL_FAILURE=false

  # Disable exit on error for health checks to ensure we reach output section
  set +e

  # Check each stack
  for STACK in $STACKS; do
    echo ""
    echo "🔍 Checking stack: $STACK"

    check_stack_health "$STACK"
    HEALTH_RESULT=$?

    case $HEALTH_RESULT in
      0)
        # Output already restored in check_stack_health
        echo "✅ $STACK: Healthy"
        HEALTHY_STACKS="$HEALTHY_STACKS $STACK"
        ;;
      2)
        # Output already restored in check_stack_health
        echo "⚠️ $STACK: Degraded but stable"
        DEGRADED_STACKS="$DEGRADED_STACKS $STACK"
        # Check if degraded stack is critical
        if is_critical_service "$STACK"; then
          echo "🚨 CRITICAL SERVICE DEGRADED: $STACK"
          echo "   Continuing monitoring but flagging for attention"
        fi
        ;;
      *)
        # For failures, output is already restored in check_stack_health
        echo "❌ $STACK: Failed health check"
        FAILED_STACKS="$FAILED_STACKS $STACK"
        # Check if failed stack is critical - trigger early exit
        if is_critical_service "$STACK"; then
          echo "🚨 CRITICAL SERVICE FAILURE: $STACK"
          echo "   This is a critical service failure - triggering early exit"
          echo "   Remaining stacks will not be health checked"
          CRITICAL_FAILURE=true
          break
        fi
        ;;
    esac
  done

  # Count services across all stacks after health checks complete
  echo ""
  echo "📊 Counting services across all stacks..."

  if [ -z "$STACKS" ]; then
    echo "ERROR: STACKS variable is empty! Cannot count services."
    echo "Will attempt to discover stacks from filesystem..."
    DISCOVERED_STACKS=""
    for dir in /opt/compose/*/; do
      if [ -d "$dir" ] && [ -f "$dir/compose.yaml" ]; then
        STACK_NAME=$(basename "$dir")
        DISCOVERED_STACKS="$DISCOVERED_STACKS $STACK_NAME"
      fi
    done
    STACKS=$(echo "$DISCOVERED_STACKS" | xargs)
    echo "Discovered stacks: $STACKS"
  fi

  for STACK in $STACKS; do
    STACK_RUNNING=$(cd /opt/compose/$STACK 2>/dev/null && op run --no-masking --env-file=/opt/compose/compose.env -- docker compose -f compose.yaml ps --services --filter "status=running" 2>/dev/null | grep -E '^[a-zA-Z0-9_-]+$' 2>/dev/null | wc -l | tr -d " " || echo "0")
    STACK_TOTAL=$(cd /opt/compose/$STACK 2>/dev/null && op run --no-masking --env-file=/opt/compose/compose.env -- docker compose -f compose.yaml config --services 2>/dev/null | grep -E '^[a-zA-Z0-9_-]+$' 2>/dev/null | wc -l | tr -d " " || echo "0")
    echo "  $STACK: $STACK_RUNNING/$STACK_TOTAL services"
    TOTAL_CONTAINERS=$((TOTAL_CONTAINERS + STACK_TOTAL))
    RUNNING_CONTAINERS=$((RUNNING_CONTAINERS + STACK_RUNNING))
  done

  # Write outputs to temp file to ensure capture even if script exits early
  TEMP_OUTPUT="/tmp/github_health_check_outputs.txt"
  echo "healthy_stacks=$(echo $HEALTHY_STACKS | tr ' ' ',' | sed 's/^,//' | sed 's/,/, /g')" > "$TEMP_OUTPUT"
  echo "degraded_stacks=$(echo $DEGRADED_STACKS | tr ' ' ',' | sed 's/^,//' | sed 's/,/, /g')" >> "$TEMP_OUTPUT"
  echo "failed_stacks=$(echo $FAILED_STACKS | tr ' ' ',' | sed 's/^,//' | sed 's/,/, /g')" >> "$TEMP_OUTPUT"
  echo "total_containers=$TOTAL_CONTAINERS" >> "$TEMP_OUTPUT"
  echo "running_containers=$RUNNING_CONTAINERS" >> "$TEMP_OUTPUT"
  if [ "$TOTAL_CONTAINERS" -gt 0 ]; then
    echo "success_rate=$(( RUNNING_CONTAINERS * 100 / TOTAL_CONTAINERS ))" >> "$TEMP_OUTPUT"
  else
    echo "success_rate=0" >> "$TEMP_OUTPUT"
  fi

  # Handle critical service failure
  if [ "$CRITICAL_FAILURE" = true ]; then
    echo ""
    echo "❌ CRITICAL SERVICE FAILURE DETECTED"
    echo "   Deployment marked as failed due to critical service failure"
    echo "   Health check terminated early to prevent extended failure cycles"
    # Output marker for critical failure
    echo "CRITICAL_FAILURE=true"
    exit 1
  fi

  echo "📊 Total service count: $RUNNING_CONTAINERS/$TOTAL_CONTAINERS across all stacks"

  # Display comprehensive health check results
  echo ""
  echo "📊 Health Check Summary:"
  echo "════════════════════════"
  echo "Total Services: $TOTAL_CONTAINERS"
  echo "Running Services: $RUNNING_CONTAINERS"
  if [ "$TOTAL_CONTAINERS" -gt 0 ]; then
    echo "Success Rate: $(( RUNNING_CONTAINERS * 100 / TOTAL_CONTAINERS ))%"
  else
    echo "Success Rate: 0%"
  fi
  echo ""

  # Display results by category
  [ -n "$HEALTHY_STACKS" ] && echo "✅ Healthy Stacks: $(echo $HEALTHY_STACKS | tr ' ' ',' | sed 's/^,//' | sed 's/,/, /g')"
  [ -n "$DEGRADED_STACKS" ] && echo "⚠️ Degraded Stacks: $(echo $DEGRADED_STACKS | tr ' ' ',' | sed 's/^,//' | sed 's/,/, /g')"
  [ -n "$FAILED_STACKS" ] && echo "❌ Failed Stacks: $(echo $FAILED_STACKS | tr ' ' ',' | sed 's/^,//' | sed 's/,/, /g')"

  echo ""
  echo "📋 Detailed Health Check Results:"
  echo "════════════════════════════════════════════════════════════════"
  for STACK in $STACKS; do
    if [ -f "/tmp/health_${STACK}.log" ]; then
      echo ""
      echo "🔸 STACK: $STACK"
      echo "────────────────────────────────────────────────────────────────"
      cat "/tmp/health_${STACK}.log"
      echo "────────────────────────────────────────────────────────────────"
    else
      echo ""
      echo "🔸 STACK: $STACK"
      echo "────────────────────────────────────────────────────────────────"
      echo "⚠️  No health check log found for $STACK"
      echo "────────────────────────────────────────────────────────────────"
    fi
  done
  echo "════════════════════════════════════════════════════════════════"

  # Output results in parseable format (temp file already written earlier)
  echo "GITHUB_OUTPUT_START"
  cat "$TEMP_OUTPUT"
  echo "GITHUB_OUTPUT_END"

  set -e  # Re-enable exit on error after outputs are written

  # Determine final health status
  if [ -n "$FAILED_STACKS" ]; then
    echo ""
    echo "💥 Health check failed - some stacks are not running"
    exit 1
  elif [ -n "$DEGRADED_STACKS" ]; then
    echo ""
    echo "⚠️ Health check passed with warnings - some services degraded"
    exit 0
  else
    echo ""
    echo "🎉 All services are fully healthy!"
    exit 0
  fi
EOF
} | ssh_retry 3 5 "ssh $SSH_USER@$SSH_HOST env COMMAND_TIMEOUT=\"$COMMAND_TIMEOUT\" CRITICAL_SERVICES_B64=\"$CRITICAL_SERVICES_B64\" /bin/bash -s \"$OP_TOKEN\" $STACKS_ESCAPED $HAS_DOCKGE_ESCAPED" > "$HEALTH_TMPFILE"
HEALTH_EXIT_CODE=$?
HEALTH_RESULT=$(cat "$HEALTH_TMPFILE")
rm -f "$HEALTH_TMPFILE"
set -e

# Check if health check command failed
if [ $HEALTH_EXIT_CODE -ne 0 ]; then
  log_error "Health check failed with exit code: $HEALTH_EXIT_CODE"
  # Still extract outputs for debugging before failing
  echo "$HEALTH_RESULT"
  if echo "$HEALTH_RESULT" | grep -q "GITHUB_OUTPUT_START"; then
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
      echo "$HEALTH_RESULT" | sed -n '/GITHUB_OUTPUT_START/,/GITHUB_OUTPUT_END/p' | grep -E "^(healthy_stacks|degraded_stacks|failed_stacks|total_containers|running_containers|success_rate)=" >> "$GITHUB_OUTPUT" || true
    fi
  fi
  exit 1
fi

# Extract health outputs from structured result
echo "$HEALTH_RESULT"

# Parse outputs and set GitHub Actions outputs
if echo "$HEALTH_RESULT" | grep -q "GITHUB_OUTPUT_START"; then
  # Extract outputs from structured section
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "$HEALTH_RESULT" | sed -n '/GITHUB_OUTPUT_START/,/GITHUB_OUTPUT_END/p' | grep -E "^(healthy_stacks|degraded_stacks|failed_stacks|total_containers|running_containers|success_rate)=" >> "$GITHUB_OUTPUT"
  fi
else
  log_warning "GITHUB_OUTPUT_START marker not found, attempting to read from temp file..."
  # Try to read from temp file on remote server
  TEMP_FILE_CONTENT=$(ssh -o "StrictHostKeyChecking no" "$SSH_USER@$SSH_HOST" 'cat /tmp/github_health_check_outputs.txt 2>/dev/null' || echo "")

  if [ -n "$TEMP_FILE_CONTENT" ]; then
    log_success "Successfully read outputs from temp file"
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
      echo "$TEMP_FILE_CONTENT" >> "$GITHUB_OUTPUT"
    fi
  else
    log_error "Could not read temp file, using fallback outputs"
    # Fallback outputs if parsing fails
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
      {
        echo "healthy_stacks="
        echo "degraded_stacks="
        echo "failed_stacks="
        echo "total_containers=0"
        echo "running_containers=0"
        echo "success_rate=0"
      } >> "$GITHUB_OUTPUT"
    fi
  fi
fi

log_success "Health check completed successfully"
exit 0
