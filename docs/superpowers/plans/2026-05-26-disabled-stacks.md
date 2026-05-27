# Disabled Stacks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `.disabled` marker file mechanism that causes the deploy workflow to `docker compose down` a stack on disable transition, without deleting the compose file from the repo.

**Architecture:** Introduce an "effectively present at SHA" predicate (compose.yaml exists ∧ .disabled absent) inside `detect-stack-changes.sh`. With effectively-present-in-CURRENT guards on removed-stack detectors and effectively-present-in-TARGET guards on new-stack detectors, the disable transition naturally piggybacks on the existing removed-stack teardown path; re-enable piggybacks on the new-stack deploy path. Discovery in the deploy workflow filters out disabled stacks; lint discovery in caller repos is unchanged. A new `disabled_stacks` output drives Discord and PR-comment visibility.

**Tech Stack:** Bash, GitHub Actions (reusable workflow), `tj-actions/changed-files`, `docker compose`, `jq`, `git cat-file`. Validation: `shellcheck`, `actionlint`, `yamllint --strict`.

**Spec:** [`docs/superpowers/specs/2026-05-26-disabled-stacks-design.md`](../specs/2026-05-26-disabled-stacks-design.md)

---

## File Inventory

**Modify:**
- `scripts/deployment/detect-stack-changes.sh` — add `--added-files` CLI flag, add `is_effectively_present_at_sha` helper, update all six detector functions with effective-presence guards
- `.github/workflows/deploy.yml` — filter `.disabled` from `Discover stacks`, add `disabled_stacks` output, wire `added_files` to script invocation, render disabled-stacks line in Discord + PR comment
- `scripts/deployment/build-pr-comment.sh` — accept `DISABLED_LINE` env var, render alongside `REMOVED_LINE`

**Create:**
- `scripts/testing/test-detect-stack-changes.sh` — bash test harness for unit-testing the classification script via throwaway git repos
- `scripts/testing/fixtures/transition-cases.sh` — transition table scenarios sourced by the harness (kept separate so the harness file stays a runner, not a fixture catalog)

