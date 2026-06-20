#!/usr/bin/env bash
#
# Renovate Config Validation Script
# Validates a repository's Renovate configuration with renovate-config-validator.
#
# The validator ships in the `renovate` npm package and is run via npx pinned to
# `renovate@latest`, so validation always matches what the hosted Renovate app
# will actually run — without committing renovate as a tracked dependency.
# `renovate@latest` also defeats any stale npx cache.
#
# Usage:
#   validate-renovate.sh
#
# Run from the repository root. The validator is invoked with NO filename
# argument on purpose: with a filename it treats the file as GLOBAL self-hosted
# config (flagging repo-level options as errors), whereas auto-discovery of the
# default config locations validates them as repo-level config — which is what
# these repos contain.
#
# Exit codes:
#   0 - Config valid (or no Renovate config present to validate)
#   1 - Config invalid / validation failed
#

set -euo pipefail

# Get script directory and source libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# Pin the validator to the latest published Renovate so it matches the hosted
# app's behaviour. `--yes` skips the npx install prompt.
RENOVATE_PKG="renovate@latest"

# Renovate's default config file locations (repo-level), in resolution order.
# Used only to decide whether a config exists — the validator itself does the
# authoritative auto-discovery when invoked with no filename argument.
DEFAULT_CONFIG_LOCATIONS=(
  "renovate.json"
  "renovate.json5"
  ".github/renovate.json"
  ".github/renovate.json5"
  ".gitlab/renovate.json"
  ".gitlab/renovate.json5"
  ".renovaterc"
  ".renovaterc.json"
  ".renovaterc.json5"
)

echo "🔍 Starting Renovate config validation"
print_separator

# Skip (don't fail) when a repo simply has no Renovate config.
found_config=""
for loc in "${DEFAULT_CONFIG_LOCATIONS[@]}"; do
  if [[ -f "$loc" ]]; then
    found_config="$loc"
    break
  fi
done

if [[ -z "$found_config" ]]; then
  log_warning "No Renovate config found in default locations — skipping validation"
  echo "   Checked: ${DEFAULT_CONFIG_LOCATIONS[*]}"
  exit 0
fi

echo "📄 Config: $found_config"
echo "📦 Validator: npx $RENOVATE_PKG renovate-config-validator --strict"
echo ""

# --strict fails on errors, warnings AND configs that need migration.
# No filename argument → repo-level auto-discovery (see header comment).
if npx --yes --package "$RENOVATE_PKG" -- renovate-config-validator --strict; then
  echo ""
  print_separator
  log_success "PASSED - Renovate config is valid"
  exit 0
fi

echo ""
print_separator
log_error "FAILED - Renovate config has issues"
echo ""
echo "🛠️  Reproduce locally (from the repo root):"
echo "    npx --yes --package $RENOVATE_PKG -- renovate-config-validator --strict"
exit 1
