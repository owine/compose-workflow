#!/usr/bin/env bash
#
# Stack Validation Script
# Validates Docker Compose stacks with YAML linting and Docker Compose config validation
#
# Usage:
#   validate-stack.sh --stack STACK_NAME --yamllint-config CONFIG_FILE
#
# Exit codes:
#   0 - All validation checks passed
#   1 - Validation failures detected
#

set -euo pipefail

# Get script directory and source libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/env-helpers.sh
source "$SCRIPT_DIR/lib/env-helpers.sh"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# Parse arguments
STACK=""
YAMLLINT_CONFIG=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --stack)
      STACK="$2"
      shift 2
      ;;
    --yamllint-config)
      YAMLLINT_CONFIG="$2"
      shift 2
      ;;
    *)
      log_error "Unknown argument: $1"
      exit 1
      ;;
  esac
done

# Validate required arguments
require_var STACK
require_var YAMLLINT_CONFIG
validate_stack_name "$STACK"

# Set pipefail to capture exit codes correctly from pipelines
set -o pipefail

# Create temporary files for capturing output
YAML_OUTPUT=$(mktemp)
DOCKER_OUTPUT=$(mktemp)
DOCKER_FILTERED=$(mktemp)

echo "🔍 Starting validation for stack: $STACK"
print_separator
echo "📁 Stack: $STACK"
echo "📄 File: ./$STACK/compose.yaml"
echo ""

# Run YAML and Docker Compose linting in parallel with output capture
(set -o pipefail; yamllint --strict --config-file "$YAMLLINT_CONFIG" "./$STACK/compose.yaml" 2>&1 | tee "$YAML_OUTPUT") &
YAML_PID=$!

# Create temporary .env with placeholders to suppress environment variable warnings
TEMP_ENV=$(mktemp)
create_temp_env "./$STACK/compose.yaml" "$TEMP_ENV"

(set -o pipefail; docker compose --env-file "$TEMP_ENV" -f "./$STACK/compose.yaml" config 2>&1 | tee "$DOCKER_OUTPUT") &
DOCKER_PID=$!

# Wait for both processes and capture exit codes.
#
# `|| VAR=$?` is required, not stylistic: this script runs under `set -e`
# (line 14), so a bare `wait` on a failing child aborts the script right there
# - before the assignment, and before every formatted report below. That made
# the entire summary block unreachable for exactly the case it exists to
# serve: a stack that fails validation printed its raw tee'd output and then
# died silently, with no "Issues found", no fix hint and no overall status.
# The job still failed (non-zero exit), so CI verdicts were always correct -
# only the diagnostics were lost, which is why this went unnoticed.
YAML_EXIT=0
wait "$YAML_PID" || YAML_EXIT=$?

DOCKER_EXIT=0
wait "$DOCKER_PID" || DOCKER_EXIT=$?

# Filter Docker Compose output to remove environment variable warnings but keep real errors
if [ "$DOCKER_EXIT" -eq 0 ]; then
  # If Docker Compose succeeded, just copy the output
  cp "$DOCKER_OUTPUT" "$DOCKER_FILTERED"
else
  # If Docker Compose failed, filter out common environment variable warnings but keep errors
  # Compose 2.x prefixes these `WARNING: ...`; Compose 5.x emits
  # `time="..." level=warning msg="..."` instead. Match case-insensitively on
  # the bare token `warning`, which is a substring of both spellings, so the
  # filter keeps working across the engine versions in use. The `|| cp` retains
  # the original behaviour: if filtering removed every line, show the raw output.
  grep -viE 'warning.*(interpolat|environment variable|not set)' \
    "$DOCKER_OUTPUT" > "$DOCKER_FILTERED" || cp "$DOCKER_OUTPUT" "$DOCKER_FILTERED"
fi

# Cleanup temporary env file
rm -f "$TEMP_ENV"

echo ""
echo "📋 VALIDATION RESULTS SUMMARY"
print_separator

# Report YAML linting results with enhanced formatting
echo ""
echo "📝 YAML LINTING (yamllint)"
print_subseparator
if [ "$YAML_EXIT" -eq 0 ]; then
  log_success "PASSED - YAML syntax and formatting is valid"
else
  log_error "FAILED - YAML linting detected issues in ./$STACK/compose.yaml:"
  echo ""
  echo "🔍 Issues found:"
  sed 's/^/    /' "$YAML_OUTPUT" | sed 's|\.\/||g'
  echo ""
  echo "🛠️  Fix locally with:"
  echo "    yamllint --strict --config-file $YAMLLINT_CONFIG $STACK/compose.yaml"
fi

echo ""

# Report Docker Compose validation results
echo "🐳 DOCKER COMPOSE VALIDATION (docker compose config)"
print_subseparator
if [ "$DOCKER_EXIT" -eq 0 ]; then
  log_success "PASSED - Docker Compose configuration is valid"
else
  log_error "FAILED - Docker Compose validation detected issues in ./$STACK/compose.yaml:"
  echo ""
  echo "🔍 Issues found:"
  # Use filtered output to show relevant errors
  if [ -s "$DOCKER_FILTERED" ]; then
    sed 's/^/    /' "$DOCKER_FILTERED"
  else
    echo "    Configuration errors detected (see full output above)"
  fi
  echo ""
  echo "🛠️  Fix locally with:"
  echo "    docker compose -f $STACK/compose.yaml config"
fi

echo ""
print_separator

# Final status summary
if [ "$YAML_EXIT" -eq 0 ] && [ "$DOCKER_EXIT" -eq 0 ]; then
  echo "🎉 OVERALL STATUS: ALL VALIDATION CHECKS PASSED"
  echo "   Stack '$STACK' is ready for deployment"
else
  echo "💥 OVERALL STATUS: VALIDATION FAILED"
  echo "   Stack '$STACK' has configuration issues that must be resolved"
  echo ""
  echo "   Failed checks:"
  [ "$YAML_EXIT" -ne 0 ] && echo "   • YAML linting (yamllint)"
  [ "$DOCKER_EXIT" -ne 0 ] && echo "   • Docker Compose validation (docker compose config)"
fi

print_separator

# Cleanup temporary files
rm -f "$YAML_OUTPUT" "$DOCKER_OUTPUT" "$DOCKER_FILTERED"

# Exit with error if any linting failed
if [ "$YAML_EXIT" -ne 0 ] || [ "$DOCKER_EXIT" -ne 0 ]; then
  exit 1
fi
