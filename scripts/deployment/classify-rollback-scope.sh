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
    --changed-files) CHANGED_FILES="${2:-}"; shift; [[ $# -gt 0 ]] && shift ;;
    --stack-dirs)    STACK_DIRS="${2:-}"; shift; [[ $# -gt 0 ]] && shift ;;
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
# Every element must be a non-empty string: a non-string element (number,
# null, nested array) would blow up the split()/index() pipeline below under
# `set -euo pipefail`, killing the script before any output is written — and
# an empty-string element would vacuously satisfy the "no paths outside a
# stack dir" check further down, silently landing on the unsafe per-stack
# side. Both must be caught here, before they reach the pipeline.
if ! jq -e 'type == "array" and all(.[]; type == "string" and length > 0)' <<<"$CHANGED_FILES" >/dev/null 2>&1; then
  emit_whole_tree "changed-files was not an array of non-empty strings"
fi
if ! jq -e 'type == "array" and all(.[]; type == "string" and length > 0)' <<<"$STACK_DIRS" >/dev/null 2>&1; then
  emit_whole_tree "stack-dirs was not an array of non-empty strings"
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
# A path with no "/" is a root-level file, so its first segment is the whole
# path. If that path happens to be spelled identically to a known stack
# directory name (e.g. a root-level file literally named "termix"), it WILL
# match and count as per-stack — this is the same exact first-segment
# membership rule applied uniformly, not a special case. In practice repo
# root files (compose.env, README, .github/**) don't collide with stack dir
# names, but this is not a semantic guarantee.
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
