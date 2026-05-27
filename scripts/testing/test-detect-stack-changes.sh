#!/usr/bin/env bash
# Unit tests for scripts/deployment/detect-stack-changes.sh
# Builds throwaway git repos per scenario, runs the script, asserts JSON outputs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DETECT_SCRIPT="$REPO_ROOT/scripts/deployment/detect-stack-changes.sh"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=scripts/testing/fixtures/transition-cases.sh
source "$SCRIPT_DIR/fixtures/transition-cases.sh"

PASS=0
FAIL=0
FAILURES=()

# build_scenario <workdir> <current_setup_fn> <target_setup_fn>
# Creates a git repo at <workdir> with two commits. Each setup fn is called
# with the workdir as CWD and performs file mutations representing one SHA.
# Returns CURRENT_SHA and TARGET_SHA via globals.
build_scenario() {
  local workdir="$1" current_fn="$2" target_fn="$3"
  rm -rf "$workdir"
  mkdir -p "$workdir"
  (
    cd "$workdir"
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name "Test"
    "$current_fn"
    git add -A
    git commit -q --allow-empty -m "current"
    CURRENT_SHA=$(git rev-parse HEAD)
    "$target_fn"
    git add -A
    # Allow empty in case target_fn only deletes
    git commit -q --allow-empty -m "target"
    TARGET_SHA=$(git rev-parse HEAD)
    echo "$CURRENT_SHA $TARGET_SHA"
  )
}

# run_detect <workdir> <current_sha> <target_sha> <input_stacks_json> \
#            [<removed_files_json>] [<added_files_json>]
# Runs the detect script with GITHUB_OUTPUT redirected to a temp file,
# returns the file path (caller parses it).
run_detect() {
  local workdir="$1" current="$2" target="$3" input="$4"
  local removed="${5:-[]}" added="${6:-[]}"
  local out
  out=$(mktemp)
  GITHUB_OUTPUT="$out" "$DETECT_SCRIPT" \
    --current-sha "$current" \
    --target-ref "$target" \
    --live-repo-path "$workdir" \
    --input-stacks "$input" \
    --removed-files "$removed" \
    --added-files "$added" \
    >/dev/null 2>&1 || {
      echo "::detect-script-failed::" >> "$out"
    }
  echo "$out"
}

# Read a GITHUB_OUTPUT-format key
read_output() {
  local file="$1" key="$2"
  # Tolerate missing key: grep returns 1 with pipefail otherwise kills caller.
  grep "^${key}=" "$file" 2>/dev/null | head -1 | cut -d= -f2- || true
}

# assert <case_name> <expected_removed_json> <expected_existing_json> \
#        <expected_new_json> <output_file>
assert_classifications() {
  local name="$1" exp_removed="$2" exp_existing="$3" exp_new="$4" out="$5"
  local got_removed got_existing got_new
  got_removed=$(read_output "$out" removed_stacks)
  got_existing=$(read_output "$out" existing_stacks)
  got_new=$(read_output "$out" new_stacks)

  if [[ "$got_removed" == "$exp_removed" \
     && "$got_existing" == "$exp_existing" \
     && "$got_new" == "$exp_new" ]]; then
    echo "✅ $name"
    PASS=$((PASS+1))
  else
    echo "❌ $name"
    echo "   removed:  got=$got_removed  want=$exp_removed"
    echo "   existing: got=$got_existing want=$exp_existing"
    echo "   new:      got=$got_new      want=$exp_new"
    FAIL=$((FAIL+1))
    FAILURES+=("$name")
  fi
}

# Run all transition test cases (defined in fixtures file).
run_all_cases

echo ""
echo "========================================"
echo "Tests: $((PASS+FAIL))  Passed: $PASS  Failed: $FAIL"
echo "========================================"
if [[ $FAIL -gt 0 ]]; then
  printf 'Failures:\n'
  printf '  - %s\n' "${FAILURES[@]}"
  exit 1
fi
