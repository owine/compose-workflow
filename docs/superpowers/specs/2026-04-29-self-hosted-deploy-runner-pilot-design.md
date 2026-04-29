# Self-Hosted Deploy Runner Pilot — Design

**Status:** Approved (design phase)
**Date:** 2026-04-29
**Scope:** Pilot self-hosted GitHub Actions runner for `docker-piwine-office`. Lint stays on GitHub-hosted runners.

## Background

Today, the deploy reusable workflow (`compose-workflow/.github/workflows/deploy.yml`) runs on `ubuntu-24.04`, brings up Tailscale, then SSH-multiplexes commands to the deploy server. A previous attempt to move workflows wholesale onto a self-hosted runner was abandoned because `tailscale/github-action` requires sudoers rules to install its own binary into `/usr/local/bin` and run `sudo tailscale up`.

**Key insight for this design:** if the runner *is* the deploy target, Tailscale is unnecessary — there is no remote to reach. That sidesteps the original blocker entirely.

## Goals

- Eliminate Tailscale install + SSH overhead from the deploy path on `docker-piwine-office`.
- Run `docker compose` operations directly on the host, with no SSH round-trips for health checks.
- Achieve zero sudo at runtime; only one-time sudo at host setup (user creation, ownership, service install).
- Preserve all current behaviors: stack categorization (removed/existing/new), critical detection, rollback, Discord notifications, dockge handling.

## Non-Goals

- Migrating `docker-piwine` or `docker-zendc` (deferred to post-pilot rollout).
- Running lint on the self-hosted runner.
- Providing an automated SSH fallback. If the runner host is down, deploys pause until it returns; manual `docker compose` on the box is the only escape hatch.
- Ephemeral or autoscaled runners (single persistent runner per host).

## Architecture

```
┌─────────────────────────────┐         ┌──────────────────────────────────────┐
│ GitHub-hosted (ubuntu-24.04)│         │ docker-piwine-office host (self-hosted)│
│                             │         │                                       │
│ • compose-lint.yml          │         │ • runner systemd service              │
│ • workflow-lint.yml         │  ─────▶ │ • runs as `deploy` user (docker grp)  │
│ • PR checks                 │         │ • workspace: ~/actions-runner/_work   │
│                             │         │ • deploy-local.yml executes here:     │
│                             │         │   - read /opt/compose HEAD            │
│                             │         │   - change detection in _work/        │
│                             │         │   - git reset --hard /opt/compose     │
│                             │         │   - docker compose pull/up/down       │
│                             │         │   - health check via local docker     │
│                             │         │   - Discord notify (curl)             │
└─────────────────────────────┘         └──────────────────────────────────────┘
```

**New file:** `compose-workflow/.github/workflows/deploy-local.yml` — reusable workflow with `runs-on: [self-hosted, piwine-office]`.

**Modified file:** `docker-piwine-office/.github/workflows/deploy.yml` — caller invokes `deploy-local.yml` instead of `deploy.yml`.

**Unchanged:**
- `compose-lint.yml`, `workflow-lint.yml` (still on `ubuntu-24.04`).
- `deploy.yml` (existing SSH workflow) — kept during pilot for `docker-piwine` and `docker-zendc`. Deleted only after all three repos migrate.
- 1Password integration via `OP_SERVICE_ACCOUNT_TOKEN`.

**Runner labels:** `self-hosted, Linux, ARM64, piwine-office`. The first three are auto-assigned by GitHub at registration; only `piwine-office` is specified explicitly. This per-repo label keeps each future runner independently targetable.

## Host Setup (One-Time)

Performed by a human admin with sudo. After completion, no runtime sudo is required.

```bash
# 1. Create dedicated user and grant docker access
sudo useradd -m -s /bin/bash deploy
sudo usermod -aG docker deploy
# Verify: as deploy, `docker ps` works without sudo

# 2. Hand over compose paths to the deploy user
sudo chown -R deploy:deploy /opt/compose /opt/dockge

# 3. Install runner (as deploy user)
# Registration token from: github.com/owine/docker-piwine-office → Settings → Actions → Runners
mkdir -p ~/actions-runner && cd ~/actions-runner
# (download + extract latest runner from GitHub releases)
./config.sh --url https://github.com/owine/docker-piwine-office \
            --token <REGISTRATION_TOKEN> \
            --labels piwine-office \
            --unattended

# 4. Install as systemd service running as deploy user
sudo ./svc.sh install deploy
sudo ./svc.sh start
```

The `svc.sh install deploy` argument makes the systemd unit run as the `deploy` user — this is the only sudo-touched step at install time, and there is no runtime sudo afterward.

## Workflow: `deploy-local.yml`

### Inputs

| Input | Type | Notes |
|---|---|---|
| `runner-label` | string | e.g. `piwine-office`. Plumbed into `runs-on`. |
| `live-repo-path` | string | e.g. `/opt/compose`. The persistent working tree. |
| `repo-name` | string | For Discord messages. |
| `webhook-url` | string | 1Password reference. |
| `discord-user-id` | string | 1Password reference. |
| `target-ref` | string | Commit SHA to deploy. |
| `has-dockge` | boolean | Same semantics as existing `deploy.yml`. |
| `force-deploy` | boolean | Same semantics as existing `deploy.yml`. |
| (timeout inputs) | numbers | Same as existing `deploy.yml`. |

### Step Ordering

The invariant: **`/opt/compose` HEAD must remain at the previous SHA when change detection runs.** All updates to the live tree happen *after* detection.

#### Phase 1 — Read state, do not mutate `/opt/compose`

