#!/usr/bin/env bash
#
# Lint Summary Script
# Generates comprehensive validation summary with error reproduction
#
# Usage:
#   lint-summary.sh --stacks JSON_ARRAY --yamllint-config CONFIG_FILE \
#                   --actionlint-result RESULT --lint-result RESULT
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
STACKS_JSON=""
YAMLLINT_CONFIG=""
ACTIONLINT_RESULT=""
LINT_RESULT=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --stacks)
      STACKS_JSON="$2"
      shift 2
      ;;
    --yamllint-config)
      YAMLLINT_CONFIG="$2"
      shift 2
      ;;
    --actionlint-result)
      ACTIONLINT_RESULT="$2"
      shift 2
      ;;
    --lint-result)
      LINT_RESULT="$2"
      shift 2
      ;;
    *)
      log_error "Unknown argument: $1"
      exit 1
      ;;
  esac
done

# Validate required arguments
require_var STACKS_JSON
require_var YAMLLINT_CONFIG
require_var ACTIONLINT_RESULT
require_var LINT_RESULT

echo "📊 Final Validation Summary"
echo ""
echo "🔍 COMPREHENSIVE VALIDATION RESULTS"
print_separator
echo ""

# Actionlint Workflow Validation Results
echo "⚙️  WORKFLOW VALIDATION (ACTIONLINT)"
print_subseparator
case "$ACTIONLINT_RESULT" in
  "success")
    log_success "PASSED - All GitHub Actions workflows are valid"
    ACTIONLINT_OK=true
    ;;
  "failure")
    log_error "FAILED - Workflow validation issues detected"
    ACTIONLINT_OK=false
    ;;
  *)
    log_warning "UNKNOWN - Unexpected actionlint result: $ACTIONLINT_RESULT"
    ACTIONLINT_OK=false
    ;;
esac

echo ""

# Detailed Lint Results with Error Reproduction
echo "📋 CODE QUALITY VALIDATION - DETAILED RESULTS"
print_subseparator

# Parse stacks from input
echo "📁 Analyzing stacks: $(echo "$STACKS_JSON" | jq -r 'join(", ")')"
echo ""

LINT_OK=true

# Process each stack and reproduce errors if validation failed
echo "$STACKS_JSON" | jq -r '.[]' | while read -r stack; do
  echo "🔍 Checking stack: $stack"
  echo "📄 File: ./$stack/compose.yaml"

  # Check if stack file exists
  if [[ ! -f "./$stack/compose.yaml" ]]; then
    log_error "ERROR: Stack file ./$stack/compose.yaml not found"
    continue
  fi

  STACK_FAILED=false

  # Run YAML validation
  echo ""
  echo "   📝 YAML Linting (yamllint):"
  if yamllint --strict --config-file "$YAMLLINT_CONFIG" "./$stack/compose.yaml" 2>/dev/null; then
    echo "   ✅ PASSED - YAML validation successful"
  else
    echo "   ❌ FAILED - YAML validation detected issues:"
    echo ""
    # shellcheck disable=SC2001  # sed is appropriate for multi-line prefix addition
    yamllint --strict --config-file "$YAMLLINT_CONFIG" "./$stack/compose.yaml" 2>&1 | sed 's/^/      /' | sed 's|\.\/||g'
    echo ""
    echo "   🛠️  Fix locally: yamllint --strict --config-file $YAMLLINT_CONFIG $stack/compose.yaml"
    STACK_FAILED=true
  fi

  echo ""
  echo "   🐳 Docker Compose Validation:"

  # Create temporary .env with placeholders to suppress environment variable warnings
  TEMP_ENV=$(mktemp)
  create_temp_env "./$stack/compose.yaml" "$TEMP_ENV"

  if docker compose --env-file "$TEMP_ENV" -f "./$stack/compose.yaml" config >/dev/null 2>&1; then
    echo "   ✅ PASSED - Docker Compose validation successful"
  else
    echo "   ❌ FAILED - Docker Compose validation detected issues:"
    echo ""
    # Show filtered errors (remove environment variable warnings)
    DOCKER_ERRORS=$(docker compose --env-file "$TEMP_ENV" -f "./$stack/compose.yaml" config 2>&1 | \
      grep -v "WARNING.*interpolat" | \
      grep -v "WARNING.*environment variable" | \
      grep -v "WARNING.*not set" || echo "Configuration errors detected")

    if [[ -n "$DOCKER_ERRORS" && "$DOCKER_ERRORS" != "Configuration errors detected" ]]; then
      # shellcheck disable=SC2001  # sed is appropriate for multi-line prefix addition
      sed 's/^/      /' <<< "$DOCKER_ERRORS"
    else
      echo "      Configuration syntax or structure issues detected"
    fi
    echo ""
    echo "   🛠️  Fix locally: docker compose -f $stack/compose.yaml config"
    STACK_FAILED=true
  fi

  rm -f "$TEMP_ENV"

  if [[ "$STACK_FAILED" == "true" ]]; then
    echo "   🚨 Stack $stack has validation failures"
  else
    echo "   ✅ Stack $stack passed all validations"
  fi

  echo ""
  print_subseparator
done

echo ""

# Overall Results Summary
if [[ "$LINT_RESULT" == "success" ]]; then
  log_success "ALL STACKS PASSED - YAML and Docker Compose validations successful"
  LINT_OK=true
else
  log_error "VALIDATION FAILURES DETECTED"
  echo ""
  echo "🚨 Failed Stacks Summary:"
  # Re-check for any failures to show summary
  echo "$STACKS_JSON" | jq -r '.[]' | while read -r stack; do
    FAILED_CHECKS=()

    if ! yamllint --strict --config-file "$YAMLLINT_CONFIG" "./$stack/compose.yaml" >/dev/null 2>&1; then
      FAILED_CHECKS+=("YAML linting")
    fi

    TEMP_ENV=$(mktemp)
    create_temp_env "./$stack/compose.yaml" "$TEMP_ENV"

    if ! docker compose --env-file "$TEMP_ENV" -f "./$stack/compose.yaml" config >/dev/null 2>&1; then
      FAILED_CHECKS+=("Docker Compose validation")
    fi
    rm -f "$TEMP_ENV"

    if [[ ${#FAILED_CHECKS[@]} -gt 0 ]]; then
      echo "   • $stack - $(IFS=', '; echo "${FAILED_CHECKS[*]}")"
    fi
  done
  LINT_OK=false
fi

echo ""
print_separator

# Final determination
if [[ "$ACTIONLINT_OK" == "true" && "$LINT_OK" == "true" ]]; then
  echo "🎉 FINAL STATUS: ALL VALIDATION CHECKS PASSED"
  echo "   Repository is ready for deployment"
  exit 0
else
  echo "💥 FINAL STATUS: VALIDATION FAILED"
  echo "   Issues must be resolved before deployment"
  echo ""
  echo "   Failed components:"
  [[ "$ACTIONLINT_OK" != "true" ]] && echo "   • Workflow validation (actionlint)"
  [[ "$LINT_OK" != "true" ]] && echo "   • Code quality validation (see detailed errors above)"
  echo ""
  exit 1
fi