**Touched but unchanged (verify only):**
- Caller-repo lint workflows — confirm disabled stacks still flow through (they should, since caller-side discovery isn't filtered)

---

## Task 1: Build test harness + write failing transition fixtures (TDD: RED)

**Files:**
- Create: `scripts/testing/test-detect-stack-changes.sh`
- Create: `scripts/testing/fixtures/transition-cases.sh`

The harness constructs a throwaway git repo with two commits (CURRENT_SHA → TARGET_SHA) representing each transition row, runs `detect-stack-changes.sh` against it, and asserts the JSON outputs match expected. We write all 8 transition fixtures up front, run against the current (unmodified) script, and confirm: 3 rows pass (normal add/delete/update), 5 fail (the new disabled-related rows). This is the RED state.

- [ ] **Step 1: Create harness skeleton with assertion helpers**

Create `scripts/testing/test-detect-stack-changes.sh`:

```bash
#!/usr/bin/env bash
# Unit tests for scripts/deployment/detect-stack-changes.sh
# Builds throwaway git repos per scenario, runs the script, asserts JSON outputs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DETECT_SCRIPT="$REPO_ROOT/scripts/deployment/detect-stack-changes.sh"

# shellcheck source=fixtures/transition-cases.sh
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
    git commit -q -m "current"
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
  grep "^${key}=" "$file" | head -1 | cut -d= -f2-
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
```

- [ ] **Step 2: Create transition fixtures**

Create `scripts/testing/fixtures/transition-cases.sh`. Each function constructs one scenario and asserts expected output. The `--added-files` flag is referenced here but doesn't exist on the script yet — that's intentional; Task 2 adds it. For now, fixtures invoke the harness's `run_detect` which always passes `--added-files [] `. **Pre-Task 2 behavior:** the script will reject the unknown flag, so this entire file fails until Task 2 lands. To allow stepwise validation, we accept that the fixtures cannot run green until after Task 2; Task 1's "RED state" verification is "fixtures parse, harness assertion helpers work."

```bash
#!/usr/bin/env bash
# Transition table scenarios for detect-stack-changes.sh tests.
# Each function: builds scenario, runs script, asserts expected classification.

case_normal_add() {
  local wd; wd=$(mktemp -d)
  read -r current target <<<"$(build_scenario "$wd" _setup_empty _add_foo_enabled)"
  local out; out=$(run_detect "$wd" "$current" "$target" '["foo"]' '[]' '["foo/compose.yaml"]')
  assert_classifications "normal_add" '[]' '[]' '["foo"]' "$out"
}
_setup_empty() { :; }
_add_foo_enabled() { mkdir -p foo; echo 'services: {a: {image: nginx}}' > foo/compose.yaml; }

case_normal_delete() {
  local wd; wd=$(mktemp -d)
  read -r current target <<<"$(build_scenario "$wd" _add_foo_enabled _delete_foo)"
  local out; out=$(run_detect "$wd" "$current" "$target" '[]' '["foo/compose.yaml"]' '[]')
  assert_classifications "normal_delete" '["foo"]' '[]' '[]' "$out"
}
_delete_foo() { rm -rf foo; }

case_normal_update() {
  local wd; wd=$(mktemp -d)
  read -r current target <<<"$(build_scenario "$wd" _add_foo_enabled _modify_foo)"
  local out; out=$(run_detect "$wd" "$current" "$target" '["foo"]' '[]' '[]')
  assert_classifications "normal_update" '[]' '["foo"]' '[]' "$out"
}
_modify_foo() { echo 'services: {a: {image: nginx:1.27}}' > foo/compose.yaml; }

case_disable() {
  local wd; wd=$(mktemp -d)
  read -r current target <<<"$(build_scenario "$wd" _add_foo_enabled _disable_foo)"
  # Input stacks excludes foo because the discover step (workflow-side) filters
  # .disabled-bearing dirs. Simulate that here.
  local out; out=$(run_detect "$wd" "$current" "$target" '[]' '[]' '["foo/.disabled"]')
  assert_classifications "disable" '["foo"]' '[]' '[]' "$out"
}
_disable_foo() { touch foo/.disabled; }

case_re_enable() {
  local wd; wd=$(mktemp -d)
  read -r current target <<<"$(build_scenario "$wd" _add_foo_disabled _enable_foo)"
  local out; out=$(run_detect "$wd" "$current" "$target" '["foo"]' '["foo/.disabled"]' '[]')
  assert_classifications "re_enable" '[]' '[]' '["foo"]' "$out"
}
_add_foo_disabled() {
  mkdir -p foo; echo 'services: {a: {image: nginx}}' > foo/compose.yaml; touch foo/.disabled;
}
_enable_foo() { rm foo/.disabled; }

case_stay_disabled() {
  local wd; wd=$(mktemp -d)
  read -r current target <<<"$(build_scenario "$wd" _add_foo_disabled _noop)"
  local out; out=$(run_detect "$wd" "$current" "$target" '[]' '[]' '[]')
  assert_classifications "stay_disabled" '[]' '[]' '[]' "$out"
}
_noop() { :; }

case_born_disabled() {
  local wd; wd=$(mktemp -d)
  read -r current target <<<"$(build_scenario "$wd" _setup_empty _add_foo_disabled)"
  # Both files appear as added; this is the regression case for the guard.
  local out; out=$(run_detect "$wd" "$current" "$target" '[]' '[]' '["foo/compose.yaml","foo/.disabled"]')
  assert_classifications "born_disabled" '[]' '[]' '[]' "$out"
}

case_delete_while_disabled() {
  local wd; wd=$(mktemp -d)
  read -r current target <<<"$(build_scenario "$wd" _add_foo_disabled _delete_foo)"
  local out; out=$(run_detect "$wd" "$current" "$target" '[]' '["foo/compose.yaml","foo/.disabled"]' '[]')
  assert_classifications "delete_while_disabled" '[]' '[]' '[]' "$out"
}

run_all_cases() {
  case_normal_add
  case_normal_delete
  case_normal_update
  case_disable
  case_re_enable
  case_stay_disabled
  case_born_disabled
  case_delete_while_disabled
}
```

- [ ] **Step 3: Make harness + fixtures executable**

```bash
chmod +x scripts/testing/test-detect-stack-changes.sh
```

- [ ] **Step 4: Run the harness — expect catastrophic failure (RED)**

```bash
./scripts/testing/test-detect-stack-changes.sh || true
```

Expected: every test fails because the script will reject `--added-files` as an unknown argument. This is RED. The fixtures and harness assertion plumbing are validated by reading the output — confirm each case prints `❌ <name>` and that the failure messages include the script's "Unknown argument: --added-files" output (visible in script stderr; the harness suppresses it, but you can re-run one case manually to check).

Manually verify:

```bash
"$(pwd)/scripts/deployment/detect-stack-changes.sh" --added-files '[]' 2>&1 | head -3
```

Expected: contains `Unknown argument: --added-files`.

- [ ] **Step 5: Commit**

```bash
git add scripts/testing/test-detect-stack-changes.sh scripts/testing/fixtures/transition-cases.sh
git commit -m "test: harness + transition fixtures for detect-stack-changes"
```

---

## Task 2: Add `--added-files` CLI plumbing

**Files:**
- Modify: `scripts/deployment/detect-stack-changes.sh` (arg parsing block at lines 24–42)

No behavior change — just accept the flag so fixtures can pass it.

- [ ] **Step 1: Add ADDED_FILES variable + argument parsing**

In `detect-stack-changes.sh`, alongside `REMOVED_FILES`:

```bash
REMOVED_FILES="[]"
ADDED_FILES="[]"
```

In the `while [[ $# -gt 0 ]]; do case $1 in ... esac done` block:

```bash
    --added-files)      ADDED_FILES="$2"; shift 2 ;;
```

- [ ] **Step 2: Re-run harness — still RED but for the *right* reasons now**

```bash
./scripts/testing/test-detect-stack-changes.sh || true
```

Expected: `normal_add`, `normal_delete`, `normal_update` pass (3 ✅); the five disabled-related cases fail (5 ❌). This proves: (a) the flag is now accepted, (b) existing behavior is preserved for non-disabled rows, (c) the disabled rows are correctly failing because the script doesn't yet know about `.disabled`.

- [ ] **Step 3: Run shellcheck**

```bash
shellcheck scripts/deployment/detect-stack-changes.sh
```

Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add scripts/deployment/detect-stack-changes.sh
git commit -m "feat(detect): accept --added-files flag (no behavior change yet)"
```

---

## Task 3: Add `is_effectively_present_at_sha` helper + apply to removed-stack detectors

**Files:**
- Modify: `scripts/deployment/detect-stack-changes.sh`

Implements the effectively-present-in-CURRENT guard on all three removed detectors. After this task, the `disable` and `delete_while_disabled` fixtures should pass; `re_enable`, `stay_disabled`, and `born_disabled` will still fail (those need the symmetric new-detector guards in Task 4).

- [ ] **Step 1: Add the helper**

Inside the `run_local` helper block (around line 55), or as a top-level function above the detector functions, add:

```bash
# is_effectively_present_at_sha <sha> <stack>
# Returns 0 iff <stack>/compose.yaml exists at <sha> AND <stack>/.disabled does not.
# Must be invoked inside the LIVE_REPO_PATH git repo (i.e. inside a run_local block).
is_effectively_present_at_sha() {
  local sha="$1" stack="$2"
  git cat-file -e "$sha:$stack/compose.yaml" 2>/dev/null || return 1
  if git cat-file -e "$sha:$stack/.disabled" 2>/dev/null; then
    return 1
  fi
  return 0
}
```

Because each detector runs its body in a `bash -s` heredoc subshell via `run_local`, the helper must be defined *inside* each detector's heredoc OR exported through `LIVE_REPO_PATH` propagation. The simplest approach: inline the helper at the top of each detector's heredoc body. To keep things DRY, define the function body once as a bash string variable and prepend it to each heredoc:

```bash
# Helper text injected at the top of each detector heredoc.
HELPER_FUNCS='
is_effectively_present_at_sha() {
  local sha="$1" stack="$2"
  git cat-file -e "$sha:$stack/compose.yaml" 2>/dev/null || return 1
  if git cat-file -e "$sha:$stack/.disabled" 2>/dev/null; then
    return 1
  fi
  return 0
}
is_effectively_present_on_disk() {
  local root="$1" stack="$2"
  [[ -f "$root/$stack/compose.yaml" ]] || return 1
  [[ ! -f "$root/$stack/.disabled" ]]
}
'
```

Then prepend `$HELPER_FUNCS` to each detector's heredoc body. This requires changing each detector's heredoc from a single-quoted `<< 'DETECT_EOF'` (literal, no interpolation) to a setup that injects the helpers. Cleanest pattern: keep the heredoc literal, but prepend the helpers via concatenation:

```bash
detect_removed_stacks_gitdiff() {
  local current_sha="$1" target_ref="$2"
  log_info "Running git diff detection for removed stacks..."
  local detect_script
  detect_script="$HELPER_FUNCS"$'\n'"$(cat << 'DETECT_EOF'
  ...existing body...
DETECT_EOF
)"
  echo "$detect_script" | run_local "$current_sha" "$target_ref"
}
```

Apply this concatenation pattern to all six detectors.

- [ ] **Step 2: Update `detect_removed_stacks_gitdiff` body**

**Preserve the existing preamble inside the heredoc** (the `git fetch`, `TARGET_SHA=$(git rev-parse ...)`, and `git cat-file -e` SHA-existence guards). Replace only the trailing `git diff --diff-filter=D` pipeline at the end of the heredoc body. The new pipeline:
1. Collects candidates from compose.yaml deletions (diff-filter `D`) AND `.disabled` additions (diff-filter `A`)
2. For each candidate, emits only if `is_effectively_present_at_sha "$CURRENT_SHA" "$candidate"`

```bash
# Inside the heredoc body, replacing the existing single git-diff invocation:
{
  git diff --diff-filter=D --name-only "$CURRENT_SHA" "$TARGET_SHA" 2>/dev/null \
    | grep -E '^[^/]+/compose\.yaml$' | sed 's|/compose\.yaml||' || true
  git diff --diff-filter=A --name-only "$CURRENT_SHA" "$TARGET_SHA" 2>/dev/null \
    | grep -E '^[^/]+/\.disabled$' | sed 's|/\.disabled||' || true
} | sort -u | while read -r candidate; do
  [[ -z "$candidate" ]] && continue
  if is_effectively_present_at_sha "$CURRENT_SHA" "$candidate"; then
    echo "$candidate"
  fi
