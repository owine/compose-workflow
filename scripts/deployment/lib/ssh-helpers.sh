#!/usr/bin/env bash
# SSH Helper Functions for Deployment Scripts
# Provides retry logic and SSH connection utilities

set -euo pipefail

# SSH retry function with specific error handling
# IMPORTANT: Only retries on SSH connection errors (exit code 255).
# Script failures (exit code 1) are NOT retried because:
# 1. Script errors (validation failures, etc.) are not transient
# 2. Stdin content (heredocs) is consumed on first attempt and not available for retries
ssh_retry() {
  local max_attempts=$1
  local delay=$2
  local ssh_cmd="${*:3}"
  local attempt=1
  local last_exit_code=1

  while [ "$attempt" -le "$max_attempts" ]; do
    echo "SSH Attempt $attempt of $max_attempts" >&2
    if eval "$ssh_cmd"; then
      echo "✅ SSH command succeeded on attempt $attempt" >&2
      return 0
    else
      last_exit_code=$?
      echo "❌ SSH command failed on attempt $attempt (exit code: $last_exit_code)" >&2

      # Check for specific SSH errors and determine if retry is appropriate
      case $last_exit_code in
        255)
          # SSH connection error - network/auth issue, should retry
          echo "SSH connection error - network/auth issue (will retry)" >&2
          ;;
        1)
          # Script execution failed - do NOT retry
          # This prevents false successes when stdin (heredoc) content is consumed
          echo "Script execution failed - not retrying to prevent stdin consumption issues" >&2
          return $last_exit_code
          ;;
        *)
          # Unknown error - fail immediately
          echo "Unknown error code: $last_exit_code - not retrying" >&2
          return $last_exit_code
          ;;
      esac

      if [ "$attempt" -lt "$max_attempts" ]; then
        echo "⏳ Waiting ${delay}s before SSH retry..." >&2
        sleep "$delay"
      fi
      attempt=$((attempt + 1))
    fi
  done

  echo "💥 SSH command failed after $max_attempts attempts (final exit code: $last_exit_code)" >&2
  return $last_exit_code
}
