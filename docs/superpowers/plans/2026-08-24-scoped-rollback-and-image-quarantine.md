# Scoped Rollback and Image Quarantine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Confine a failed stack's rollback to that stack alone, and give the operator a one-command way to permanently block a known-bad image version from being re-proposed by Renovate.

**Architecture:** Change A adds a scope classifier to `deploy.yml`'s `prepare` job that decides between a new per-stack rollback path and the existing whole-tree reset, plus the plumbing (a `failed_stacks` output on `health-check`) needed to know which stacks to roll back. Change B adds a standalone user skill that reverts a bad image bump and writes a negated-regex `allowedVersions` block into the consuming repo's Renovate config, in one atomic commit.

**Tech Stack:** Bash 5, GitHub Actions reusable workflows, `jq`, `git`, Renovate config JSON, shellcheck/yamllint.

**Spec:** `docs/superpowers/specs/2026-08-24-scoped-rollback-and-image-quarantine-design.md`

---

## Context for the implementer

You are working in `~/Git/Compose/compose-workflow`, a repository of **reusable GitHub Actions workflows** consumed by two private repos (`docker-piwine`, `docker-piwine-office`). Those repos each hold a set of Docker Compose "stacks" — one directory per stack, each containing a `compose.yaml`.

Facts you need that are not obvious from the code:

- **Deploys run on a self-hosted runner** that owns a persistent clone of the caller repo at `inputs.live-repo-path`. The workflow mutates that clone directly. There is no ephemeral checkout for the deploy itself.
- **Every deploy starts with `git -C "$LIVE_REPO_PATH" reset --hard "$TARGET_REF"`** (`.github/workflows/deploy.yml:283`). This is why leaving the live tree dirty after a partial rollback is safe — the next run cleans it. Do not add a cleanup step for this.
- **Secrets come from 1Password at runtime.** Every `docker compose up` is wrapped in `op run --no-masking --env-file="$LIVE_REPO_PATH/compose.env" -- …`. **A `compose up` without that wrapper comes up with empty environment variables and appears to succeed.** This is the single easiest way to break this change. Non-`up` compose calls (`down`, `ps`) are deliberately *not* wrapped.
- **Unit tests are local-only.** `scripts/testing/*.sh` are not invoked by any workflow. Run them by hand. Do not wire them into CI as part of this plan — that is out of scope.
- **`jq` is available on the runner** and used throughout the workflow.

### Deviation from the spec, and why

The spec (§A1) places the scope classifier "after `Get changed files` (`deploy.yml:120`)". **Implement it after `Detect stack changes` instead.**

Reason: the classifier decides whether a changed path's first segment names a stack directory. It therefore needs the full set of known stack directories — and a *removed* stack's directory no longer exists in the target tree, so it is absent from `discover-stacks`'s output. Classifying against active stacks alone would misfile every stack deletion as a root-file change and force whole-tree rollback on routine removals. The `removed_stacks` list only exists after `Detect stack changes` runs, so the classifier must follow it.

This is a placement change only. The classification rules in the spec's table are unchanged.

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `scripts/deployment/classify-rollback-scope.sh` | Create | Pure function: changed-file list + known stack dirs → `rollback_scope`. No git, no docker, no network. |
| `scripts/testing/test-classify-rollback-scope.sh` | Create | Unit tests for the classifier. Mirrors `test-detect-stack-changes.sh` harness style. |
| `.github/workflows/deploy.yml` | Modify | Wire the classifier into `prepare`; add `failed_stacks` to `health-check`; add the per-stack branch to `rollback`; report scope in `notify`. |
| `~/.claude/skills/quarantine-image/SKILL.md` | Create | The `/quarantine-image` skill. Lives outside this repo (user skills dir), matching `renovate-trigger`. |

The classifier is a separate script rather than inline YAML because inline `run:` blocks cannot be unit-tested, and this is the one piece of new logic with enough branches to be worth testing. Everything else in Change A is plumbing that is only meaningfully verified end-to-end on a real host.

---

## Task 1: Rollback scope classifier