done
```

- [ ] **Step 3: Update `detect_removed_stacks_tree` body**

**Preserve the existing preamble** (`git fetch`, `TARGET_SHA=$(git rev-parse ...)`, and the `git cat-file -e $TARGET_SHA` existence guard). The current body computes `MISSING_IN_COMMIT` via filesystem comparison after that preamble — replace only the comparison logic with:

```bash
# All directories that ever appeared at root in either tree or live filesystem.
ALL_DIRS=$( {
  git ls-tree --name-only "$TARGET_SHA" 2>/dev/null
  find "$LIVE_REPO_PATH" -maxdepth 1 -mindepth 1 -type d ! -name '.*' -exec basename {} \;
} | sort -u )

for dir in $ALL_DIRS; do
  # Removed = effectively-present on live disk AND NOT effectively-present at target SHA.
  if is_effectively_present_on_disk "$LIVE_REPO_PATH" "$dir" \
     && ! is_effectively_present_at_sha "$TARGET_SHA" "$dir"; then
    echo "$dir"
  fi
done
```

- [ ] **Step 4: Update `detect_removed_stacks_discovery` body**

Currently keys only on `deleted_files`. Extend to merge `added_files` for `.disabled` markers, then apply the guard. Update the function signature to take both inputs:

```bash
detect_removed_stacks_discovery() {
  local removed_files_json="$1" added_files_json="$2" current_sha="$3"
  log_info "Running discovery analysis detection for removed stacks..."
  local removed_b64 added_b64
  removed_b64=$(echo -n "$removed_files_json" | base64 -w 0 2>/dev/null || echo -n "$removed_files_json" | base64)
  added_b64=$(echo -n "$added_files_json" | base64 -w 0 2>/dev/null || echo -n "$added_files_json" | base64)

  local detect_script
  detect_script="$HELPER_FUNCS"$'\n'"$(cat << 'DETECT_DISCOVERY_EOF'
  set -e
  CURRENT_SHA="$3"
  REMOVED_JSON=$(echo "$1" | base64 -d)
  ADDED_JSON=$(echo "$2" | base64 -d)
  cd "$LIVE_REPO_PATH"
  {
    echo "$REMOVED_JSON" | jq -r '.[]?' | grep -E '^[^/]+/compose\.yaml$' | sed 's|/compose\.yaml||' || true
    echo "$ADDED_JSON"   | jq -r '.[]?' | grep -E '^[^/]+/\.disabled$'    | sed 's|/\.disabled||'    || true
  } | sort -u | while read -r candidate; do
    [[ -z "$candidate" ]] && continue
    if is_effectively_present_at_sha "$CURRENT_SHA" "$candidate"; then
      echo "$candidate"
    fi
  done
DETECT_DISCOVERY_EOF
)"
  echo "$detect_script" | run_local "$removed_b64" "$added_b64" "$current_sha"
}
```

Then update the caller (in the MAIN section) to pass the new arguments:

```bash
REMOVED_DISCOVERY=$(detect_removed_stacks_discovery "$REMOVED_FILES" "$ADDED_FILES" "$CURRENT_SHA") || REMOVED_DISCOVERY_EXIT=$?
```

Also remove the `if [ "$REMOVED_FILES" = "[]" ] ...` early-skip block — we now have two sources to check, so the function itself handles emptiness (the jq `.[]?` operator tolerates `[]`).

- [ ] **Step 5: Run the harness — expect partial GREEN**

```bash
./scripts/testing/test-detect-stack-changes.sh || true
```

Expected: `normal_add`, `normal_delete`, `normal_update`, `disable`, `delete_while_disabled` pass (5 ✅); `re_enable`, `stay_disabled`, `born_disabled` still fail (3 ❌). The remaining failures are all on the new-stack detector side.

- [ ] **Step 6: Run shellcheck**

```bash
shellcheck scripts/deployment/detect-stack-changes.sh
```

Expected: no errors.

- [ ] **Step 7: Commit**

```bash
git add scripts/deployment/detect-stack-changes.sh
git commit -m "feat(detect): effectively-present-in-CURRENT guard on removed detectors"
```

---

## Task 4: Apply effectively-present-in-TARGET guards to new-stack detectors

**Files:**
- Modify: `scripts/deployment/detect-stack-changes.sh`

Symmetric to Task 3. After this task all 8 fixtures should pass.

- [ ] **Step 1: Update `detect_new_stacks_gitdiff` body**

**Preserve the existing preamble** (`git fetch`, `TARGET_SHA=$(git rev-parse ...)`, SHA-existence guards for both CURRENT and TARGET). Replace only the trailing `git diff --diff-filter=A` invocation with combined candidate collection + guard:

```bash
{
  git diff --diff-filter=A --name-only "$CURRENT_SHA" "$TARGET_SHA" 2>/dev/null \
    | grep -E '^[^/]+/compose\.yaml$' | sed 's|/compose\.yaml||' || true
  git diff --diff-filter=D --name-only "$CURRENT_SHA" "$TARGET_SHA" 2>/dev/null \
    | grep -E '^[^/]+/\.disabled$' | sed 's|/\.disabled||' || true
} | sort -u | while read -r candidate; do
  [[ -z "$candidate" ]] && continue
  if is_effectively_present_at_sha "$TARGET_SHA" "$candidate"; then
    echo "$candidate"
  fi
