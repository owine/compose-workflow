#!/usr/bin/env bash
#
# Common Utilities for Linting Scripts
# Provides logging, validation, and helper functions
#

set -euo pipefail

# Logging functions with colors
# All log functions output to stderr to avoid corrupting command output capture
log_info() {
  echo "ℹ️  $*" >&2
}

log_success() {
  echo "✅ $*" >&2
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

# Format list for output (space-separated to comma-separated)
format_list() {
  echo "$1" | tr ' ' ',' | sed 's/^,//;s/,/, /g'
}

# Print section separator
print_separator() {
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Print subsection separator
print_subseparator() {
  echo "───────────────────────────────────────────────────────────────────────────────────"
}
