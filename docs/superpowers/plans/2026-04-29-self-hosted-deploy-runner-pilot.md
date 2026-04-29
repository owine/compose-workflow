# Self-Hosted Deploy Runner Pilot — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pilot a self-hosted GitHub Actions runner on the `docker-piwine-office` deploy host, eliminating Tailscale + SSH from the deploy path while preserving all current behaviors (stack categorization, critical detection, rollback, dockge handling, Discord notifications).

**Architecture:** A new reusable workflow `deploy-local.yml` runs on `[self-hosted, piwine-office]`. It is **workflow-native, not script-driven**: the deploy/health/rollback/cleanup operations that today live inside SSH heredocs (`deploy-stacks.sh`, `health-check.sh`, `rollback-stacks.sh`, `cleanup-stack.sh`) are inlined as workflow steps, with per-stack work expressed as a `strategy.matrix` job for native parallelism and per-stack visibility in the Actions UI. The two genuinely-pure-logic scripts (`detect-stack-changes.sh`, `detect-critical-stacks.sh`) are reused. `detect-stack-changes.sh` gets one focused refactor to add `--mode local` (its only SSH-coupled siblings stay untouched). The existing `deploy.yml` (SSH-based) is unchanged during the pilot.

**Tech Stack:** GitHub Actions (reusable workflows, matrix strategy), bash, Docker Compose, 1Password Connect, systemd (for the runner service).

**Spec:** `docs/superpowers/specs/2026-04-29-self-hosted-deploy-runner-pilot-design.md`

---

## File Structure

**Created in `compose-workflow`:**
- `.github/workflows/deploy-local.yml` — new reusable workflow

**Modified in `compose-workflow`:**
- `scripts/deployment/detect-stack-changes.sh` — add `--mode local` (the only script touched)

**Untouched in `compose-workflow`:**
- `deploy-stacks.sh`, `health-check.sh`, `rollback-stacks.sh`, `cleanup-stack.sh` — remain SSH-based, used by `deploy.yml` for piwine and zendc until they migrate
- `detect-critical-stacks.sh` — already mode-agnostic, called as-is
- `deploy.yml` — unchanged

**Created/modified in `docker-piwine-office`:**
- `.github/workflows/deploy-local.yml` — manual pilot caller (Task 4.1)
- `.github/workflows/deploy.yml` — switched to invoke the new reusable workflow (Task 4.3)

**Out-of-band (host setup, not version-controlled):**
- `/home/deploy/actions-runner/` — runner installation
- systemd service `actions.runner.owine-docker-piwine-office.<name>.service`
- Ownership transfer of `/opt/compose` and `/opt/dockge` to `deploy:deploy`

---

## Phase 1 — Refactor `detect-stack-changes.sh` for local execution

This is the single script that must change. It has 6 `ssh_retry "ssh ... 'cmd'"` calls; in local mode each becomes a direct `bash -c 'cmd'` (or equivalent) running against the `_work/` checkout. The other four heredoc-driven scripts are not touched — their logic moves inline in Phase 2.

### Task 1.1: Add `--mode local` to `detect-stack-changes.sh`

**Files:**
- Modify: `scripts/deployment/detect-stack-changes.sh`

- [ ] **Step 1: Add `--mode` argument and validate**

```bash
# Near other defaults
MODE="ssh"

# In argument parser
--mode)
  MODE="$2"
  shift 2
  ;;

# After parsing
if [[ "$MODE" != "ssh" && "$MODE" != "local" ]]; then
  echo "❌ --mode must be 'ssh' or 'local', got: $MODE"
  exit 1
fi
```

- [ ] **Step 2: Make `--ssh-user` and `--ssh-host` conditional on mode**

Move the existing `require_var SSH_USER` / `require_var SSH_HOST` (lines ~61-62) inside an `if [[ "$MODE" == "ssh" ]]; then ... fi` guard. Add a `--live-repo-path` argument required when `MODE=local` (default unset; error in `local` mode if missing).

- [ ] **Step 3: Introduce a `run_remote` wrapper**

Near the top of the script, after sourcing helpers:
```bash
run_remote() {
  # Usage: echo "<bash script>" | run_remote arg1 arg2 ...
  # Reads script from stdin, runs with positional args.
  local args=("$@")
  if [[ "$MODE" == "local" ]]; then
    LIVE_REPO_PATH="$LIVE_REPO_PATH" bash -s "${args[@]}"
  else
    ssh_retry 3 5 "ssh -o \"StrictHostKeyChecking no\" $SSH_USER@$SSH_HOST /bin/bash -s ${args[*]@Q}"
  fi
}
```

- [ ] **Step 4: Replace each of the 6 SSH call sites**

