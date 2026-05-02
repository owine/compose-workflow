# PR Comment on Deploy Result

**Date:** 2026-05-02
**Status:** Draft

> **Correction (2026-05-02):** Initial draft targeted `deploy.yml`, but consumer repos (`docker-piwine`, `docker-piwine-office`, `docker-zendc`) all call `deploy-local.yml@<sha>`, the self-hosted-runner workflow consolidated 2026-04-30. `deploy.yml` is effectively legacy. This spec has been corrected to target `deploy-local.yml`, which has a different job structure (`prepare` / `deploy` / `health-check` / `rollback` / `notify`) and high-level aggregated outputs (no per-stack health buckets, no per-container counts) — driving a simpler comment body.

## Problem

When the deploy workflow runs after a PR merge, the result is announced on Discord but not recorded on the PR itself. PR authors and reviewers have no in-context signal that their merged change deployed successfully (or failed and rolled back), and Discord history is ephemeral. We want a durable, in-PR record of the deploy outcome that ties the deployed SHA back to the PR that introduced it.

## Goals

- Post a markdown comment to the originating PR when a deploy completes for a SHA that maps to a merged PR.
- Use a sticky comment (update-in-place) for normal runs so the PR shows the latest deploy state without clutter.
- Post a fresh comment on `force-deploy: true` runs so retroactive force-deploys don't overwrite the original automatic deploy result.
- Skip the comment for no-op deploys (`deployment_needed == false`) to avoid noise.
- Keep notification reliability decoupled from the deploy host (notifications must fire even if the self-hosted runner that performed the deploy is unhealthy).

## Non-goals