done
```

- [ ] **Step 2: Update `detect_new_stacks_tree` body**

**Preserve the existing preamble** (`git fetch`, `TARGET_SHA`, SHA-existence guard). Replace only the `COMMIT_STACKS` / `SERVER_STACKS` / `comm -23` logic with:

```bash
ALL_DIRS=$( {
  git ls-tree --name-only "$TARGET_SHA" 2>/dev/null
  find "$LIVE_REPO_PATH" -maxdepth 1 -mindepth 1 -type d ! -name '.*' -exec basename {} \;
} | sort -u )

for dir in $ALL_DIRS; do
  # New = effectively-present at target SHA AND NOT effectively-present on live disk.
  if is_effectively_present_at_sha "$TARGET_SHA" "$dir" \
     && ! is_effectively_present_on_disk "$LIVE_REPO_PATH" "$dir"; then
    echo "$dir"
  fi
done
```

- [ ] **Step 3: `detect_new_stacks_input` — verify no change needed**

Read the function and confirm: it takes `INPUT_STACKS` (which, after Task 5's discover-stacks filter, will already exclude disabled stacks) and emits those not present on disk. The on-disk check (`-f compose.yaml`) is fine here because: if `INPUT_STACKS` only contains effectively-present-in-TARGET names, and the on-disk check is checking the *live* tree, then "not on live disk" = "new" remains correct. No edit needed.

Confirm by reading lines 281–304 of the script.

- [ ] **Step 4: Run the harness — expect full GREEN**

```bash
./scripts/testing/test-detect-stack-changes.sh
```

Expected: all 8 cases pass. `Tests: 8  Passed: 8  Failed: 0`. Exit code 0.

- [ ] **Step 5: Run shellcheck**

```bash
shellcheck scripts/deployment/detect-stack-changes.sh
```

Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add scripts/deployment/detect-stack-changes.sh
git commit -m "feat(detect): effectively-present-in-TARGET guard on new detectors"
```