**Files:**
- Create: `scripts/deployment/classify-rollback-scope.sh`
- Test: `scripts/testing/test-classify-rollback-scope.sh`

- [ ] **Step 1: Write the failing test**

Create `scripts/testing/test-classify-rollback-scope.sh`:

```bash
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
```

Make it executable:

```bash
chmod +x scripts/testing/test-classify-rollback-scope.sh
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/testing/test-classify-rollback-scope.sh`

Expected: every case fails with `got '<none>'`, because `classify-rollback-scope.sh` does not exist yet. Exit code 1.

- [ ] **Step 3: Write the implementation**

Create `scripts/deployment/classify-rollback-scope.sh`:

```bash
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
```

Make it executable:

```bash
chmod +x scripts/deployment/classify-rollback-scope.sh
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `./scripts/testing/test-classify-rollback-scope.sh`

Expected: `Passed: 11  Failed: 0`, exit code 0.

- [ ] **Step 5: Run shellcheck**

Run: `shellcheck -x scripts/deployment/classify-rollback-scope.sh scripts/testing/test-classify-rollback-scope.sh`

Expected: no output, exit code 0. This is the same invocation `.github/workflows/workflow-lint.yml:71` uses, so a clean run here means CI will be clean.

- [ ] **Step 6: Commit**

```bash
git add scripts/deployment/classify-rollback-scope.sh scripts/testing/test-classify-rollback-scope.sh
git commit -m "feat(deploy): add rollback scope classifier

Decides per-stack vs whole-tree rollback from the changed-file list.
Uncertainty always resolves to whole-tree."
```

---

## Task 2: Wire the classifier into `prepare`

**Files:**
- Modify: `.github/workflows/deploy.yml` (job outputs at `:65-80`; new step after `Detect stack changes` at `:165-186`)

- [ ] **Step 1: Add the job output**

In the `prepare` job's `outputs:` block, after the `critical_stacks` line, add:

```yaml
      rollback_scope: ${{ steps.classify-scope.outputs.rollback_scope }}
```

- [ ] **Step 2: Add the classifier step**

Insert this step **after** the `Detect stack changes` step and **before** `Detect critical stacks`:

```yaml
      - name: Classify rollback scope
        id: classify-scope
        # Runs after detect-changes because it needs removed_stacks: a removed
        # stack's directory is gone from the target tree, so discover-stacks
        # never sees it. Without it in the known-dirs set, every stack deletion
        # would look like a root-level change and force whole-tree rollback.
        env:
          CHANGED_FILES: ${{ steps.changed-files.outputs.all_changed_files != '' && steps.changed-files.outputs.all_changed_files || '[]' }}
          ACTIVE_STACKS: ${{ steps.discover-stacks.outputs.stacks }}
          DISABLED_STACKS: ${{ steps.discover-stacks.outputs.disabled_stacks }}
          REMOVED_STACKS: ${{ steps.detect-changes.outputs.removed_stacks || '[]' }}
        run: |
          set -euo pipefail
          stack_dirs=$(jq -cn \
            --argjson a "$ACTIVE_STACKS" \
            --argjson b "$DISABLED_STACKS" \
            --argjson c "$REMOVED_STACKS" \
            '($a + $b + $c) | unique')
          ./.compose-workflow/scripts/deployment/classify-rollback-scope.sh \
            --changed-files "$CHANGED_FILES" \
            --stack-dirs "$stack_dirs"
```

Note the `./.compose-workflow/` prefix: `prepare` checks the workflow's own repo out to that path (`deploy.yml:90-94`) pinned to `job.workflow_sha`. Every other script call in this job uses the same prefix — match it.

- [ ] **Step 3: Verify `all_changed_files` is the right output name**

Run: `grep -n "changed-files.outputs" .github/workflows/deploy.yml`

Expected: existing uses are `deleted_files` and `added_files`. Confirm `tj-actions/changed-files@v47` also exposes `all_changed_files` with `json: true` set (it does — the action's `json: true` input applies to every file-list output). If the JSON array does not materialise at runtime, the classifier's array-type guard emits `whole-tree` and the deploy behaves exactly as it does today. The failure mode is safe.

- [ ] **Step 4: Lint the workflow**

Run:
```bash
yamllint --strict --config-file .yamllint .github/workflows/deploy.yml
actionlint .github/workflows/deploy.yml
```

Expected: no output from either, exit code 0.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/deploy.yml
git commit -m "feat(deploy): expose rollback_scope from prepare"
```

