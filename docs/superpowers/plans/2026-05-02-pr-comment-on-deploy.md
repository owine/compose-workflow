# PR Comment on Deploy Result — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Post a sticky markdown comment to the originating PR when the reusable deploy workflow completes for a SHA that maps to a merged PR.

**Architecture:** Three new steps added to the existing `notify` job in `compose-workflow/.github/workflows/deploy.yml` (sparse-checkout → resolve PR → post/patch comment). Body construction lives in a new `scripts/deployment/build-pr-comment.sh` script. Notify job moves from inherited `${{ inputs.runner }}` to GitHub-hosted `ubuntu-24.04` so notifications fire even when self-hosted runners are unhealthy. Each consumer repo's caller workflow gains a `pull-requests: write` permission grant.

**Tech Stack:** GitHub Actions, bash, `gh` CLI, `jq`, GitHub REST API.

**Spec:** `docs/superpowers/specs/2026-05-02-pr-comment-on-deploy-design.md`

---

## File Structure

**Files created:**
- `compose-workflow/scripts/deployment/build-pr-comment.sh` — markdown body builder (~80 lines)

**Files modified:**
- `compose-workflow/.github/workflows/deploy.yml` — notify job runner change + 3 new steps
- `docker-piwine/.github/workflows/deploy.yml` — add `permissions:` block
- `docker-piwine-office/.github/workflows/deploy.yml` — add `permissions:` block
- `docker-zendc/.github/workflows/deploy.yml` — add `permissions:` block

**Boundary rationale:** All body-building markdown logic lives in the script, isolated from YAML. The workflow steps only handle: GitHub API auth, PR resolution, comment dispatch. This keeps the deploy.yml diff small (~30 lines added) and lets the script be invoked locally for smoke testing.

---

## Task 1: Create the comment-body builder script

**Files:**
- Create: `compose-workflow/scripts/deployment/build-pr-comment.sh`

The script reads deploy outputs from environment variables and writes a complete markdown comment body to stdout. It handles three top-level outcomes (deployed, rolled back, failed) and conditionally includes rollback tables when applicable.

**Inputs (environment variables, all set by the caller workflow):**

- `REPO_NAME` — e.g. `docker-piwine`
- `TARGET_REF` — full SHA being deployed
- `RUN_ID`, `RUN_NUMBER`, `REPOSITORY` — for run-link construction
- `DEPLOY_STATUS`, `HEALTH_STATUS`, `CLEANUP_STATUS`, `ROLLBACK_STATUS`, `ROLLBACK_HEALTH_STATUS`
- `HEALTHY_STACKS`, `DEGRADED_STACKS`, `FAILED_STACKS`
- `ROLLBACK_HEALTHY_STACKS`, `ROLLBACK_DEGRADED_STACKS`, `ROLLBACK_FAILED_STACKS`
- `RUNNING_CONTAINERS`, `TOTAL_CONTAINERS`, `SUCCESS_RATE`
- `ROLLBACK_RUNNING_CONTAINERS`, `ROLLBACK_TOTAL_CONTAINERS`, `ROLLBACK_SUCCESS_RATE`
- `COMMIT_SUBJECT` — first line of the deployed commit's message

- [ ] **Step 1.1: Write the script**

Create `compose-workflow/scripts/deployment/build-pr-comment.sh`:

```bash
#!/usr/bin/env bash
# Build a markdown PR comment body from deploy job outputs.
# All inputs are read from environment variables (see plan for full list).
set -euo pipefail

short_sha="${TARGET_REF:0:7}"

# Determine outcome: deployed | rolled-back | failed
if [[ "$DEPLOY_STATUS" == "success" && "$HEALTH_STATUS" == "success" ]]; then
  outcome="deployed"
  status_emoji="✅"
  status_word="Deployed"
elif [[ "$ROLLBACK_STATUS" == "success" ]]; then
  outcome="rolled-back"
  status_emoji="⚠️"
  status_word="Rolled back"
else
  outcome="failed"
  status_emoji="❌"
  status_word="Failed"
fi

# Format a stack-bucket value, falling back to em-dash if empty.
fmt_bucket() {
  local v="$1"
  if [[ -z "$v" ]]; then
    printf -- "—"
  else
    printf "%s" "$v"
  fi
}

# Render a stack-status table.
render_stack_table() {
  local title="$1" healthy="$2" degraded="$3" failed="$4"
  cat <<EOF
**$title**

| Status | Stacks |
|--------|--------|
| ✅ Healthy | $(fmt_bucket "$healthy") |
| ⚠️ Degraded | $(fmt_bucket "$degraded") |
| ❌ Failed | $(fmt_bucket "$failed") |
EOF
}

# Render the pipeline-pills line.
render_pipeline_line() {
  local deploy_pill health_pill cleanup_pill rollback_extra=""
  case "$DEPLOY_STATUS" in success) deploy_pill="✅" ;; skipped) deploy_pill="⏭️" ;; *) deploy_pill="❌" ;; esac
  case "$HEALTH_STATUS" in success) health_pill="✅" ;; skipped) health_pill="⏭️" ;; *) health_pill="❌" ;; esac
  case "$CLEANUP_STATUS" in success) cleanup_pill="✅" ;; skipped) cleanup_pill="⏭️" ;; *) cleanup_pill="❌" ;; esac

  local line="$deploy_pill Deploy → $health_pill Health → $cleanup_pill Cleanup"
  if [[ "$ROLLBACK_STATUS" != "skipped" && -n "$ROLLBACK_STATUS" ]]; then
    local rb_pill verify_pill=""
    case "$ROLLBACK_STATUS" in success) rb_pill="✅" ;; *) rb_pill="❌" ;; esac
    line+=" → $rb_pill Rollback"
    case "$ROLLBACK_HEALTH_STATUS" in
      success) line+=" → ✅ Verify" ;;
      failure) line+=" → ❌ Verify" ;;
    esac
  fi
  printf "%s" "$line"
}

# Begin output.
printf '<!-- compose-deploy-result:%s -->\n' "$REPO_NAME"
printf '## 🚀 %s deploy: %s %s\n\n' "$REPO_NAME" "$status_emoji" "$status_word"
printf '**Commit:** [`%s`](https://github.com/%s/commit/%s) %s\n' \
  "$short_sha" "$REPOSITORY" "$TARGET_REF" "$COMMIT_SUBJECT"
printf '**Run:** [#%s](https://github.com/%s/actions/runs/%s)\n' \
  "$RUN_NUMBER" "$REPOSITORY" "$RUN_ID"

# Health line — use rollback values if rolled back.
if [[ "$outcome" == "rolled-back" ]]; then
  printf '**Health (rollback):** 🟢 %s/%s services (%s%%)\n\n' \
    "${ROLLBACK_RUNNING_CONTAINERS:-0}" "${ROLLBACK_TOTAL_CONTAINERS:-0}" "${ROLLBACK_SUCCESS_RATE:-0}"
else
  printf '**Health:** 🟢 %s/%s services (%s%%)\n\n' \
    "${RUNNING_CONTAINERS:-0}" "${TOTAL_CONTAINERS:-0}" "${SUCCESS_RATE:-0}"
fi

# Stack table(s).
if [[ "$outcome" == "rolled-back" ]]; then
  if [[ -n "$HEALTHY_STACKS$DEGRADED_STACKS$FAILED_STACKS" ]]; then
    render_stack_table "Stack Status (failed deploy)" "$HEALTHY_STACKS" "$DEGRADED_STACKS" "$FAILED_STACKS"
    printf '\n\n'
  fi
  render_stack_table "Rollback Stack Status" \
    "$ROLLBACK_HEALTHY_STACKS" "$ROLLBACK_DEGRADED_STACKS" "$ROLLBACK_FAILED_STACKS"
  printf '\n\n'
elif [[ -n "$HEALTHY_STACKS$DEGRADED_STACKS$FAILED_STACKS" ]]; then
  render_stack_table "Stack Status" "$HEALTHY_STACKS" "$DEGRADED_STACKS" "$FAILED_STACKS"
  printf '\n\n'
fi

# Pipeline pills — collapsed on success, raw on any failure.
pipeline_line=$(render_pipeline_line)
if [[ "$outcome" == "deployed" ]]; then
  cat <<EOF
<details><summary>Pipeline</summary>

$pipeline_line

</details>
EOF
else
  printf '**Pipeline:** %s\n' "$pipeline_line"
fi
```

- [ ] **Step 1.2: Make it executable**

```bash
chmod +x compose-workflow/scripts/deployment/build-pr-comment.sh
```

- [ ] **Step 1.3: Run shellcheck**

