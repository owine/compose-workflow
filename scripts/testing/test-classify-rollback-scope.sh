#!/usr/bin/env bash
# Unit tests for scripts/deployment/classify-rollback-scope.sh
# Pure input/output tests — no git repos, no docker.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLASSIFY="$REPO_ROOT/scripts/deployment/classify-rollback-scope.sh"

TMPROOT=$(mktemp -d -t classify-tests.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0
FAIL=0
FAILURES=()

# expect_scope <name> <expected> <changed_files_json> <stack_dirs_json>
expect_scope() {
  local name="$1" expected="$2" changed="$3" dirs="$4"
  local out actual
  out=$(mktemp -p "$TMPROOT")
  GITHUB_OUTPUT="$out" "$CLASSIFY" \
    --changed-files "$changed" \
    --stack-dirs "$dirs" \
    >/dev/null 2>&1 || true
  actual=$(grep '^rollback_scope=' "$out" 2>/dev/null | cut -d= -f2- || echo "<none>")
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1))
    echo "  ✅ $name"
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("$name: expected '$expected', got '$actual'")
    echo "  ❌ $name: expected '$expected', got '$actual'"
  fi
}

STACKS='["termix","monitoring","swag"]'

echo "== classify-rollback-scope =="

# Stack-scoped: every changed path lives under a known stack dir.
expect_scope "single stack file" \
  "per-stack" '["termix/compose.yaml"]' "$STACKS"
expect_scope "two stacks" \
  "per-stack" '["termix/compose.yaml","monitoring/compose.yaml"]' "$STACKS"
expect_scope "nested file under stack" \
  "per-stack" '["swag/config/nginx.conf"]' "$STACKS"

# Root-scoped: anything outside a known stack dir forces whole-tree.
expect_scope "compose.env at root" \
  "whole-tree" '["compose.env"]' "$STACKS"
expect_scope "mixed stack and root" \
  "whole-tree" '["termix/compose.yaml","compose.env"]' "$STACKS"
expect_scope "workflow file" \
  "whole-tree" '[".github/workflows/deploy.yml"]' "$STACKS"
expect_scope "unknown top-level dir" \
  "whole-tree" '["newstack/compose.yaml"]' "$STACKS"

# Degenerate inputs default to the safe path.
expect_scope "empty changed list" \
  "whole-tree" '[]' "$STACKS"
expect_scope "empty string changed list" \
  "whole-tree" '' "$STACKS"
expect_scope "empty stack dirs" \
  "whole-tree" '["termix/compose.yaml"]' '[]'

# A stack dir name that is a prefix of another must not match loosely.
expect_scope "prefix collision is not a match" \
  "whole-tree" '["termix-old/compose.yaml"]' "$STACKS"

echo
echo "Passed: $PASS  Failed: $FAIL"
if [[ $FAIL -gt 0 ]]; then
  printf '  - %s\n' "${FAILURES[@]}"
  exit 1
fi