---

## Task 3: `health-check` reports which stacks failed

**Files:**
- Modify: `.github/workflows/deploy.yml` (`health-check` outputs block; the `failed=()` handling at the end of step `h`)

Why this is its own task: `health-check` currently emits only `status`. A bad image release most often fails *health*, not *deploy* — so without this output the per-stack path would have an empty culprit list on exactly the case this whole change exists to handle, and would silently degrade to whole-tree.

- [ ] **Step 1: Add the output declaration**

In the `health-check` job's `outputs:` block, alongside `status`:

```yaml
      failed_stacks: ${{ steps.h.outputs.failed_stacks }}
```

- [ ] **Step 2: Emit the list before exiting**

Replace the tail of step `h` (currently the `if [[ ${#failed[@]} -gt 0 ]]` block) with:

```bash
          if [[ ${#failed[@]} -gt 0 ]]; then
            # Emit the culprit list BEFORE `exit 1` — a step that exits
            # non-zero still has its already-written $GITHUB_OUTPUT honoured,
            # but nothing written after the exit would be.
            json=$(printf '"%s",' "${failed[@]}" | sed 's/,$//')
            echo "failed_stacks=[$json]" >> "$GITHUB_OUTPUT"
            echo "status=failed" >> "$GITHUB_OUTPUT"
            exit 1
          fi
          echo "failed_stacks=[]" >> "$GITHUB_OUTPUT"
          echo "status=healthy" >> "$GITHUB_OUTPUT"
```

The `printf`/`sed` JSON construction is copied verbatim from the `deploy-existing` step (`deploy.yml:424-425`) so both jobs build their arrays identically. Stack names are already constrained to `^[a-zA-Z0-9._-]+$` upstream, so no escaping is needed.

- [ ] **Step 3: Lint**

Run:
```bash
yamllint --strict --config-file .yamllint .github/workflows/deploy.yml
actionlint .github/workflows/deploy.yml
```

Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/deploy.yml
git commit -m "feat(deploy): emit failed_stacks from health-check"
```

---

## Task 4: Per-stack rollback branch

**Files:**
- Modify: `.github/workflows/deploy.yml` (`rollback` job, currently `:684-748`)

This is the highest-risk task in the plan. The rollback job is what runs when things are *already* broken; a bug here turns a one-stack outage into a fleet outage.

- [ ] **Step 1: Extend the job's `needs` and `env`**

The `rollback` job currently declares `needs: [prepare, deploy, health-check]` — unchanged. Add to its `env:` block:

```yaml
      ROLLBACK_SCOPE: ${{ needs.prepare.outputs.rollback_scope || 'whole-tree' }}
      DEPLOY_EXISTING_FAILED: ${{ needs.deploy.outputs.existing_failed_stacks || '[]' }}
      DEPLOY_NEW_FAILED: ${{ needs.deploy.outputs.new_failed_stacks || '[]' }}
      HEALTH_FAILED: ${{ needs.health-check.outputs.failed_stacks || '[]' }}
      NEW_STACKS: ${{ needs.prepare.outputs.new_stacks || '[]' }}