1. **`actions/checkout`** into `_work/` with `fetch-depth: 0` and `ref: target-ref`. Used for change-detection metadata; not the deploy target.
2. **Load 1Password secrets** via `1password/load-secrets-action`.
3. **Capture `previous_sha`** from the live tree:
   ```bash
   CURRENT_SHA=$(git -C /opt/compose rev-parse HEAD)
   # Validate 40-hex; fall back to HEAD^ if invalid
   ```
   No SSH retry needed — this is a local filesystem read.
4. **`tj-actions/changed-files`** in `_work/`, `base_sha=previous_sha`, `sha=target-ref`.
5. **`detect-stack-changes.sh`** in `_work/`, consuming `previous_sha`, `target-ref`, and the changed-files JSON. Outputs `removed_stacks`, `existing_stacks`, `new_stacks`.
6. **`detect-critical-stacks.sh`** in `_work/` — scans `compose.yaml` labels.

#### Phase 2 — Mutate `/opt/compose`, deploy

7. **Stop removed stacks** using the *pre-reset* tree (the only place those stacks' compose files still exist):
   ```bash
   for stack in $removed_stacks; do
     docker compose -f /opt/compose/$stack/compose.yaml down
   done
   ```
   This is a deviation from current `deploy.yml`, which does the SSH'd `git checkout` first. On self-hosted there is only one working tree, so teardown must precede the reset.
8. **Update live tree** — *the point of no return for change detection:*
   ```bash
   git -C /opt/compose fetch
   git -C /opt/compose reset --hard $TARGET_REF
   ```
9. **Discord notify (removed)** — can run any time after step 5; placed here to batch.
10. **`deploy-stacks.sh` (existing stacks)** — uses `/opt/compose` paths now on the new SHA. `--has-dockge` causes dockge deploy from `/opt/dockge` after git is current (existing behavior preserved).
11. **`deploy-stacks.sh` (new stacks)** — only if existing succeeded.

#### Phase 3 — Verify and branch

12. **`health-check.sh`**.
13. **On failure:** `cleanup-stack.sh` for failed new stacks, then `rollback-stacks.sh` (`git reset --hard $previous_sha` on `/opt/compose` and redeploy).
14. **Discord notify** — success or failure with metrics.

### Three ordering points to call out explicitly

1. **Step 3 must precede step 8.** `previous_sha` is read from `/opt/compose` HEAD; once step 8 hard-resets, that reading is gone.
2. **Step 7 must precede step 8.** Removed stacks need their old `compose.yaml` to do `docker compose down` cleanly. After the hard reset those files are gone.
3. **Steps 4–6 do not touch `/opt/compose`.** They run inside the runner's `_work/` checkout, which is at the new SHA. Pure metadata work.

## Reuse vs. Duplication

What stays identical to current `deploy.yml` (so the pilot is apples-to-apples):
- `detect-stack-changes.sh`, `detect-critical-stacks.sh`, `deploy-stacks.sh`, `health-check.sh`, `rollback-stacks.sh`, `cleanup-stack.sh` — all reused unmodified.
- Stack categorization (removed/existing/new), critical detection, sequential deployment.
- Discord message format.

What gets deleted in the local path:
- Tailscale install + cache.
- SSH multiplexing setup, `ssh-helpers.sh` retry calls (commands run locally; failures are immediately visible).
- `SSH_USER` / `SSH_HOST` references (secrets stay in repo settings — used by other repos still on `deploy.yml`).

What gets *better* on self-hosted:
- ~30–60s saved per run on Tailscale install.
- Health checks run locally — no SSH round-trip per `docker compose ps` call.

## Failure Modes

| Risk | Mitigation |
|---|---|
| Runner host down | Deploys pause until host is restored. Manual `docker compose` remains available to the human admin. No automated fallback. |
| Runner workspace fills disk | `_work/` reused across jobs; checkout is small. Re-evaluate if observed; not blocking pilot. |
| `git reset --hard` blows away local edits in `/opt/compose` | Same behavior as current `deploy-stacks.sh`. No change. |
| Concurrent runs racing on `/opt/compose` | `concurrency: { group: deploy-piwine-office, cancel-in-progress: false }` on the caller workflow. |
| `safe.directory` git error after chown | Resolved by `chown -R deploy:deploy /opt/compose /opt/dockge` at setup. |
| Pilot fails midway | Phase 3 rollback restores `previous_sha` and redeploys. If rollback fails, human admin intervenes on the box directly. |

## Rollout Plan

1. **Pilot:** `docker-piwine-office` only. Caller's `deploy.yml` switches to invoke `deploy-local.yml`. The reusable `deploy.yml` (SSH-based) is unchanged and continues to serve `docker-piwine` and `docker-zendc`.
2. **Bake-in:** ~2 weeks of normal Renovate-driven deploys. Watch for anything Tailscale/SSH was implicitly providing that has been lost.
3. **If green — roll forward:**
   - Register a runner on `docker-piwine`'s host with label `piwine`. Migrate caller. Confirm.
   - Register a runner on `docker-zendc`'s host with label `zendc`. Migrate caller. This is the first exercise of `has-dockge: false` through `deploy-local.yml`.
   - After all three migrated and stable, delete `deploy.yml` (the SSH version) from `compose-workflow`.
4. **If red:** diagnose and fix the runner setup. The pilot is one-way; there is no SSH fallback.

## Open Items for Implementation Plan

- Exact runner version pinning strategy (release URL vs. configuration management).
- Decision on whether `live-repo-path` should be a workflow input or hardcoded per caller (likely input, defaulted in caller workflow).
- Whether to keep the `runner` input on the existing `deploy.yml` reusable workflow once it is no longer the only workflow that needs it.
- Concurrency group naming convention if runners ever serve more than one repo.