- Surfacing failed-container log excerpts in the comment (would require new outputs from the deploy job; out of scope here).
- Supporting non-merged PRs, draft PRs, or unmerged commits — only commits associated with a merged PR get a comment.
- Cross-repo PR comments (e.g., commenting on a `compose-workflow` PR from a downstream consumer's deploy).

## Design

### Where the logic lives

Three new steps in the existing `notify` job in `compose-workflow/.github/workflows/deploy-local.yml`, running after the Discord step: a sparse checkout (notify currently has no checkout — needed to access the script), a PR resolver, and a comment poster. Body-building logic lives in `compose-workflow/scripts/deployment/build-pr-comment.sh`, consistent with the existing pattern of factoring complex logic out of YAML (see `deploy-stacks.sh`, `health-check.sh`) and matching the established `scripts/deployment/` location.

### Notify job runner

Change `notify` job's `runs-on:` from `[self-hosted, "${{ inputs.runner-label }}"]` to `ubuntu-24.04`. The notify job has never needed deploy-host access — Discord and GH API calls are pure cloud-to-cloud — and pinning it to a GitHub-hosted runner ensures notifications fire even if the self-hosted runner is down (which is precisely when notifications matter most). Deploy/health-check/rollback jobs stay on `[self-hosted, "${{ inputs.runner-label }}"]`.

### When to comment (gating logic)

Comment is posted when **all** of these hold:

1. `inputs.force-deploy != true` — force-deploys skip PR comments entirely (per Q4(c); force-deploys are typically manual fixups well after merge, and commenting on an old PR with a fresh deploy result is confusing context).
2. `needs.deploy.outputs.deployment_needed != 'false'` — no-op deploys skip (per Q3(b)).
3. `gh api repos/{owner}/{repo}/commits/{sha}/pulls` returns at least one PR with `merged_at != null` — i.e., the target SHA maps to a merged PR.

If any condition fails, the comment step is skipped cleanly (visible as "skipped" in the workflow run UI for transparency).

### Sticky comment behavior

Each comment starts with an HTML marker on its first line:

```
<!-- compose-deploy-result:<repo-name> -->
```

The `<repo-name>` suffix scopes the marker per consumer repo so multi-repo scenarios don't collide. The post step:

1. Lists existing comments on the PR via `gh api repos/{repo}/issues/{pr}/comments`.
2. Finds any comment whose body starts with the marker.
3. If found and **not** a force-deploy: `PATCH /repos/{repo}/issues/comments/{id}` to update in place.
4. If not found or this is a force-deploy: `POST /repos/{repo}/issues/{pr}/comments` to create a new comment.

(In practice, force-deploys are filtered out at gate (1) above, so the "force-deploy → new comment" branch never fires under current rules. The marker-based update-or-create logic still handles the create case correctly.)

### Comment body structure

Markdown rendered by GitHub. Sections (simplified from the original draft because `deploy-local.yml` only emits high-level aggregated outputs — no per-stack health buckets and no per-container counts):

**Marker line** (hidden, first line):
```
<!-- compose-deploy-result:<repo-name> -->
```

**Header**:
```
## 🚀 <repo-name> deploy: <status emoji> <status word>
```
Status word comes from `steps.status.outputs.title_suffix` — one of `Deployed`, `Rolled Back`, `Failed`. (`No Changes` is filtered out at the gate.)

**Summary block**:
```
**Commit:** [`<short-sha>`](…/commit/<sha>) `<commit subject>`
**Run:** [#<run_number>](…/actions/runs/<run_id>)
```
Commit subject is wrapped in inline-code backticks to neutralize markdown injection.

**Description line**: the rich one-liner from `steps.status.outputs.description` (e.g., `✅ **Deployment completed successfully**`, `🔄 **Deployment failed but rolled back successfully**`, `❌ **Deployment failed**`).

**Removed-stacks line** (only when present): from `steps.status.outputs.removed_line` — e.g. `🗑️ **Removed stacks:** foo, bar`.

**Pipeline pills**: from `steps.status.outputs.pipeline` (e.g., `✅ Deploy → ✅ Health` or `❌ Deploy → ❌ Health → ✅ Rollback`).

- On success: collapsed inside `<details><summary>Pipeline</summary>` since most readers won't need it.
- On any failure: emitted as raw `**Pipeline:** …` line (auto-expanded) so failure context doesn't require a click.

**Why simpler than original draft:** `deploy-local.yml` consolidated multiple jobs and dropped per-stack output enumeration in favor of a single aggregated `status` step. Adding stack-level outputs back across `deploy` and `health-check` jobs would be scope creep; the comment matches the data the workflow actually exposes.

### Permissions

Reusable workflows inherit `GITHUB_TOKEN` permissions from the calling job — `deploy.yml` itself does not declare its own `permissions:` block, and adding one would have no effect. The grant must happen on the caller's job. Each consumer repo's deploy job that calls `deploy.yml` must declare:

```yaml
jobs:
  deploy:
    permissions:
      contents: read
      pull-requests: write
    uses: owine/compose-workflow/.github/workflows/deploy.yml@main
```

Three repos: `docker-piwine`, `docker-piwine-office`, `docker-zendc`.

### Why `pull-requests: write` and not `issues: write`

PR comments use the issues comments API endpoint (PRs are issues under the hood), but `pull-requests: write` is the semantically correct scope per GitHub's documentation for PR comment automation. Either grants the necessary access; `pull-requests` reads more clearly in the caller's `permissions:` block.

## Implementation plan

### Files touched

1. **`compose-workflow/.github/workflows/deploy-local.yml`**
   - Change `notify` job `runs-on:` from `[self-hosted, "${{ inputs.runner-label }}"]` to `ubuntu-24.04`.
   - Add step `Checkout compose-workflow scripts` (sparse-checkout `scripts/deployment/`) — notify currently has no checkout; needed to access `build-pr-comment.sh`.
   - Add step `Resolve PR for deploy` (gated by force-deploy and the existing `steps.status.outputs.deployment_needed` check; resolves PR number and existing sticky comment ID).
   - Add step `Post PR deploy comment` (builds body via `build-pr-comment.sh`, posts or patches via `gh api`).

2. **`compose-workflow/scripts/deployment/build-pr-comment.sh`** (new, ~80 lines)
   - Reads deploy outputs from environment variables.
   - Emits a complete markdown comment body to stdout.
   - Handles success, rollback, and failure variants.
   - Auto-expands pipeline pills on failure; collapses inside `<details>` on success.

3. **`docker-piwine/.github/workflows/deploy.yml`** — add `permissions:` block to deploy job.

4. **`docker-piwine-office/.github/workflows/deploy.yml`** — same.

5. **`docker-zendc/.github/workflows/deploy.yml`** — same.

### Step skeletons

```yaml
- name: Checkout compose-workflow scripts
  if: inputs.force-deploy != true && needs.deploy.outputs.deployment_needed != 'false'
  uses: actions/checkout@v6
  with:
    repository: owine/compose-workflow
    sparse-checkout: scripts/deployment
    sparse-checkout-cone-mode: false

- name: Resolve PR for deploy
  id: pr
  if: inputs.force-deploy != true && needs.deploy.outputs.deployment_needed != 'false'
  env:
    GH_TOKEN: ${{ github.token }}
  run: |
    PR=$(gh api "repos/${{ github.repository }}/commits/${{ inputs.target-ref }}/pulls" \
      --jq '[.[] | select(.merged_at != null)] | .[0].number // empty')
    if [[ -z "$PR" ]]; then
      echo "skip=true" >> "$GITHUB_OUTPUT"
      exit 0
    fi
    MARKER="<!-- compose-deploy-result:${{ inputs.repo-name }} -->"
    EXISTING=$(gh api "repos/${{ github.repository }}/issues/${PR}/comments" \
      --jq "[.[] | select(.body | startswith(\"$MARKER\"))] | .[0].id // empty")
    {
      echo "pr=$PR"
      echo "comment_id=$EXISTING"
      echo "skip=false"
    } >> "$GITHUB_OUTPUT"

- name: Post PR deploy comment
  if: steps.pr.conclusion == 'success' && steps.pr.outputs.skip == 'false'
  env:
    GH_TOKEN: ${{ github.token }}
    PR: ${{ steps.pr.outputs.pr }}
    COMMENT_ID: ${{ steps.pr.outputs.comment_id }}
    REPO_NAME: ${{ inputs.repo-name }}
    TARGET_REF: ${{ inputs.target-ref }}
    # … plus all needs.deploy.outputs.* needed by the script
  run: |
    BODY=$(./scripts/deployment/build-pr-comment.sh)
    if [[ -n "$COMMENT_ID" ]]; then
      gh api -X PATCH "repos/${{ github.repository }}/issues/comments/${COMMENT_ID}" \
        -f body="$BODY"
    else
      gh api -X POST "repos/${{ github.repository }}/issues/${PR}/comments" \
        -f body="$BODY"
    fi
```

## Edge cases & decisions

- **Multiple PRs associated with one SHA**: take the first merged PR (`.[0]`). Multiple-PR-per-SHA is rare (only happens with cherry-picks across branches) and picking the first is a reasonable default.
- **PR closed without merge**: `select(.merged_at != null)` filters these out — no comment.
- **Rerun of an old workflow**: the SHA still maps to the same PR; sticky update keeps the comment fresh. Acceptable.
- **PR is in a fork**: comments still go on the upstream PR object; `pull-requests: write` on the upstream repo's `GITHUB_TOKEN` is sufficient.
- **`gh api` rate limiting**: three API calls per notify run on update (resolve PR, list comments, PATCH comment); four on first comment (resolve PR, list comments, POST comment — list returns empty). Well within limits.
- **Unmerged fork PRs**: filtered by `select(.merged_at != null)` so they never trigger a comment. This is correct behavior (we only comment on actual deploys, which only happen post-merge), not a bug — flagged here so it isn't mistaken for one during implementation.
- **Comment grows too large**: GitHub's comment body limit is 65,536 chars. With many stacks, table rows are short; we're nowhere near the limit.

## Out of scope (future work)

- Failed-container log excerpts in the comment body (requires new deploy-job outputs).
- Linking from the comment to the rollback diff (commit-range link between `previous_sha` and `target-ref`).
- Slack mirror of the same comment shape, if Slack is ever added alongside Discord.