```

The `|| 'whole-tree'` default matters: if `prepare` is ever changed such that the classifier step is skipped, the expression yields empty and this restores today's behavior rather than an empty scope string that matches neither branch.

- [ ] **Step 2: Add the culprit-resolution step as the job's first step**

```yaml
      - name: Resolve rollback plan
        id: plan
        run: |
          set -euo pipefail
          culprits=$(jq -cn \
            --argjson a "$DEPLOY_EXISTING_FAILED" \
            --argjson b "$DEPLOY_NEW_FAILED" \
            --argjson c "$HEALTH_FAILED" \
            '($a + $b + $c) | unique')
          count=$(jq 'length' <<<"$culprits")

          # Per-stack requires BOTH a stack-confined change set AND a known
          # culprit. An empty culprit list means the failure was not attributed
          # to any specific stack (a teardown failure, an infrastructure error,
          # a timeout before any stack was named) — there is nothing to scope
          # to, so the whole-tree reset is the only correct response.
          if [[ "$ROLLBACK_SCOPE" == "per-stack" && "$count" -gt 0 ]]; then
            mode="per-stack"
          else
            mode="whole-tree"
          fi

          {
            echo "mode=$mode"
            echo "culprits=$culprits"
          } >> "$GITHUB_OUTPUT"
          echo "🔄 Rollback mode: $mode (culprits: $culprits, scope: $ROLLBACK_SCOPE)"
```

- [ ] **Step 3: Add the per-stack rollback step**

Insert after `Resolve rollback plan`, before the existing `Tear down new stacks` step:

```yaml
      - name: Roll back failed stacks only
        if: steps.plan.outputs.mode == 'per-stack'
        env:
          CULPRITS: ${{ steps.plan.outputs.culprits }}
        run: |
          set -euo pipefail
          for stack in $(jq -r '.[]' <<<"$CULPRITS"); do
            [[ "$stack" =~ ^[a-zA-Z0-9._-]+$ ]] || {
              echo "::error::invalid stack name: $stack"; exit 1; }

            # Was this stack introduced by the failing deploy? If so it has no
            # previous state to restore — tear it down and leave it gone, the
            # same disposition the whole-tree path gives new stacks.
            if jq -e --arg s "$stack" 'index($s) != null' <<<"$NEW_STACKS" >/dev/null; then
              echo "🛑 Tearing down failed new stack $stack"
              if [[ -f "$LIVE_REPO_PATH/$stack/compose.yaml" || -f "$LIVE_REPO_PATH/$stack/compose.yml" ]]; then
                (cd "$LIVE_REPO_PATH/$stack" && docker compose down) \
                  || echo "::warning::down failed for $stack"
              fi
              continue
            fi

            echo "⏪ Reverting $stack to $PREVIOUS_SHA"
            # Partial checkout: only this stack's directory moves back. HEAD
            # stays at the target SHA and the tree is left dirty — that is
            # fine, the next deploy's `git reset --hard $TARGET_REF`
            # (deploy.yml:283) cleans it before anything else runs.
            git -C "$LIVE_REPO_PATH" checkout "$PREVIOUS_SHA" -- "$stack/"

            [[ -f "$LIVE_REPO_PATH/$stack/compose.yaml" || -f "$LIVE_REPO_PATH/$stack/compose.yml" ]] || {
              echo "::warning::no compose file for $stack after revert; skipping up"
              continue
            }

            # No --pull always and no --build: land on the locally-tagged
            # previous image kept on disk by the prune policy, so recovery does
            # not depend on a registry being reachable mid-incident.
            #
            # The `op run` wrapper is REQUIRED. Without it every ${VAR} in the
            # compose file resolves to empty and the stack comes up
            # misconfigured while reporting success.
            (cd "$LIVE_REPO_PATH/$stack" && \
              op run --no-masking --env-file="$LIVE_REPO_PATH/compose.env" -- \
                docker compose up -d --quiet-pull --wait --remove-orphans) \
              || echo "::warning::per-stack rollback up failed for $stack"
          done
