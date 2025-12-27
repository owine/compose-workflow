#!/usr/bin/env bash
# Common Utilities for Deployment Scripts
# Provides logging, validation, and helper functions

set -euo pipefail

# Logging functions with colors
log_info() {
  echo "ℹ️  $*"
}

log_success() {
  echo "✅ $*"
}

log_error() {
  echo "❌ $*" >&2
}

log_warning() {
  echo "⚠️  $*" >&2
}

# Set GitHub Actions output
set_github_output() {
  local key=$1
  local value=$2

  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "${key}=${value}" >> "$GITHUB_OUTPUT"
  fi
}

# Validate stack names (alphanumeric, dash, underscore only)
validate_stack_name() {
  local stack=$1

  if [[ ! "$stack" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    log_error "Invalid stack name: $stack (must be alphanumeric with dash/underscore)"
    return 1
  fi

  return 0
}

# Validate SHA format (40 hex characters)
validate_sha() {
  local sha=$1

  if [[ ! "$sha" =~ ^[a-fA-F0-9]{40}$ ]]; then
    log_error "Invalid SHA format: $sha (must be 40 hex characters)"
    return 1
  fi

  return 0
}

# Validate 1Password reference format
validate_op_reference() {
  local ref=$1

  if [[ ! "$ref" =~ ^op:// ]]; then
    log_error "Invalid 1Password reference: $ref (must start with op://)"
    return 1
  fi

  return 0
}

# Format list for output (space-separated to comma-separated)
format_list() {
  echo "$1" | tr ' ' ',' | sed 's/^,//;s/,/, /g'
}

# Check if variable is set and non-empty
require_var() {
  local var_name=$1
  local var_value="${!var_name:-}"

  if [ -z "$var_value" ]; then
    log_error "Required variable $var_name is not set"
    return 1
  fi

  return 0
}