---

## Task 5: Filter `.disabled` from `Discover stacks` + emit `disabled_stacks` output

**Files:**
- Modify: `.github/workflows/deploy.yml` (lines 123–143 `Discover stacks` step + prepare job outputs at lines 70–78)

- [ ] **Step 1: Update the `Discover stacks` step**

Replace the step body to filter `.disabled` and emit a second JSON array:

```yaml
      - name: Discover stacks
        id: discover-stacks
        env:
          DETECTION_TREE: ${{ github.workspace }}
        run: |
          set -euo pipefail
          cd "$DETECTION_TREE"
          active=()
          disabled=()
          for dir in */; do
            dir_name=$(basename "$dir")
            if [[ -f "$dir/compose.yml" || -f "$dir/compose.yaml" ]]; then
              if [[ -f "$dir/.disabled" ]]; then
                disabled+=("\"$dir_name\"")
              else
                active+=("\"$dir_name\"")
              fi
            fi
          done
          if [ ${#active[@]} -eq 0 ] && [ ${#disabled[@]} -eq 0 ]; then
            echo "::error::No Docker Compose stacks found in repository"
            exit 1
          fi
          active_json="[$(IFS=,; echo "${active[*]}")]"
          disabled_json="[$(IFS=,; echo "${disabled[*]}")]"
          echo "stacks=$active_json" >> "$GITHUB_OUTPUT"
          echo "disabled_stacks=$disabled_json" >> "$GITHUB_OUTPUT"
          echo "has_disabled_stacks=$([ ${#disabled[@]} -gt 0 ] && echo true || echo false)" >> "$GITHUB_OUTPUT"
          echo "✅ Active stacks: $active_json"
          echo "🛑 Disabled stacks: $disabled_json"
```