```bash
cd compose-workflow && shellcheck scripts/deployment/build-pr-comment.sh
```

Expected: no output (clean pass). The existing `scripts/deployment/.shellcheckrc` will be picked up automatically.

- [ ] **Step 1.4: Smoke test — successful deploy**

```bash
cd compose-workflow
REPO_NAME=docker-piwine \
TARGET_REF=abc1234567890abc1234567890abc1234567890a \
RUN_ID=12345 RUN_NUMBER=42 REPOSITORY=owine/docker-piwine \
DEPLOY_STATUS=success HEALTH_STATUS=success CLEANUP_STATUS=success \
ROLLBACK_STATUS=skipped ROLLBACK_HEALTH_STATUS=skipped \
HEALTHY_STACKS="dockge, portainer, swag" \
DEGRADED_STACKS="" FAILED_STACKS="" \
ROLLBACK_HEALTHY_STACKS="" ROLLBACK_DEGRADED_STACKS="" ROLLBACK_FAILED_STACKS="" \
RUNNING_CONTAINERS=14 TOTAL_CONTAINERS=15 SUCCESS_RATE=93 \
ROLLBACK_RUNNING_CONTAINERS=0 ROLLBACK_TOTAL_CONTAINERS=0 ROLLBACK_SUCCESS_RATE=0 \
COMMIT_SUBJECT="feat(swag): bump traefik to v3.3" \
./scripts/deployment/build-pr-comment.sh
```

Expected: stdout contains `<!-- compose-deploy-result:docker-piwine -->`, header `## 🚀 docker-piwine deploy: ✅ Deployed`, the commit/run lines, a healthy stack table with `—` for degraded and failed, and pipeline pills inside `<details>`.

- [ ] **Step 1.5: Smoke test — rolled back**

Same as above but with `DEPLOY_STATUS=failure HEALTH_STATUS=failure ROLLBACK_STATUS=success ROLLBACK_HEALTH_STATUS=success FAILED_STACKS="monitoring" ROLLBACK_HEALTHY_STACKS="dockge, portainer, swag" ROLLBACK_RUNNING_CONTAINERS=14 ROLLBACK_TOTAL_CONTAINERS=15 ROLLBACK_SUCCESS_RATE=93`.

Expected: header `⚠️ Rolled back`, both stack tables present (failed + rollback), pipeline line raw (not collapsed).

- [ ] **Step 1.6: Smoke test — outright failure**

`DEPLOY_STATUS=failure HEALTH_STATUS=failure ROLLBACK_STATUS=failure ROLLBACK_HEALTH_STATUS=failure`.

Expected: header `❌ Failed`, pipeline line raw with two `❌` pills.

- [ ] **Step 1.7: Commit**

```bash
git -C compose-workflow add scripts/deployment/build-pr-comment.sh
git -C compose-workflow commit -m "feat(notify): add PR-comment body builder script"
```

---

## Task 2: Wire script into the notify job

**Files:**
- Modify: `compose-workflow/.github/workflows/deploy.yml` — `notify` job (around line 887)

- [ ] **Step 2.1: Change notify job runner**

Find the `notify` job header and change its `runs-on:`:

```yaml
notify:
  name: Discord Notification
  runs-on: ubuntu-24.04   # was: ${{ inputs.runner }}
  needs: [deploy]
  if: always()
```

- [ ] **Step 2.2: Add sparse-checkout step at the top of `notify.steps`**

Insert immediately before the existing `Configure 1Password Service Account` step:

```yaml
- name: Checkout compose-workflow scripts
  if: inputs.force-deploy != true && needs.deploy.outputs.deployment_needed != 'false'
  uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd  # v6.0.2
  with:
    repository: owine/compose-workflow
    sparse-checkout: scripts/deployment
    sparse-checkout-cone-mode: false
```

(Use the same pinned SHA as the existing `actions/checkout@de0fac2e...` references in the deploy job to keep Renovate happy.)

- [ ] **Step 2.3: Add resolve-PR step after the existing Discord step**

Insert after the `Send Discord notification` step and before `Unload Discord webhook`:

```yaml
- name: Resolve PR for deploy
  id: pr
  if: inputs.force-deploy != true && needs.deploy.outputs.deployment_needed != 'false'
  env:
    GH_TOKEN: ${{ github.token }}
  run: |
    set -euo pipefail
    PR=$(gh api "repos/${{ github.repository }}/commits/${{ inputs.target-ref }}/pulls" \
      --jq '[.[] | select(.merged_at != null)] | .[0].number // empty')
    if [[ -z "$PR" ]]; then
      echo "ℹ️ No merged PR for ${{ inputs.target-ref }} — skipping comment"
      echo "skip=true" >> "$GITHUB_OUTPUT"
      exit 0
    fi
    MARKER="<!-- compose-deploy-result:${{ inputs.repo-name }} -->"
    EXISTING=$(gh api "repos/${{ github.repository }}/issues/${PR}/comments" \
      --jq "[.[] | select(.body | startswith(\"$MARKER\"))] | .[0].id // empty")
    # Note: when no existing comment is found, $EXISTING is empty.
    # GitHub Actions maps `comment_id=` to an empty-string output, which the
    # next step's `[[ -n "$COMMENT_ID" ]]` guard correctly treats as falsy.
    # Do NOT add a `// empty` guard or default value here — the empty-string
    # contract is what drives create-vs-update branching downstream.
    {
      echo "pr=$PR"
      echo "comment_id=$EXISTING"
      echo "skip=false"
    } >> "$GITHUB_OUTPUT"
    echo "✅ Resolved PR #$PR (existing comment: ${EXISTING:-none})"
```

- [ ] **Step 2.4: Add post-comment step**

Immediately after the `Resolve PR for deploy` step:

```yaml
- name: Post PR deploy comment
  if: steps.pr.conclusion == 'success' && steps.pr.outputs.skip == 'false'
  env:
    GH_TOKEN: ${{ github.token }}
    PR: ${{ steps.pr.outputs.pr }}
    COMMENT_ID: ${{ steps.pr.outputs.comment_id }}
    REPO_NAME: ${{ inputs.repo-name }}
    TARGET_REF: ${{ inputs.target-ref }}
    RUN_ID: ${{ github.run_id }}
    RUN_NUMBER: ${{ github.run_number }}
    REPOSITORY: ${{ github.repository }}
    DEPLOY_STATUS: ${{ needs.deploy.outputs.deploy_status }}
    HEALTH_STATUS: ${{ needs.deploy.outputs.health_status }}
    CLEANUP_STATUS: ${{ needs.deploy.outputs.cleanup_status }}
    ROLLBACK_STATUS: ${{ needs.deploy.outputs.rollback_status }}
    ROLLBACK_HEALTH_STATUS: ${{ needs.deploy.outputs.rollback_health_status }}
    HEALTHY_STACKS: ${{ needs.deploy.outputs.healthy_stacks }}
    DEGRADED_STACKS: ${{ needs.deploy.outputs.degraded_stacks }}
    FAILED_STACKS: ${{ needs.deploy.outputs.failed_stacks }}
    ROLLBACK_HEALTHY_STACKS: ${{ needs.deploy.outputs.rollback_healthy_stacks }}
    ROLLBACK_DEGRADED_STACKS: ${{ needs.deploy.outputs.rollback_degraded_stacks }}
    ROLLBACK_FAILED_STACKS: ${{ needs.deploy.outputs.rollback_failed_stacks }}
    RUNNING_CONTAINERS: ${{ needs.deploy.outputs.running_containers }}
    TOTAL_CONTAINERS: ${{ needs.deploy.outputs.total_containers }}
    SUCCESS_RATE: ${{ needs.deploy.outputs.success_rate }}
    ROLLBACK_RUNNING_CONTAINERS: ${{ needs.deploy.outputs.rollback_running_containers }}
    ROLLBACK_TOTAL_CONTAINERS: ${{ needs.deploy.outputs.rollback_total_containers }}
    ROLLBACK_SUCCESS_RATE: ${{ needs.deploy.outputs.rollback_success_rate }}
    COMMIT_SUBJECT: ${{ steps.commit-msg.outputs.message }}
  run: |
    set -euo pipefail
    BODY=$(./scripts/deployment/build-pr-comment.sh)
    if [[ -n "$COMMENT_ID" ]]; then
      echo "🔄 Updating existing comment $COMMENT_ID"
      gh api -X PATCH "repos/${{ github.repository }}/issues/comments/${COMMENT_ID}" \
        -f body="$BODY"
    else
      echo "📝 Posting new comment to PR #$PR"
      gh api -X POST "repos/${{ github.repository }}/issues/${PR}/comments" \
        -f body="$BODY"
    fi