```

- [ ] **Step 4: Gate the three existing whole-tree steps**

Add `if: steps.plan.outputs.mode == 'whole-tree'` to each of the existing steps:

| Step | Current `if:` | New `if:` |
|---|---|---|
| `Tear down new stacks (will not exist after reset)` | `needs.prepare.outputs.has_new_stacks == 'true'` | `steps.plan.outputs.mode == 'whole-tree' && needs.prepare.outputs.has_new_stacks == 'true'` |
| `Reset live tree to previous SHA` | *(none)* | `steps.plan.outputs.mode == 'whole-tree'` |
| `Redeploy stacks at previous SHA` | *(none)* | `steps.plan.outputs.mode == 'whole-tree'` |

Change **only** the `if:` conditions. Leave the bodies of these three steps exactly as they are — they are the tested status quo and the fallback for every case the new path declines to handle.

- [ ] **Step 5: Lint**

Run:
```bash
yamllint --strict --config-file .yamllint .github/workflows/deploy.yml
actionlint .github/workflows/deploy.yml
```

Expected: clean.

- [ ] **Step 6: Re-read the diff against the two invariants**

Run: `git diff`

Confirm by eye:
1. Every `docker compose up` you added is wrapped in `op run --no-masking --env-file=…`.
2. The three original whole-tree steps have gained an `if:` and nothing else.

- [ ] **Step 7: Commit**

```bash
git add .github/workflows/deploy.yml
git commit -m "feat(deploy): scope rollback to failed stacks when safe

Per-stack rollback runs only when the change set is confined to stack
directories AND a culprit stack was identified. Every other case keeps
the existing whole-tree reset."
```

---

## Task 5: Report rollback scope in the Discord notification

**Files:**
- Modify: `.github/workflows/deploy.yml` (`notify` job `env:` block at `:805-811`; pipeline line construction at `:897-902`)

- [ ] **Step 1: Pass the plan into `notify`**

Add to the `notify` job's `env:` block for the summary step:

```yaml
          ROLLBACK_MODE: ${{ needs.rollback.outputs.mode }}
          ROLLBACK_CULPRITS: ${{ needs.rollback.outputs.culprits }}
```

This requires the `rollback` job to expose them. Add to the `rollback` job:

```yaml
    outputs:
      mode: ${{ steps.plan.outputs.mode }}
      culprits: ${{ steps.plan.outputs.culprits }}
```

- [ ] **Step 2: Extend the pipeline line**

Replace the `rollback_line` construction:

```bash
          rollback_line=""
          if [[ "$rollback_status" != "skipped" ]]; then
            rb_icon="✅"; [[ "$rollback_status" != "success" ]] && rb_icon="❌"
            rb_detail=""
            if [[ "$ROLLBACK_MODE" == "per-stack" ]]; then
              rb_names=$(jq -r '. | join(", ")' <<<"${ROLLBACK_CULPRITS:-[]}" 2>/dev/null || echo "")
              rb_detail=" (per-stack: ${rb_names:-unknown})"
            elif [[ "$ROLLBACK_MODE" == "whole-tree" ]]; then
              rb_detail=" (whole-tree)"
            fi
            rollback_line=" → $rb_icon Rollback$rb_detail"
          fi
```

A whole-tree rollback and a one-stack rollback are currently indistinguishable in the alert. That distinction is the first thing the reader needs: it is the difference between "one app is down" and "the entire fleet just moved backwards".

- [ ] **Step 3: Lint**

Run:
```bash
yamllint --strict --config-file .yamllint .github/workflows/deploy.yml
actionlint .github/workflows/deploy.yml
```

Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/deploy.yml
git commit -m "feat(deploy): report rollback scope and culprits in notification"
```

---

## Task 6: The `quarantine-image` skill

**Files:**
- Create: `~/.claude/skills/quarantine-image/SKILL.md`

This file lives **outside this repository**, in the user's skills directory, matching `~/.claude/skills/renovate-trigger/SKILL.md`. It is a single markdown file: frontmatter, prose, inline bash recipes. No helper scripts, no plugin packaging. Read `renovate-trigger/SKILL.md` first and match its voice and structure.

- [ ] **Step 1: Read the reference skill**

Run: `cat ~/.claude/skills/renovate-trigger/SKILL.md`

Note the conventions: `name` + `description` frontmatter where the description enumerates trigger phrases; `## Prerequisites`; one `##` section per operation; explicit guidance on what to do when a step finds nothing.

- [ ] **Step 2: Write the skill**

Create `~/.claude/skills/quarantine-image/SKILL.md` covering, in order:

**Frontmatter.** `name: quarantine-image`. The `description` must enumerate trigger phrases: "quarantine an image", "block a bad image version", "this update broke the deploy", "stop Renovate from re-proposing", "revert and block", "unblock an image version".