For each line that currently reads:
```bash
echo "$detect_script" | ssh_retry 3 5 "ssh ... $SSH_USER@$SSH_HOST /bin/bash -s \"$arg1\" \"$arg2\""
```
Change to:
```bash
echo "$detect_script" | run_remote "$arg1" "$arg2"
```

Inside each `$detect_script` heredoc body, change any `cd /opt/compose` to `cd "$LIVE_REPO_PATH"` (or pass the path as a positional arg to make the script self-contained). The heredoc bodies should already be agnostic to whether they run locally or remotely — they're plain bash.

- [ ] **Step 5: Run `shellcheck`**

```bash
shellcheck scripts/deployment/detect-stack-changes.sh
```
Expected: no new warnings.

- [ ] **Step 6: Local smoke test**

Pick a real commit pair on this repo (e.g., `git rev-parse HEAD` and `git rev-parse HEAD~1`) and run:
```bash
LIVE_REPO_PATH=/Users/owine/Git/Compose/compose-workflow \
./scripts/deployment/detect-stack-changes.sh \
  --mode local \
  --previous-sha $(git rev-parse HEAD~1) \
  --target-ref $(git rev-parse HEAD) \
  --live-repo-path /Users/owine/Git/Compose/compose-workflow \
  --removed-files '[]'
```
Expected: outputs `removed_stacks=[]`, `existing_stacks=[]`, `new_stacks=[]` (or actual values if there are stacks in this repo — there aren't, since `compose-workflow` itself has no compose stacks). On a real repo with stacks (e.g., a clone of `docker-piwine-office`), expect non-empty arrays. Crucially: **no SSH attempt, no `command not found: ssh`**.

- [ ] **Step 7: Backward-compat verification**

Run the existing `deploy.yml` workflow against `docker-piwine` (push to a throwaway branch and trigger via `workflow_dispatch`, or wait for the next Renovate PR merge). Expected: green deploy. The default `MODE=ssh` keeps current behavior.

- [ ] **Step 8: Open PR for Phase 1 to `compose-workflow`**

```bash
git add scripts/deployment/detect-stack-changes.sh
git commit -m "feat(detect-stack-changes): add --mode local for self-hosted runner support"
git push
gh pr create --title "feat(detect-stack-changes): add --mode local for self-hosted runner" \
             --body "Adds a --mode local flag to detect-stack-changes.sh for use by the upcoming deploy-local.yml workflow. Default mode remains ssh; existing deploy.yml callers are unaffected."
```

Wait for a green deploy on `docker-piwine` after merge before proceeding to Phase 2.

---

## Phase 2 — Build `deploy-local.yml` (`compose-workflow` repo)

Multi-job workflow with native parallelism. Job graph:

```
prepare → teardown-removed → update-tree → deploy-dockge ─┐
                                          └→ deploy-existing (matrix) → deploy-new (matrix) → health → [rollback?] → notify
```

All jobs run on `[self-hosted, piwine-office]`. The matrix jobs give per-stack visibility in the Actions UI and use GitHub-native parallelism instead of bash PID tracking.

### Task 2.1: Workflow skeleton with inputs and the `prepare` job

**Files:**
- Create: `.github/workflows/deploy-local.yml`

- [ ] **Step 1: Write the skeleton with `prepare` job**

```yaml
---
name: Deploy (Local Self-Hosted)

on:
  workflow_call:
    inputs:
      live-repo-path:
        description: "Absolute path to the live compose tree on the runner host"
        required: true
        type: string
      live-dockge-path:
        description: "Absolute path to dockge's compose tree (when has-dockge=true)"
        required: false
        type: string
        default: /opt/dockge
      repo-name:
        required: true
        type: string
      webhook-url:
        required: true
        type: string
      discord-user-id:
        required: true
        type: string
      target-ref:
        required: true
        type: string
      has-dockge:
        type: boolean
        default: false
      force-deploy:
        type: boolean
        default: false
      auto-detect-critical:
        type: boolean
        default: true
      critical-services:
        type: string
        default: '[]'
      image-pull-timeout:
        type: number
        default: 600
      service-startup-timeout:
        type: number
        default: 300

permissions:
  contents: read

jobs:
  prepare:
    runs-on: [self-hosted, piwine-office]
    timeout-minutes: 5
    outputs:
      previous_sha: ${{ steps.previous-sha.outputs.previous_sha }}
      removed_stacks: ${{ steps.detect-changes.outputs.removed_stacks }}
      existing_stacks: ${{ steps.detect-changes.outputs.existing_stacks }}
      new_stacks: ${{ steps.detect-changes.outputs.new_stacks }}
      has_removed_stacks: ${{ steps.detect-changes.outputs.has_removed_stacks }}
      has_existing_stacks: ${{ steps.detect-changes.outputs.has_existing_stacks }}
      has_new_stacks: ${{ steps.detect-changes.outputs.has_new_stacks }}
      critical_stacks: ${{ steps.detect-critical.outputs.critical_stacks }}
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd  # v6.0.2
        with:
          fetch-depth: 0
          ref: ${{ inputs.target-ref }}

      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd
        with:
          repository: owine/compose-workflow
          ref: main
          path: .compose-workflow

      - name: Capture previous deployment SHA from live tree
        id: previous-sha
        env:
          LIVE_REPO_PATH: ${{ inputs.live-repo-path }}
        run: |
          set -euo pipefail
          CURRENT_SHA=$(git -C "$LIVE_REPO_PATH" rev-parse HEAD 2>/dev/null || echo "")
          if [[ "$CURRENT_SHA" =~ ^[a-fA-F0-9]{40}$ ]]; then
            echo "previous_sha=$CURRENT_SHA" >> "$GITHUB_OUTPUT"
            echo "✅ previous_sha=$CURRENT_SHA"
          else
            echo "previous_sha=HEAD^" >> "$GITHUB_OUTPUT"
            echo "⚠️  Live tree HEAD unreadable — using HEAD^ as fallback"
          fi

      - name: Get changed files (for removal detection)
        id: changed-files
        if: steps.previous-sha.outputs.previous_sha != inputs.target-ref
        continue-on-error: true
        uses: tj-actions/changed-files@9426d40962ed5378910ee2e21d5f8c6fcbf2dd96  # v47.0.6
        with:
          json: true
          sha: ${{ inputs.target-ref }}
          base_sha: ${{ steps.previous-sha.outputs.previous_sha }}

      - name: Detect stack changes
        id: detect-changes
        env:
          LIVE_REPO_PATH: ${{ inputs.live-repo-path }}
        run: |
          ./.compose-workflow/scripts/deployment/detect-stack-changes.sh \
            --mode local \
            --previous-sha "${{ steps.previous-sha.outputs.previous_sha }}" \
            --target-ref "${{ inputs.target-ref }}" \
            --live-repo-path "$LIVE_REPO_PATH" \
            --removed-files '${{ steps.changed-files.outputs.deleted_files }}'

      - name: Detect critical stacks
        id: detect-critical
        if: inputs.auto-detect-critical
        run: ./.compose-workflow/scripts/deployment/detect-critical-stacks.sh
```

- [ ] **Step 2: Lint**

```bash
actionlint .github/workflows/deploy-local.yml
yamllint --strict .github/workflows/deploy-local.yml
```

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/deploy-local.yml
git commit -m "feat(deploy-local): add prepare job — capture SHA and detect changes"
```

### Task 2.2: `teardown-removed` job

**Files:**
- Modify: `.github/workflows/deploy-local.yml`

- [ ] **Step 1: Append the job**

```yaml
  teardown-removed:
    needs: prepare
    if: needs.prepare.outputs.has_removed_stacks == 'true'
    runs-on: [self-hosted, piwine-office]
    timeout-minutes: 10
    env:
      LIVE_REPO_PATH: ${{ inputs.live-repo-path }}
      REMOVED_STACKS: ${{ needs.prepare.outputs.removed_stacks }}
    steps:
      - name: Stop removed stacks (uses pre-reset compose files)
        run: |
          set -euo pipefail
          for stack in $(echo "$REMOVED_STACKS" | jq -r '.[]'); do
            compose_file="$LIVE_REPO_PATH/$stack/compose.yaml"
            if [[ -f "$compose_file" ]]; then
              echo "🛑 Stopping $stack"
              docker compose -f "$compose_file" down || echo "::warning::down failed for $stack"
            else
              echo "::warning::compose file missing for removed stack $stack"
            fi
          done

      - name: Discord notify removed stacks
        env:
          DISCORD_WEBHOOK_URL: ${{ inputs.webhook-url }}  # NOTE: 1P resolution happens via load-secrets-action; see Task 2.6
        run: |
          # Placeholder — full Discord payload added in Task 2.6 alongside other notifications
          echo "🔔 Removed: $REMOVED_STACKS"
```

(The Discord notification is stubbed here; the full implementation is consolidated in Task 2.6 to keep secret loading in one place.)

- [ ] **Step 2: Lint and commit**

```bash
actionlint .github/workflows/deploy-local.yml
yamllint --strict .github/workflows/deploy-local.yml
git add .github/workflows/deploy-local.yml
git commit -m "feat(deploy-local): add teardown-removed job"
```

### Task 2.3: `update-tree` job — point of no return

**Files:**
- Modify: `.github/workflows/deploy-local.yml`

- [ ] **Step 1: Append the job**

```yaml
  update-tree:
    needs: [prepare, teardown-removed]
    # Run if teardown-removed succeeded OR was skipped (no removed stacks)
    if: |
      always() && needs.prepare.result == 'success'
      && (needs.teardown-removed.result == 'success' || needs.teardown-removed.result == 'skipped')
    runs-on: [self-hosted, piwine-office]
    timeout-minutes: 5
    env:
      LIVE_REPO_PATH: ${{ inputs.live-repo-path }}
      TARGET_REF: ${{ inputs.target-ref }}
    steps:
      - name: Skip if already at target SHA (and not forced)
        id: gate
        run: |
          set -euo pipefail
          CURRENT_SHA=$(git -C "$LIVE_REPO_PATH" rev-parse HEAD)
          if [[ "$CURRENT_SHA" == "$TARGET_REF" && "${{ inputs.force-deploy }}" != "true" ]]; then
            echo "skipped=true" >> "$GITHUB_OUTPUT"
            echo "ℹ️  Already at $TARGET_REF; skipping update"
          else
            echo "skipped=false" >> "$GITHUB_OUTPUT"
          fi

      - name: Update live tree
        if: steps.gate.outputs.skipped == 'false'
        run: |
          set -euo pipefail
          git -C "$LIVE_REPO_PATH" fetch
          git -C "$LIVE_REPO_PATH" reset --hard "$TARGET_REF"
          echo "✅ /opt/compose now at $TARGET_REF"
```

- [ ] **Step 2: Lint and commit**

```bash
actionlint .github/workflows/deploy-local.yml
yamllint --strict .github/workflows/deploy-local.yml
git add .github/workflows/deploy-local.yml
git commit -m "feat(deploy-local): add update-tree job"
```

### Task 2.4: `deploy-dockge`, `deploy-existing`, `deploy-new` matrix jobs

**Files:**
- Modify: `.github/workflows/deploy-local.yml`

- [ ] **Step 1: Append `deploy-dockge`**

```yaml
  deploy-dockge:
    needs: [prepare, update-tree]
    if: |
      always() && needs.update-tree.result == 'success'
      && inputs.has-dockge
    runs-on: [self-hosted, piwine-office]
    timeout-minutes: 10
    env:
      DOCKGE_PATH: ${{ inputs.live-dockge-path }}
      IMAGE_PULL_TIMEOUT: ${{ inputs.image-pull-timeout }}
      SERVICE_STARTUP_TIMEOUT: ${{ inputs.service-startup-timeout }}
    steps:
      - name: Pull and start dockge
        run: |
          set -euo pipefail
          cd "$DOCKGE_PATH"
          timeout "$IMAGE_PULL_TIMEOUT" docker compose pull
          timeout "$SERVICE_STARTUP_TIMEOUT" docker compose up -d --wait
```

- [ ] **Step 2: Append `deploy-existing` matrix job**

```yaml
  deploy-existing:
    needs: [prepare, update-tree, deploy-dockge]
    if: |
      always()
      && needs.update-tree.result == 'success'
      && (needs.deploy-dockge.result == 'success' || needs.deploy-dockge.result == 'skipped')
      && needs.prepare.outputs.has_existing_stacks == 'true'
    runs-on: [self-hosted, piwine-office]
    timeout-minutes: 15
    strategy:
      fail-fast: false
      matrix:
        stack: ${{ fromJSON(needs.prepare.outputs.existing_stacks) }}
    env:
      LIVE_REPO_PATH: ${{ inputs.live-repo-path }}
      IMAGE_PULL_TIMEOUT: ${{ inputs.image-pull-timeout }}
      SERVICE_STARTUP_TIMEOUT: ${{ inputs.service-startup-timeout }}
    steps:
      - name: Load 1Password env for stack
        # Most stacks read compose.env via docker compose; if any stack needs op
        # references resolved at deploy time, do it here. For now, no-op.
        run: echo "ℹ️  Stack ${{ matrix.stack }} uses compose.env at runtime"

      - name: Pull and deploy ${{ matrix.stack }}
        run: |
          set -euo pipefail
          cd "$LIVE_REPO_PATH/${{ matrix.stack }}"
          timeout "$IMAGE_PULL_TIMEOUT" docker compose pull
          timeout "$SERVICE_STARTUP_TIMEOUT" docker compose up -d --wait
```

- [ ] **Step 3: Append `deploy-new` matrix job (depends on existing succeeding)**

```yaml
  deploy-new:
    needs: [prepare, update-tree, deploy-existing]
    if: |
      always()
      && needs.update-tree.result == 'success'
      && (needs.deploy-existing.result == 'success' || needs.deploy-existing.result == 'skipped')
      && needs.prepare.outputs.has_new_stacks == 'true'
    runs-on: [self-hosted, piwine-office]
    timeout-minutes: 15
    strategy:
      fail-fast: false
      matrix:
        stack: ${{ fromJSON(needs.prepare.outputs.new_stacks) }}
    env:
      LIVE_REPO_PATH: ${{ inputs.live-repo-path }}
      IMAGE_PULL_TIMEOUT: ${{ inputs.image-pull-timeout }}
      SERVICE_STARTUP_TIMEOUT: ${{ inputs.service-startup-timeout }}
    steps:
      - name: Pull and deploy ${{ matrix.stack }}
        run: |
          set -euo pipefail
          cd "$LIVE_REPO_PATH/${{ matrix.stack }}"
          timeout "$IMAGE_PULL_TIMEOUT" docker compose pull
          timeout "$SERVICE_STARTUP_TIMEOUT" docker compose up -d --wait
```

- [ ] **Step 4: Lint and commit**

```bash
actionlint .github/workflows/deploy-local.yml
yamllint --strict .github/workflows/deploy-local.yml
git add .github/workflows/deploy-local.yml
git commit -m "feat(deploy-local): add deploy-dockge and per-stack matrix jobs"
```

### Task 2.5: `health-check` and `rollback` jobs

**Files:**
- Modify: `.github/workflows/deploy-local.yml`

`health-check` validates that critical stacks reached `healthy` per `docker compose ps`. Logic ported from `health-check.sh`'s heredoc body, simplified: per-stack `docker compose ps --format json`, parse `Health` field, error if any critical stack is not `healthy` (or `running` for stacks without healthchecks).

- [ ] **Step 1: Append `health-check`**

```yaml
  health-check:
    needs: [prepare, deploy-existing, deploy-new]
    if: |
      always()
      && (needs.deploy-existing.result == 'success' || needs.deploy-existing.result == 'skipped')
      && (needs.deploy-new.result == 'success' || needs.deploy-new.result == 'skipped')
      && (needs.deploy-existing.result != 'skipped' || needs.deploy-new.result != 'skipped')
    runs-on: [self-hosted, piwine-office]
    timeout-minutes: 5
    outputs:
      status: ${{ steps.h.outputs.status }}
    env:
      LIVE_REPO_PATH: ${{ inputs.live-repo-path }}
      CRITICAL_STACKS: ${{ needs.prepare.outputs.critical_stacks }}
    steps:
      - name: Health check critical stacks
        id: h
        run: |
          set -euo pipefail
          failed=()
          for stack in $(echo "$CRITICAL_STACKS" | jq -r '.[]'); do
            cd "$LIVE_REPO_PATH/$stack"
            services=$(docker compose ps --format json | jq -s '.')
            unhealthy=$(echo "$services" | jq -r \
              '[.[] | select(.Health == "unhealthy" or (.Health == "" and .State != "running"))] | length')
            if [[ "$unhealthy" -gt 0 ]]; then
              failed+=("$stack")
              echo "::error::Critical stack $stack has $unhealthy unhealthy services"
              docker compose logs --tail 50
            fi
          done
          if [[ ${#failed[@]} -gt 0 ]]; then
            echo "status=failed" >> "$GITHUB_OUTPUT"
            exit 1
          fi
          echo "status=healthy" >> "$GITHUB_OUTPUT"
```

- [ ] **Step 2: Append `rollback`**

```yaml
  rollback:
    needs: [prepare, deploy-existing, deploy-new, health-check]
    if: |
      always()
      && needs.prepare.outputs.previous_sha != 'HEAD^'
      && (needs.deploy-existing.result == 'failure'
          || needs.deploy-new.result == 'failure'
          || needs.health-check.result == 'failure')
    runs-on: [self-hosted, piwine-office]
    timeout-minutes: 15
    env:
      LIVE_REPO_PATH: ${{ inputs.live-repo-path }}
      PREVIOUS_SHA: ${{ needs.prepare.outputs.previous_sha }}
    steps:
      - name: Reset live tree to previous SHA
        run: git -C "$LIVE_REPO_PATH" reset --hard "$PREVIOUS_SHA"

      - name: Redeploy stacks at previous SHA
        run: |
          set -euo pipefail
          for stack_dir in "$LIVE_REPO_PATH"/*/; do
            [[ -f "$stack_dir/compose.yaml" ]] || continue
            cd "$stack_dir"
            docker compose pull || true
            docker compose up -d --wait || echo "::warning::rollback up failed for $stack_dir"
          done

  cleanup-failed-new:
    needs: [prepare, deploy-new]
    if: always() && needs.deploy-new.result == 'failure'
    runs-on: [self-hosted, piwine-office]
    timeout-minutes: 5
    env:
      LIVE_REPO_PATH: ${{ inputs.live-repo-path }}
      NEW_STACKS: ${{ needs.prepare.outputs.new_stacks }}
    steps:
      - name: Tear down failed new stacks
        run: |
          set -euo pipefail
          for stack in $(echo "$NEW_STACKS" | jq -r '.[]'); do
            cd "$LIVE_REPO_PATH/$stack" 2>/dev/null || continue
            docker compose down || true
          done
```

- [ ] **Step 3: Lint and commit**

```bash
actionlint .github/workflows/deploy-local.yml
yamllint --strict .github/workflows/deploy-local.yml
git add .github/workflows/deploy-local.yml
git commit -m "feat(deploy-local): add health-check, rollback, cleanup-failed-new jobs"
```

### Task 2.6: `notify` job (single source of Discord truth)

**Files:**
- Modify: `.github/workflows/deploy-local.yml`

Consolidate Discord notifications into one job that runs at the end and reports: success / partial-failure-rolled-back / partial-failure-no-rollback / removed-stacks-summary. Loads 1Password secrets here.

- [ ] **Step 1: Append the job**

```yaml
  notify:
    needs:
      - prepare
      - teardown-removed
      - update-tree
      - deploy-dockge
      - deploy-existing
      - deploy-new
      - health-check
      - rollback
    if: always()
    runs-on: [self-hosted, piwine-office]
    timeout-minutes: 5
    env:
      OP_SERVICE_ACCOUNT_TOKEN: ${{ secrets.OP_SERVICE_ACCOUNT_TOKEN }}
    steps:
      - uses: 1password/load-secrets-action@v3
        id: op
        with:
          export-env: true
        env:
          DISCORD_WEBHOOK_URL: ${{ inputs.webhook-url }}
          DISCORD_USER_ID: ${{ inputs.discord-user-id }}

      - name: Determine overall status and post notification
        env:
          REPO_NAME: ${{ inputs.repo-name }}
          TARGET_REF: ${{ inputs.target-ref }}
          REMOVED_STACKS: ${{ needs.prepare.outputs.removed_stacks }}
          HEALTH_STATUS: ${{ needs.health-check.outputs.status }}
        run: |
          set -euo pipefail
          # Compose payload based on job results; mention user on failure.
          # Reuse jq-based payload pattern from existing deploy.yml.
          # (Full implementation: copy the success/failure embed templates from
          # current deploy.yml lines ~830-960, swapping field values for these
          # job results.)
          # TODO: paste Discord payload here from existing workflow's notify step.
          echo "Will post Discord embed for $REPO_NAME @ $TARGET_REF"
```

- [ ] **Step 2: Port the Discord payload from the existing `deploy.yml`**

Copy the success and failure embed JSON templates from `deploy.yml`'s notify step. Adapt field references to use `needs.<job>.result` outputs from this workflow. Do not recreate from scratch — keep payloads identical to today's so the channel messages look the same.

- [ ] **Step 3: Lint and commit**

```bash
actionlint .github/workflows/deploy-local.yml
yamllint --strict .github/workflows/deploy-local.yml
git add .github/workflows/deploy-local.yml
git commit -m "feat(deploy-local): add notify job with Discord payload"
```

### Task 2.7: Cross-check against current `deploy.yml` and open PR

- [ ] **Step 1: Step-list diff**

```bash
diff <(grep -E "^\s*- name:" .github/workflows/deploy.yml | sort -u) \
     <(grep -E "^\s*- name:" .github/workflows/deploy-local.yml | sort -u)
```
Expected differences in `deploy-local.yml`: missing all Tailscale, SSH known-hosts, SSH multiplexing, `Determine previous deployment SHA`, `Store current deployment for rollback` steps. Confirm no business-logic step is missing: deploy existing, deploy new, dockge, health, rollback, cleanup-failed-new, notify, removed notify all present.

- [ ] **Step 2: Open PR for Phase 2**

```bash
gh pr create --title "feat(workflows): add deploy-local.yml for self-hosted runner deploys" \
             --body "Workflow-native rewrite of the deploy logic for self-hosted runners. Each stack runs in its own matrix job; health/rollback/cleanup steps are inline (no SSH heredoc baggage). Reuses detect-stack-changes.sh (--mode local) and detect-critical-stacks.sh from Phase 1. Existing deploy.yml unchanged. Cannot be exercised end-to-end until Phase 3 (host setup) and Phase 4 (caller wiring) land."
```

Merge after maintainer review of the workflow shape. The file is dormant until called.

---

## Phase 3 — Host Setup (out-of-band, human-admin)

These steps run on the `docker-piwine-office` host as a human admin with sudo. They are not version-controlled. Capture in `~/Git/Compose/CLAUDE.md` or a private runbook for reproducibility on the next two hosts.

### Task 3.1: Provision the deploy user

- [ ] **Step 1: Create user, grant docker access**

```bash
sudo useradd -m -s /bin/bash deploy
sudo usermod -aG docker deploy
```

- [ ] **Step 2: Verify docker access**

```bash
sudo -u deploy docker ps
```
Expected: lists running containers (or empty), no permission error.

- [ ] **Step 3: Transfer ownership**

```bash
sudo chown -R deploy:deploy /opt/compose /opt/dockge
```

- [ ] **Step 4: Verify git operations as deploy**

```bash
sudo -u deploy git -C /opt/compose status
sudo -u deploy git -C /opt/compose rev-parse HEAD
sudo -u deploy git -C /opt/dockge status 2>/dev/null || echo "(dockge may not be a git repo — that's fine)"
```
Expected: clean status, valid SHA on `/opt/compose`. No `safe.directory` warnings.

### Task 3.2: Install and register the runner

- [ ] **Step 1: Get a registration token**

`https://github.com/owine/docker-piwine-office/settings/actions/runners/new` → copy the registration token (1-hour validity).

- [ ] **Step 2: Download and extract**

```bash
sudo -u deploy bash -c '
  cd ~ && mkdir -p actions-runner && cd actions-runner
  curl -o actions-runner.tar.gz -L https://github.com/actions/runner/releases/download/v<VERSION>/actions-runner-linux-arm64-<VERSION>.tar.gz
  tar xzf actions-runner.tar.gz
'
```
Pin `<VERSION>` to a specific stable release; record in the runbook.

- [ ] **Step 3: Register**

```bash
sudo -u deploy bash -c '
  cd ~/actions-runner
  ./config.sh --url https://github.com/owine/docker-piwine-office \
              --token <TOKEN> --labels piwine-office --unattended --replace
'
```

- [ ] **Step 4: Install systemd service running as deploy**

```bash
cd /home/deploy/actions-runner
sudo ./svc.sh install deploy
sudo ./svc.sh start
sudo ./svc.sh status
```

- [ ] **Step 5: Verify in GitHub UI**

Settings → Actions → Runners → one online runner with labels `self-hosted, Linux, ARM64, piwine-office`.

### Task 3.3: Smoke test — runner executes a trivial workflow

- [ ] **Step 1: Add temporary smoke workflow to `docker-piwine-office`**

`.github/workflows/runner-smoke.yml`:
```yaml
---
name: Runner Smoke Test
on:
  workflow_dispatch:
permissions:
  contents: read
jobs:
  smoke:
    runs-on: [self-hosted, piwine-office]
    steps:
      - run: |
          set -euo pipefail
          echo "user: $(whoami)"
          docker ps
          git -C /opt/compose rev-parse HEAD
          test -d /opt/dockge && echo "/opt/dockge OK"
          jq --version
          # Verify tools the new workflow depends on
          command -v timeout
          command -v docker
```

- [ ] **Step 2: Trigger and verify**

`gh workflow run -R owine/docker-piwine-office runner-smoke.yml`

Verify:
- `whoami` → `deploy`
- `docker ps` succeeds without sudo
- `git -C /opt/compose rev-parse HEAD` returns a valid SHA
- `/opt/dockge` exists
- `jq`, `timeout`, `docker` are on PATH

If `jq` is missing, `apt install jq` as root (one-time host-prep). Document in runbook.

- [ ] **Step 3: Delete the smoke workflow**

```bash
git -C ~/Git/Compose/docker-piwine-office rm .github/workflows/runner-smoke.yml
git -C ~/Git/Compose/docker-piwine-office commit -m "chore: remove runner smoke test"
git -C ~/Git/Compose/docker-piwine-office push
```

---

## Phase 4 — Caller Wiring (`docker-piwine-office`)

### Task 4.1: Manual pilot caller

**Files:**
- Create: `.github/workflows/deploy-local.yml` in `docker-piwine-office`

- [ ] **Step 1: Write caller**

```yaml
---
name: Deploy (Local) — Manual Pilot

on:
  workflow_dispatch:
    inputs:
      target-ref:
        description: "Git SHA to deploy (default: HEAD of main)"
        required: false
        default: ""
      force-deploy:
        type: boolean
        default: false

permissions:
  contents: read

concurrency:
  group: deploy-piwine-office
  cancel-in-progress: false

jobs:
  resolve-ref:
    runs-on: ubuntu-24.04
    outputs:
      sha: ${{ steps.r.outputs.sha }}
    steps:
      - uses: actions/checkout@v6
      - id: r
        run: |
          REF="${{ inputs.target-ref }}"
          if [ -z "$REF" ]; then REF=$(git rev-parse HEAD); fi
          echo "sha=$REF" >> "$GITHUB_OUTPUT"

  deploy:
    needs: resolve-ref
    uses: owine/compose-workflow/.github/workflows/deploy-local.yml@main
    secrets: inherit
    with:
      live-repo-path: /opt/compose
      live-dockge-path: /opt/dockge
      repo-name: docker-piwine-office
      webhook-url: "op://Docker/discord-github-notifications/piwine_office_webhook_url"
      discord-user-id: "op://Docker/discord-github-notifications/user_id"
      target-ref: ${{ needs.resolve-ref.outputs.sha }}
      has-dockge: true
      force-deploy: ${{ inputs.force-deploy }}
```

Cross-check the 1Password references against the existing caller `deploy.yml` to avoid typos.

- [ ] **Step 2: Lint, commit, push**

```bash
actionlint .github/workflows/deploy-local.yml
yamllint --strict .github/workflows/deploy-local.yml
git add .github/workflows/deploy-local.yml
git commit -m "feat(deploy): add manual pilot caller for self-hosted runner"
git push
```

### Task 4.2: End-to-end smoke test

- [ ] **Step 1: Trigger with `force-deploy: true`**

```bash
gh workflow run -R owine/docker-piwine-office "Deploy (Local) — Manual Pilot" -f force-deploy=true
```

- [ ] **Step 2: Watch run**

In Actions UI verify in order:
- `prepare` job: `previous_sha` matches `git -C /opt/compose rev-parse HEAD` from the box (run that command in a separate terminal during the run to confirm)
- `teardown-removed`: skipped (nothing removed in a no-op deploy)
- `update-tree`: completes (`gate.skipped` may be true if force-deploy not set; with force, runs the reset)
- `deploy-dockge`: runs and succeeds
- `deploy-existing`: matrix runs `dozzle` and `portainer` in parallel; both green
- `deploy-new`: skipped
- `health-check`: green
- `rollback`, `cleanup-failed-new`: skipped
- `notify`: posts to the piwine-office Discord channel

- [ ] **Step 3: Verify host state**

```bash
sudo -u deploy git -C /opt/compose rev-parse HEAD
docker ps --filter "label=com.docker.compose.project" --format "{{.Names}} {{.Status}}"
```
Expected: SHA matches deployed; `dozzle`, `portainer`, and dockge containers all healthy.

- [ ] **Step 4: If smoke fails, do not proceed**

Diagnose against spec failure-modes table. Common pitfalls: 1Password token scope, `safe.directory` (ownership), missing `jq`/`timeout` on PATH, runner not picking up jobs (label mismatch). Fix in `compose-workflow`, push, re-run the manual pilot.

### Task 4.3: Cutover

**Files:**
- Modify: `.github/workflows/deploy.yml` in `docker-piwine-office`
- Delete: `.github/workflows/deploy-local.yml` in `docker-piwine-office`

- [ ] **Step 1: Repoint `deploy.yml` at the new reusable workflow**

In `deploy.yml`, change the `uses:` from `owine/compose-workflow/.github/workflows/deploy.yml@main` to `owine/compose-workflow/.github/workflows/deploy-local.yml@main`. Update inputs to match Task 4.1 (add `live-repo-path`, `live-dockge-path`; drop any SSH-specific inputs that no longer exist).

- [ ] **Step 2: Delete the now-redundant manual pilot caller**

```bash
git rm .github/workflows/deploy-local.yml
```

- [ ] **Step 3: Lint, commit, push**

```bash
actionlint .github/workflows/deploy.yml
yamllint --strict .github/workflows/deploy.yml
git add .github/workflows/deploy.yml
git commit -m "feat(deploy): cut docker-piwine-office over to self-hosted runner"
git push
```

- [ ] **Step 4: Verify next merge to `main` triggers a green deploy**

Wait for next Renovate PR or push. Watch end-to-end. Green = pilot live.

---

## Phase 5 — Bake-In and Rollout Decision

- [ ] **Step 1: Observe ~2 weeks of normal Renovate-driven deploys**

Track: deploy duration vs baseline (expect ~30-90s shaved); any failures and root causes; anything Tailscale/SSH was implicitly providing that's now missing.

- [ ] **Step 2: Decision**

Green: write a follow-up plan for `docker-piwine` migration. The `runs-on` strategy decision (spec section "`runs-on` strategy") MUST be made before the second migration: pick option 1 (input-interpolation, verified), option 2 (per-repo workflow), or option 3 (matrix). Without that decision, the second migration adds risk.

Red: diagnose, fix in `compose-workflow`, re-bake. Pilot is one-way — no SSH fallback.

---

## Out-of-Scope for This Plan

- Migrating `docker-piwine` and `docker-zendc` (separate plans post-bake).
- Deleting the SSH-based `deploy.yml` from `compose-workflow` (only after all three migrate; the SSH scripts go with it).
- Picking among `runs-on` strategy options 1/2/3 (deferred to second-repo migration plan).
- Runner version pinning automation (manual at install; revisit if it becomes a maintenance burden).
- Adding `tj-actions/changed-files` self-hosted compatibility verification — assumed working; if not, the workflow must fall back to a `git diff --name-only $previous_sha $target-ref` step inside the `prepare` job.