- [ ] **Step 2: Add new prepare job outputs**

In the `prepare` job's `outputs:` block (lines 70–78), add:

```yaml
      disabled_stacks: ${{ steps.discover-stacks.outputs.disabled_stacks }}
      has_disabled_stacks: ${{ steps.discover-stacks.outputs.has_disabled_stacks }}
```

- [ ] **Step 3: Validate with actionlint + yamllint**

```bash
actionlint .github/workflows/deploy.yml
yamllint --strict .github/workflows/deploy.yml
```

Expected: both pass with no errors.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/deploy.yml
git commit -m "feat(deploy): filter .disabled from discovery, emit disabled_stacks"
```

---

## Task 6: Wire `added_files` into `detect-stack-changes.sh` invocation

**Files:**
- Modify: `.github/workflows/deploy.yml` (Detect stack changes step around lines 145–163)

- [ ] **Step 1: Pass `added_files` env var**

In the `Detect stack changes` step's `env:` block, after `REMOVED_FILES`:

```yaml
          ADDED_FILES: ${{ steps.changed-files.outputs.added_files != '' && steps.changed-files.outputs.added_files || '[]' }}
```

And in the script invocation, add the new flag:

```yaml
          ./.compose-workflow/scripts/deployment/detect-stack-changes.sh \
            --current-sha "$PREVIOUS_SHA" \
            --target-ref "$TARGET_REF" \
            --live-repo-path "$DETECTION_TREE" \
            --input-stacks "$INPUT_STACKS" \
            --removed-files "$REMOVED_FILES" \
            --added-files "$ADDED_FILES"