**Why revert alone does not work.** State the mechanism up front, because it is the reason the skill exists: `compose-workflow/default.json` groups minor/patch/digest updates into `all-deps` with `automerge: true` and `minimumReleaseAge: "1 hour"`. A `git revert` makes the old version current again, Renovate sees the newer tag as available, and re-proposes and re-merges it within the hour.

**The blocking mechanism, with the trap called out.** `allowedVersions` accepts a version *range* interpreted by the active versioning scheme, or a *regex* in forward slashes, negated as `!/…/`. Use the negated regex. **`!=release-2.7.1` will not work** — it is range syntax, and these repos pin images to custom `regex:` versioning schemes where range operators are not dependable. A negated regex filters the raw version string before any versioning scheme parses it, so one form covers `release-2.7.1`, `4.2.1-ls286`, and `2026-08-24` alike:

```json
{ "matchPackageNames": ["ghcr.io/lukegus/termix"],
  "allowedVersions": "!/^release-2\\.7\\.1$/" }
```

**Prerequisites.** Run from `~/Git/Compose`. `git` and `jq` available. `npx` available for config validation.

**Locating the stack:**

```bash
matches=$(ls -d docker-piwine*/"$STACK"/ 2>/dev/null)
count=$(wc -l <<<"$matches")
```

Zero matches or more than one is an error — ask the user which repo, never guess.

**Finding the last-known-good image line.** Walk the file's history and take the previous `image:` line verbatim, tag *and* digest together:

```bash
git -C "$REPO" log --format=%H -- "$STACK/compose.yaml" \
  | while read -r sha; do
      line=$(git -C "$REPO" show "$sha:$STACK/compose.yaml" | grep -m1 "image: $PKG:")
      case "$line" in *"$BAD_VERSION"*) continue ;; esac
      echo "$line"; break
    done
```

Emphasise: **never compose a `@sha256:` digest by hand.** Restoring a tag/digest pair that a real Renovate run already wrote is what keeps this consistent with the project's "Renovate owns digest pinning" rule.

**Writing the block.** Edit the consuming repo's `.github/renovate.json` — never `compose-workflow/default.json`, since a bad `termix` build is not `docker-piwine-office`'s problem. Two cases, and the second is the one that bites:

- No existing block for the package → append a new rule object.
- A block already exists → **widen the alternation in place**: `!/^release-(2\.7\.1|2\.8\.0)$/`. Do not append a second rule. Two `packageRules` entries matching the same package both apply and the later `allowedVersions` silently wins, discarding the earlier block.

Keep the block rule **separate** from the package's existing `versioning` rule (see `docker-piwine/.github/renovate.json:19-23` for termix). Renovate merges matching rules in order so the two coexist, and separation lets `--unblock` delete a whole object rather than surgically editing a shared one.

**Committing.** Both files in **one commit**. State why the ordering is load-bearing: the compose revert makes `2.7.0` current in the same commit that makes `2.7.1` invisible. Split across two commits there is a window where the pinned-current version is also the blocked version, which Renovate handles badly.

**Validating before pushing:**

```bash
npx --yes --package renovate -- renovate-config-validator "$REPO/.github/renovate.json"
```

**After pushing.** Do not trigger a Renovate run — point at the existing `renovate-trigger` skill.

**`--unblock <stack>`.** Remove the package's rule object and its comment, commit, note that Renovate will offer the version again on its next run. Do not touch the compose file: by unblock time you want the newest version, not the one you blocked.

**Cases to refuse rather than guess at:**

| Case | Behavior |
|---|---|
| Stack name matches zero or multiple repos | Error; ask the user to disambiguate |
| No prior version in history | Error; nothing to revert to — tell the user to fix forward |
| `image:` uses a floating tag (`:latest`) | Error; no version to block — the answer is a digest pin, not a quarantine |

- [ ] **Step 3: Verify the skill is discoverable**

Run: `ls ~/.claude/skills/quarantine-image/SKILL.md && head -5 ~/.claude/skills/quarantine-image/SKILL.md`

