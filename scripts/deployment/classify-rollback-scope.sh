#!/usr/bin/env bash
# Script Name: classify-rollback-scope.sh
# Purpose: Decide whether a failed deploy can be rolled back per-stack or
#          requires the whole-tree reset.
# Usage: ./classify-rollback-scope.sh \
#          --changed-files '["termix/compose.yaml"]' \
#          --stack-dirs '["termix","monitoring"]'
#
# Emits: rollback_scope=per-stack|whole-tree  (to $GITHUB_OUTPUT)
#
# A deploy is per-stack rollbackable only when EVERY changed path's first
# segment names a known stack directory. Anything else — compose.env,
# .github/**, a README, an unrecognised top-level dir — is repo-wide and
# cannot be undone by reverting one stack directory, so it falls back to the
# whole-tree reset.
#
# compose.env is the motivating case: it lives at the repo root and is passed
# to every stack via `op run --env-file`. A bad edit there (renamed var, dead
# 1Password reference) breaks stacks whose own directories never changed.
#
# Uncertainty always resolves to whole-tree. Never the reverse.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

CHANGED_FILES="[]"
STACK_DIRS="[]"

while [[ $# -gt 0 ]]; do
  case $1 in
    --changed-files) CHANGED_FILES="${2:-[]}"; shift 2 ;;
    --stack-dirs)    STACK_DIRS="${2:-[]}"; shift 2 ;;
    *)
      log_error "Unknown argument: $1"
      exit 1
      ;;
  esac
done

# Normalise empty/absent inputs to empty JSON arrays.
[[ -z "$CHANGED_FILES" ]] && CHANGED_FILES="[]"
[[ -z "$STACK_DIRS" ]] && STACK_DIRS="[]"

emit_whole_tree() {
  log_info "Rollback scope: whole-tree ($1)"
  set_github_output "rollback_scope" "whole-tree"
  exit 0
}

# Malformed JSON from an upstream step must not crash the deploy; fall back.
if ! jq -e 'type == "array"' <<<"$CHANGED_FILES" >/dev/null 2>&1; then
  emit_whole_tree "changed-files was not a JSON array"
fi
if ! jq -e 'type == "array"' <<<"$STACK_DIRS" >/dev/null 2>&1; then
  emit_whole_tree "stack-dirs was not a JSON array"
fi

changed_count=$(jq 'length' <<<"$CHANGED_FILES")
if [[ "$changed_count" -eq 0 ]]; then
  emit_whole_tree "no changed-file list available"
fi

dirs_count=$(jq 'length' <<<"$STACK_DIRS")
if [[ "$dirs_count" -eq 0 ]]; then
  emit_whole_tree "no known stack directories"
fi

# Split each path on the first "/" and require the segment to be an exact
# member of the stack-dir set. Exact membership (not prefix matching) is what
# keeps "termix-old/…" from being mistaken for the "termix" stack.
#
# A path with no "/" is a root-level file: its first segment is the whole
# path, which will not match any stack dir, so it correctly forces whole-tree.
outside=$(jq -r --argjson dirs "$STACK_DIRS" '
  [ .[] | select((split("/")[0]) as $seg | ($dirs | index($seg)) == null) ]
  | .[]' <<<"$CHANGED_FILES")

if [[ -n "$outside" ]]; then
  log_info "Paths outside known stack directories:"
  while IFS= read -r p; do
    [[ -n "$p" ]] && log_info "  - $p"
  done <<<"$outside"
  emit_whole_tree "changes touch repo-root or unknown paths"
fi

log_success "Rollback scope: per-stack (all changes confined to stack directories)"
set_github_output "rollback_scope" "per-stack"
