#!/usr/bin/env bash
#
# Environment Helper Functions for Linting Operations
# Provides utilities for creating temporary environment files for Docker Compose validation
#

set -euo pipefail

# Function to create temporary environment file with placeholder values
# This allows Docker Compose validation without requiring actual secrets
#
# Args:
#   $1 - Path to the compose file to extract variables from
#   $2 - Path to the temporary environment file to create
#
# Behavior:
#   - Extracts all ${VAR} references from the compose file
#   - Creates realistic placeholder values based on variable name patterns
#   - Writes placeholders to the temporary environment file
#
create_temp_env() {
  local compose_file="$1"
  local temp_env_file="$2"

  # Extract environment variable references from compose file and create realistic placeholders
  while IFS= read -r match; do
    # Remove ${ prefix and } suffix using parameter expansion
    var="${match#\$\{}"
    var="${var%\}}"

    # Use realistic placeholder values based on common variable patterns
    case "$var" in
      *PATH*|*DIR*)
        echo "${var}=/tmp/placeholder" >> "$temp_env_file"
        ;;
      *DOMAIN*)
        echo "${var}=example.com" >> "$temp_env_file"
        ;;
      *PORT*)
        echo "${var}=8080" >> "$temp_env_file"
        ;;
      *KEY*|*SECRET*|*TOKEN*|*PASS*)
        echo "${var}=placeholder-secret-value" >> "$temp_env_file"
        ;;
      *URL*|*HOST*)
        echo "${var}=http://localhost:8080" >> "$temp_env_file"
        ;;
      UID|PUID)
        echo "${var}=1000" >> "$temp_env_file"
        ;;
      GID|PGID)
        echo "${var}=1000" >> "$temp_env_file"
        ;;
      TZ)
        echo "${var}=UTC" >> "$temp_env_file"
        ;;
      *)
        echo "${var}=placeholder_value" >> "$temp_env_file"
        ;;
    esac
  done < <(grep -oE '\$\{[^}]+\}' "$compose_file" | sort -u) 2>/dev/null || true
}