```

- [ ] **Step 2.5: Validate workflow syntax**

```bash
cd compose-workflow
actionlint .github/workflows/deploy.yml
yamllint --strict .github/workflows/deploy.yml
```

Expected: both commands exit 0 with no output.

- [ ] **Step 2.6: Commit**

```bash
git -C compose-workflow add .github/workflows/deploy.yml
git -C compose-workflow commit -m "feat(deploy): post PR comment when deploy fires from PR merge"
```

---

## Task 3: Grant `pull-requests: write` in consumer repos

The reusable workflow inherits `GITHUB_TOKEN` permissions from the calling job. Without this grant, the new `gh api POST/PATCH` calls will return 403.

- [ ] **Step 3.1: docker-piwine**

Edit `docker-piwine/.github/workflows/deploy.yml`. Find the job that does `uses: owine/compose-workflow/.github/workflows/deploy.yml@main` and add a `permissions:` block:

```yaml
jobs:
  deploy:
    permissions:
      contents: read
      pull-requests: write
    uses: owine/compose-workflow/.github/workflows/deploy.yml@main
    secrets: inherit
    with:
      # ... existing inputs
```

Validate:

```bash
yamllint --strict docker-piwine/.github/workflows/deploy.yml
actionlint docker-piwine/.github/workflows/deploy.yml
```

Commit:

```bash
git -C docker-piwine add .github/workflows/deploy.yml
git -C docker-piwine commit -m "ci(deploy): grant pull-requests: write for PR comment posting"
```

- [ ] **Step 3.2: docker-piwine-office**

Same as Step 3.1, applied to `docker-piwine-office/.github/workflows/deploy.yml`. Validate, commit.

- [ ] **Step 3.3: docker-zendc**

Same as Step 3.1, applied to `docker-zendc/.github/workflows/deploy.yml`. Validate, commit.

---

## Task 4: End-to-end validation on a real PR

GitHub Actions can only be truly tested by running them. Use a low-risk consumer repo (docker-piwine-office is the smallest) for the first live test.

- [ ] **Step 4.1: Push compose-workflow changes**

```bash
git -C compose-workflow push
```

- [ ] **Step 4.2: Create a trivial PR in docker-piwine-office**

Edit a comment in any compose file or bump a label value — anything that triggers CI but doesn't change runtime behavior. Push branch, open PR, wait for CI, merge.

- [ ] **Step 4.3: Verify on the merged PR**

Within ~5 min of merge, the PR should receive a comment from `github-actions[bot]` with the `<!-- compose-deploy-result:docker-piwine-office -->` marker, header showing `✅ Deployed`, commit/run links resolving correctly, stack table populated, and pipeline pills collapsed inside `<details>`.

- [ ] **Step 4.4: Verify sticky-update behavior**

Re-run the deploy workflow manually on the same SHA via `gh workflow run`. Confirm the existing comment is *updated in place* (no second comment appears, comment timestamp updates).

- [ ] **Step 4.5: Verify force-deploy skip**

Re-run with `force-deploy: true`. Confirm no new comment is posted and the existing comment is not modified.

- [ ] **Step 4.6: Verify failure path** (optional, opportunistic)

If a real deploy fails during the rollout window, confirm the comment renders `❌ Failed` or `⚠️ Rolled back` with the pipeline line in raw (not collapsed) form. Don't engineer a failure — just observe one if it happens.

---

## Rollback plan

If the feature misbehaves in production:

1. **Comment-only failures** (resolve or post step fails): the `notify` job's other steps still complete. No deploy impact. Revert `deploy.yml` notify changes via a single commit revert.
2. **Notify job entirely broken** (e.g., checkout step fails on GH-hosted runner): Discord notifications also fail since they share the job. Revert `compose-workflow` and the new feature is removed across all consumers on the next deploy of any of them.
3. **Permissions mistake in a consumer repo**: revert just that repo's `permissions:` block; only that repo loses the PR-comment feature.

No state to migrate, no secrets rotation, no DB. Pure additive change.

---

## Out of scope (future work, do not implement here)

- Failed-container log excerpts in the comment body (would require new outputs from the deploy job).
- Linking from comment to the rollback diff (commit-range link between `previous_sha` and `target-ref`).
- Slack mirror.
