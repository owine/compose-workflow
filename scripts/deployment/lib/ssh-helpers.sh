#!/usr/bin/env bash
# SSH Helper Functions for Deployment Scripts
# Provides retry logic and SSH connection utilities

set -euo pipefail

# General retry function with exponential backoff
retry() {
  local max_attempts=$1
  local delay=$2
  local command="${*:3}"
  local attempt=1

  while [ "$attempt" -le "$max_attempts" ]; do
    echo "Attempt $attempt of $max_attempts: $command"
    if eval "$command"; then
      echo "✅ Command succeeded on attempt $attempt"
      return 0
    else
      echo "❌ Command failed on attempt $attempt"
      if [ "$attempt" -lt "$max_attempts" ]; then
        echo "⏳ Waiting ${delay}s before retry..."
        sleep "$delay"
        delay=$((delay * 2))  # Exponential backoff
      fi
      attempt=$((attempt + 1))
    fi
  done

  echo "💥 Command failed after $max_attempts attempts"
  return 1
}

# SSH retry function with specific error handling
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

      # Check for specific SSH errors
      case $last_exit_code in
        255) echo "SSH connection error - network/auth issue" >&2 ;;
        1) echo "General SSH error" >&2 ;;
        *) echo "Unknown error code: $last_exit_code" >&2 ;;
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

# Simple SSH execution wrapper
ssh_exec() {
  local ssh_user=$1
  local ssh_host=$2
  local command=$3

  ssh -o "StrictHostKeyChecking no" "${ssh_user}@${ssh_host}" "$command"
}