```

- [ ] **Step 2: Validate**

```bash
actionlint .github/workflows/deploy.yml
yamllint --strict .github/workflows/deploy.yml
```

Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/deploy.yml
git commit -m "feat(deploy): wire added_files into stack change detection"
```

---

## Task 7: Render `DISABLED_LINE` in `build-pr-comment.sh`

**Files:**
- Modify: `scripts/deployment/build-pr-comment.sh`

- [ ] **Step 1: Add the env var default + render block**

After line 18 (`: "${REMOVED_LINE:=}"`), add:

```bash
: "${DISABLED_LINE:=}"
```

After the existing removed-stacks rendering block (lines 53–56), add:

```bash
# Disabled-stacks line (only when present).
if [[ -n "$DISABLED_LINE" ]]; then
  printf '%s\n\n' "$DISABLED_LINE"
fi
```

- [ ] **Step 2: Verify with shellcheck**

```bash
shellcheck scripts/deployment/build-pr-comment.sh
```

Expected: no errors.

- [ ] **Step 3: Smoke test locally**

```bash
REPO_NAME=test TARGET_REF=abcdef0123456789 REPOSITORY=foo/bar \
  RUN_ID=1 RUN_NUMBER=1 OVERALL=success TITLE_SUFFIX=ok \
  REMOVED_LINE='🗑️ **Removed stacks:** foo' \
  DISABLED_LINE='🛑 **Disabled stacks:** bar' \
  ./scripts/deployment/build-pr-comment.sh
```

Expected output: includes both the 🗑️ removed line and the 🛑 disabled line as separate paragraphs.

- [ ] **Step 4: Commit**

```bash
git add scripts/deployment/build-pr-comment.sh
git commit -m "feat(notify): render disabled-stacks line in PR comment"
```

---

## Task 8: Build `disabled_line` in notify status step + wire through to Discord and PR comment

**Files:**
- Modify: `.github/workflows/deploy.yml` (status step around lines 725–846, Discord step around lines 857–875, PR comment env around lines 925–940)

- [ ] **Step 1: Pass `disabled_stacks` through the status step env**

In the `Compute notification status` step (around line 725), add to the `env:` block:

```yaml
          HAS_DISABLED: ${{ needs.prepare.outputs.has_disabled_stacks }}
          DISABLED_STACKS: ${{ needs.prepare.outputs.disabled_stacks }}
```

- [ ] **Step 2: Build `disabled_line` mirroring the existing `removed_line` block**

After the existing `removed_line` block (around line 846), add:

```bash
          # Disabled stacks line
          disabled_line=""
          if [[ "$HAS_DISABLED" == "true" ]]; then
            disabled_names=$(echo "$DISABLED_STACKS" | jq -r '. | join(", ")' 2>/dev/null || echo "")
            if [[ -n "$disabled_names" ]]; then
              disabled_line="🛑 **Disabled stacks:** $disabled_names"
            fi
          fi
          {
            echo "disabled_line<<EOF"
            echo "$disabled_line"
            echo "EOF"
          } >> "$GITHUB_OUTPUT"
```

- [ ] **Step 3: Add `disabled_line` to Discord embed description**

In the `Send Discord notification` step (around line 858), in the `description:` multiline block, add a line after the existing `removed_line` interpolation (around line 867):

```yaml
          description: |
            ${{ steps.status.outputs.description }}

            ${{ steps.status.outputs.removed_line }}
            ${{ steps.status.outputs.disabled_line }}

            ${{ steps.status.outputs.deployment_needed == 'true' && format('**🔄 Pipeline Status**
            {0}', steps.status.outputs.pipeline) || '' }}
            ...
```

Note: the existing `removed_line` already handles the "empty when no removed stacks" case because the GitHub Actions `${{ ... }}` substitution preserves the empty string and the surrounding blank line is harmless. Same applies to `disabled_line`.

- [ ] **Step 4: Pass `DISABLED_LINE` to `build-pr-comment.sh` env**

In the step that invokes `build-pr-comment.sh` (around line 933, alongside `REMOVED_LINE`):

```yaml
          DISABLED_LINE: ${{ steps.status.outputs.disabled_line }}
```

- [ ] **Step 5: Validate**

```bash
actionlint .github/workflows/deploy.yml
yamllint --strict .github/workflows/deploy.yml
```

Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/deploy.yml
git commit -m "feat(notify): include disabled stacks in Discord and PR comment"
```

---

## Task 9: Final lint + manual smoke verification plan

**Files:** all touched files

- [ ] **Step 1: Full repo lint pass**

```bash
shellcheck scripts/deployment/*.sh scripts/testing/*.sh scripts/testing/fixtures/*.sh
actionlint .github/workflows/*.yml
yamllint --strict .github/workflows/*.yml
./scripts/testing/test-detect-stack-changes.sh
```

Expected: all pass. Test harness reports `Tests: 8  Passed: 8  Failed: 0`.

- [ ] **Step 2: Write smoke-test runbook entry**

This step does NOT execute the smoke test (that happens after merge against a real environment). Document the runbook in the commit message body so the human operator who deploys this can follow it:

```
After this change is merged and a caller-repo workflow picks up the new reusable-workflow SHA:

1. Pick a low-stakes stack in docker-piwine-office (e.g. dozzle).
2. touch dozzle/.disabled, commit, push to main.
3. Wait for deploy workflow. Verify:
   - Discord notification description includes "🛑 Disabled stacks: dozzle"
   - PR comment (if from a PR) includes the same line
   - On the host: docker compose ps shows no dozzle containers running
   - /opt/compose/dozzle/compose.yaml still present on disk
4. git rm dozzle/.disabled, commit, push.
5. Verify: stack classified as "new" in deploy logs, containers running again, health check passes.
```

- [ ] **Step 3: Commit (final)**

If any housekeeping diffs remain (e.g. shellcheck-discovered fixups), commit them:

```bash
git add -A
git commit -m "chore: final lint pass for disabled-stacks feature" --allow-empty
```

If no diffs, skip the commit.

---

## Out of scope

The spec's "Out of scope" section applies here verbatim: no reason strings, no central registry/dashboard, no per-env disable, no CLI tooling, no `.disabled` lint-trigger special-casing. If any of these are tempting during implementation, stop and consult the spec.

## Risk + rollback

If the deployed change misbehaves in production (e.g. mass false-positive teardowns), the rollback is the standard self-hosted runner rollback path documented in `compose-workflow/CLAUDE.md`: the caller repo's `deploy.yml` will rebase to the prior SHA pin of `owine/compose-workflow` (Renovate auto-bumps; manual revert is a single line). The bulk of risk is in Task 3/4 (detector logic) — those tasks gate the change via the test harness specifically to catch regressions before merge.