Expected: the file exists and the frontmatter parses (opening `---`, `name:`, `description:`, closing `---`). The skill will be listed in a new Claude Code session.

- [ ] **Step 4: Dry-run the recipes against the real termix history**

Do not commit anything. Verify each recipe returns what the skill claims:

```bash
cd ~/Git/Compose
# Stack resolution finds exactly one repo
ls -d docker-piwine*/termix/ 2>/dev/null
# The previous image line is recoverable verbatim, with its digest
git -C docker-piwine log --format=%H -- termix/compose.yaml | head -5
git -C docker-piwine show 65606eb:termix/compose.yaml | grep -m1 'image: ghcr.io/lukegus/termix'
```

Expected: one directory; a list of SHAs; an `image:` line pinned to `release-2.7.0` **with** an `@sha256:` digest. If the digest is absent, the recipe in Step 2 needs adjusting before the skill is trusted.

- [ ] **Step 5: Verify a block validates**

Build a throwaway copy and run the real validator against it:

```bash
cp docker-piwine/.github/renovate.json /tmp/rv.json
jq '.packageRules += [{"matchPackageNames":["ghcr.io/lukegus/termix"],"allowedVersions":"!/^release-2\\.7\\.1$/"}]' \
  /tmp/rv.json > /tmp/rv-blocked.json
npx --yes --package renovate -- renovate-config-validator /tmp/rv-blocked.json
```

Expected: the validator reports the config is valid. If it rejects the `allowedVersions` string, stop — the escaping in the skill is wrong and must be fixed before Task 6 is considered done.

- [ ] **Step 6: Commit (this repo's docs only)**

The skill file lives outside this repo and is not committed here. Nothing to commit for this task unless the dry-run revealed a spec inaccuracy — in which case amend the spec and commit that.

---

## Task 7: Live-host validation — NOT PERFORMED (decision, 2026-08-25)

The user declined a live test. Deliberately breaking a stack on `docker-piwine`
to exercise both rollback paths was offered and turned down, and the per-stack
path was shipped **enabled** rather than behind an opt-in flag.

**Decision:** ship active; the first real stack failure exercises the new path.

### What this leaves unverified

Everything logic-level is covered: 19 classifier unit tests, the 8 existing
transition tests, and stubbed dry runs of the rollback loop against real
throwaway git repos. Four things are not, and unit tests structurally cannot
reach them:

1. `op run` + `docker compose up` against a rolled-back tree — no 1Password or
   Docker daemon in the dev environment.
2. `git checkout $PREVIOUS_SHA -- <stack>/` against the runner's *persistent*
   clone (tested only against throwaway repos).
3. GitHub Actions expression evaluation of the new outputs — specifically the
   skipped-job empty-string cases and the `|| '[]'` defaults.
4. The classifier receiving a real `all_changed_files` value post-`escape_json`
   fix (verified against the action's source, not a live run).

### Known accepted risk

The per-stack step swallows `up` failures as warnings:

```bash
op run ... docker compose up ... || echo "::warning::per-stack rollback up failed for $stack"
```

This matches the pre-existing whole-tree step's behavior, so it is consistent —
but it means a per-stack rollback that fails to bring the stack back up still
reports the job **green**, and the Discord line shows a success icon. Without a
live test, the first occurrence will be during a real incident.

Mitigating factor: every malformed-input path in `Resolve rollback plan`
degrades to `whole-tree`, so the *scope* decision fails safe. The residual risk
is concentrated in the docker/`op`/Actions layer, not in the classification
logic.

If this proves noisy in practice, the fix is to collect failed stacks in the
loop and `exit 1` at the end, so the job result reflects reality.

## Out of scope

Named here so they are not quietly added:

- Automatic quarantine from the deploy workflow. The workflow cannot distinguish a bad image from a bad healthcheck, a bad config change, or a transient registry blip, and a false positive would block a good version.
- Changes to `minimumReleaseAge` or automerge policy in `default.json`.
- Expiry metadata or scheduled auditing of accumulated blocks.
- Wiring `scripts/testing/*.sh` into CI. Worth doing; not part of this change.
