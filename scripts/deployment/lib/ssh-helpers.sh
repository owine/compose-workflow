#!/usr/bin/env bash
# SSH Helper Functions for Deployment Scripts
# Provides retry logic and SSH connection utilities with consistent logging

set -euo pipefail

# Source common logging functions for consistent output
# Use unique variable name to avoid overwriting caller's SCRIPT_DIR
_SSH_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$_SSH_HELPERS_DIR/common.sh"
unset _SSH_HELPERS_DIR

# Allowlisted operation labels for safe context logging
# SECURITY: Only these hardcoded labels are ever output - never raw command content
# NOTE: Order matters - more specific patterns must come before general ones
readonly -a _SSH_OP_PATTERNS=(
  "health:health-check"
  "rollback:rollback"
  "cleanup:cleanup"
  "critical:detect-critical"
  "detect:detect"
  "dockge:dockge"
  "deploy:deploy"
)

# Safely determine operation context using allowlist only
# SECURITY: Never outputs any part of the actual command
# Arguments:
#   $1 - The SSH command string (used for pattern matching only)
# Returns:
#   Prints the safe operation label to stdout
_get_operation_context() {
  local cmd="$1"

  # Check environment override first (explicit is always safe)
  if [[ -n "${SSH_OPERATION_CONTEXT:-}" ]]; then
    echo "$SSH_OPERATION_CONTEXT"
    return
  fi

  # Match against allowlist patterns only
  local pattern_pair pattern label
  for pattern_pair in "${_SSH_OP_PATTERNS[@]}"; do
    pattern="${pattern_pair%%:*}"
    label="${pattern_pair##*:}"
    if [[ "$cmd" == *"$pattern"* ]]; then
      echo "$label"
      return
    fi
  done

  # Safe fallback - reveals nothing about command
  echo "ssh"
}

# SSH retry function with specific error handling and consistent logging
# IMPORTANT: Only retries on SSH connection errors (exit code 255).
# Script failures (exit code 1) are NOT retried because:
# 1. Script errors (validation failures, etc.) are not transient
# 2. Stdin content (heredocs) is consumed on first attempt and not available for retries
#
# Arguments:
#   $1 - max_attempts: Number of retry attempts
#   $2 - delay: Seconds to wait between retries
#   $3+ - ssh_cmd: The SSH command to execute
#
# Environment:
#   SSH_OPERATION_CONTEXT - Optional explicit operation label (overrides auto-detect)
ssh_retry() {
  local max_attempts=$1
  local delay=$2
  local ssh_cmd="${*:3}"
  local attempt=1
  local last_exit_code=1

  # SECURITY: Context derived from allowlist only, never from raw command
  local op
  op=$(_get_operation_context "$ssh_cmd")

  while [ "$attempt" -le "$max_attempts" ]; do
    log_info "SSH attempt $attempt/$max_attempts [$op]"
    if eval "$ssh_cmd"; then
      log_success "SSH [$op] succeeded on attempt $attempt"
      return 0
    else
      last_exit_code=$?
      log_error "SSH [$op] failed on attempt $attempt (exit: $last_exit_code)"

      # Check for specific SSH errors and determine if retry is appropriate
      case $last_exit_code in
        255)
          # SSH connection error - network/auth issue, should retry
          log_warning "Connection error - will retry"
          ;;
        1)
          # Script execution failed - do NOT retry
          # This prevents false successes when stdin (heredoc) content is consumed
          log_error "Script execution failed - not retrying"
          return $last_exit_code
          ;;
        *)
          # Unknown error - fail immediately
          log_error "Unknown error: $last_exit_code - not retrying"
          return $last_exit_code
          ;;
      esac

      if [ "$attempt" -lt "$max_attempts" ]; then
        log_info "Waiting ${delay}s before retry..."
        sleep "$delay"
      fi
      attempt=$((attempt + 1))
    fi
  done

  log_error "SSH [$op] failed after $max_attempts attempts (exit: $last_exit_code)"
  return $last_exit_code
}
