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

# expect_case <name> <expected_scope|"<none>"> <expected_rc> -- <argv...>
# Runs the classifier with an arbitrary argv and asserts BOTH the emitted
# rollback_scope output AND the exit code. Asserting rc matters: a case that
# only checks output would miss a regression that writes the right value and
# then exits nonzero.
expect_case() {
  local name="$1" expected="$2" expected_rc="$3"
  shift 4  # drop name, expected, expected_rc, and the "--" separator
  local out actual rc=0
  out=$(mktemp -p "$TMPROOT")
  GITHUB_OUTPUT="$out" "$CLASSIFY" "$@" >/dev/null 2>&1 || rc=$?
  actual=$(grep '^rollback_scope=' "$out" 2>/dev/null | cut -d= -f2- || echo "<none>")
  if [[ "$actual" == "$expected" && "$rc" == "$expected_rc" ]]; then
    PASS=$((PASS + 1))
    echo "  ✅ $name"
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("$name: expected scope='$expected' rc=$expected_rc, got scope='$actual' rc=$rc")
    echo "  ❌ $name: expected scope='$expected' rc=$expected_rc, got scope='$actual' rc=$rc"
  fi
}

# expect_scope <name> <expected> <changed_files_json> <stack_dirs_json>
# Thin two-flag wrapper over expect_case, always asserting rc=0. All existing
# call sites below stay textually unchanged and now also assert exit code.
expect_scope() {
  local name="$1" expected="$2" changed="$3" dirs="$4"
  expect_case "$name" "$expected" 0 -- --changed-files "$changed" --stack-dirs "$dirs"
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

# Non-string / empty-string elements must not crash the script or silently
# fall through to the unsafe per-stack side.
expect_scope "non-string element" \
  "whole-tree" '[1]' "$STACKS"
expect_scope "null element" \
  "whole-tree" '[null]' "$STACKS"
expect_scope "empty-string element" \
  "whole-tree" '[""]' "$STACKS"
expect_scope "nested-array element" \
  "whole-tree" '[["a"]]' "$STACKS"
expect_scope "non-string stack dir" \
  "whole-tree" '["termix/compose.yaml"]' '[1]'

# Missing-value invocation shapes must not crash the script — they normalise
# to [] and fall through to whole-tree, rc=0.
expect_case "trailing flag with no value" \
  "whole-tree" 0 -- --changed-files
expect_case "missing value before next flag" \
  "whole-tree" 0 -- --changed-files --stack-dirs "$STACKS"

# Invocation errors (unknown flag) are deliberately NOT degraded to
# whole-tree: they mean the caller is wired up wrong, and should fail loudly
# (rc=1, no output) rather than silently deploy with a scope decision nobody
# intended. This is the most opinionated behavior in the script — cover it so
# a well-meaning "make everything fail-safe" edit can't remove it unnoticed.
expect_case "unknown flag fails loudly" \
  "<none>" 1 -- --bogus

echo
echo "Passed: $PASS  Failed: $FAIL"
if [[ $FAIL -gt 0 ]]; then
  printf '  - %s\n' "${FAILURES[@]}"
  exit 1
fi
