# Self-Hosted Runner Migration Runbook

Operational reference for migrating a docker-compose repo from the SSH-based deploy reusable workflow to the self-hosted-runner-based replacement. All three repos have now migrated: `docker-piwine-office` (2026-04-29 pilot), `docker-piwine` (2026-04-30), `docker-zendc` (2026-05-02). The replacement workflow was originally introduced as `deploy-local.yml` and renamed to `deploy.yml` on 2026-05-03 after the SSH-based file was deleted. Keep this for future hosts and as the reference for end-state cleanup.

**Spec:** `docs/superpowers/specs/2026-04-29-self-hosted-deploy-runner-pilot-design.md`
**Original plan:** `docs/superpowers/plans/2026-04-29-self-hosted-deploy-runner-pilot.md`

---

## Pre-flight (do this once per host before starting)

### Required tools on the deploy user's PATH

The runner runs jobs as the `deploy` user. Workflow `run:` blocks need each of these on PATH:

| Tool | Why | Install on Pi OS / Debian |
|---|---|---|
| `docker` | Compose ops | usually present |
| `jq` | JSON parsing in workflow steps | `sudo apt install jq` |
| `timeout` | Bound long pulls/waits | in `coreutils`, present |
| `gh` | Commit message lookups in notify job | `sudo apt install gh` |
| `op` | 1Password CLI for env-file resolution | install per https://developer.1password.com/docs/cli/get-started |

Verify before proceeding:
```bash
sudo -u deploy bash -c 'for t in docker jq timeout gh op; do command -v $t || echo MISSING:$t; done'
```

### Phase 0 — manual smoke as deploy user

**Do this before writing any workflow code for the new host.** Catches 1Password / docker / volume issues with zero CI feedback loop:

```bash
sudo -u deploy bash -c '
  cd /opt/compose/<some-stack>
  OP_SERVICE_ACCOUNT_TOKEN="<your token>" \
    op run --no-masking --env-file=/opt/compose/compose.env -- \
    docker compose up -d --build --pull always --quiet-pull --quiet-build --wait --remove-orphans
'
```

If this fails, the workflow will too. The biggest wins from this step on piwine-office would have been catching:
- Missing `op` CLI before runner registration
- Volume permissions on tailscale state dirs
- 1Password service account token scope mismatches

### Path ownership (admin owns tree, runner gets group access)

**Standardized 2026-04-30 across both piwine-office and piwine** — earlier piwine-office instructions said to `chown -R deploy:deploy` the tree. That's been reverted. The current pattern keeps the tree owned by the human admin (`owine`) and grants the `deploy` runner user access via group membership + `safe.directory`. Symmetric with the SSH path, doesn't require a recursive ownership change of a multi-stack tree, and survives `git reset --hard` cleanly.

```bash
# Tree stays owned by the admin user
sudo chown -R owine:owine /opt/compose /opt/dockge   # zendc has no /opt/dockge

# Group-writable + setgid so files created by `deploy` inherit the owine group
sudo chmod -R g+rwX /opt/compose /opt/dockge
sudo find /opt/compose /opt/dockge -type d -exec chmod g+s {} +

# Add deploy user to the admin's group (NOT the other way around)
sudo usermod -aG owine deploy

# Tell git the runner user can operate on a tree it doesn't own
sudo -u deploy git config --global --add safe.directory /opt/compose

# CRITICAL: set umask 002 for the admin user so future files created via
# SSH (manual edits, git pull, ad-hoc commands) inherit group-write
echo 'umask 002' | tee -a ~/.zshrc ~/.bashrc
```

**Why `safe.directory` is required:** git refuses to operate on repos whose top-level dir is owned by a different uid (the "dubious ownership" error). Group membership doesn't satisfy the check — only owner uid or root does. The `safe.directory` config tells the runner user "this specific path is OK." Without this line, *every* git step in the workflow fails before the deploy can begin.

**Why `umask 002` for the admin user is required (not optional):** without it, the symmetric model silently rots. Whenever the admin user creates a new file or directory in `/opt/compose` via SSH — manual config edits, `git pull` on the host, or an SSH-path deploy elsewhere that touches this tree — the default umask 022 produces files mode 644 and dirs mode 755. Setgid on the parent dir correctly puts new files in the `owine` group, but the **mode bits don't get group-write**. The runner user then can't `git reset --hard` (unlink permission denied) and the next deploy fails with `fatal: Could not reset index file to revision …`.

This bit us on piwine 2026-04-30: an SSH-path deploy added `housemanager/` and `trips/` as new stack dirs; both got mode 755 (no group-write); the next self-hosted deploy's git reset failed on `unable to unlink old housemanager/compose.yaml: Permission denied`. One-time recursive `chmod -R g+w` repaired the residue, but **without setting umask 002 the problem recurs** the next time owine creates a new file on the host. The `deploy` user's umask is already 002 by default on Ubuntu 24.04, so self-hosted-deploy-driven file creation is fine. The fix targets the admin SSH path specifically.

**`/opt/dockge` doesn't need `safe.directory`** today (it's not a git repo — just a compose tree). Add it if that ever changes.

**Don't `chown -R deploy:deploy`** the tree — earlier guidance recommended this; it works but creates an asymmetric setup where the SSH-path admin can no longer manage files without sudo, and the chown itself is a recursive blast-radius operation across many stacks. The group + `safe.directory` + symmetric umask 002 pattern avoids both.

### Runner registration

Standard. Capture in your runbook:
- Runner version pinned (e.g. `v2.334.0`); refresh once per migration
- Label per repo (`piwine-office`, `piwine`, `zendc`) — not just `self-hosted`
- `sudo ./svc.sh install deploy` (the `deploy` arg makes systemd run *as* deploy — easy to miss)

---

## Workflow gotchas

These all bit the pilot. The `deploy.yml` reusable workflow handles them; if writing a new caller or modifying the reusable workflow, validate each.

### Auth boundary: workspace vs. live tree

The deploy user has **no GitHub credentials**. The runner workspace (`$GITHUB_WORKSPACE`) does, via `actions/checkout`'s `extraheader`. Two consequences:

1. **Change detection runs against `$GITHUB_WORKSPACE`, not `/opt/compose`.** `detect-stack-changes.sh` does `git fetch` internally; pointed at `/opt/compose`, that fetch fails. The runner's workspace already has full history at target_ref. Pass `--live-repo-path "$GITHUB_WORKSPACE"` to the script for *detection only*.

2. **`update-tree` cannot `git fetch` from `/opt/compose`'s origin.** Pattern: `actions/checkout` into the workspace, then `git -C /opt/compose fetch "$GITHUB_WORKSPACE" "$TARGET_REF"` — fetch from the *local path*, no network auth needed.

### Required script arguments

| Script | Required args (caller must pass) |
|---|---|
| `detect-stack-changes.sh` | `--current-sha --target-ref --live-repo-path --input-stacks --removed-files` |
| `detect-critical-stacks.sh` | `--stacks "<space-separated>" --repo-dir <path>` |

The plan's original prepare job omitted `--input-stacks` and the args for `detect-critical-stacks.sh`. Both surfaced as opaque "Required variable not set" errors mid-run.

### `op run` is mandatory for every docker compose call

`compose.env` contains 1Password references like `PORTAINER_TS_AUTHKEY=op://Docker/portainer/ts_authkey`. Plain `docker compose up` doesn't resolve these — containers come up with empty env vars and dependent services (Tailscale sidecars) fail to start.

Wrap **every** docker compose invocation:
```bash
op run --no-masking --env-file="$LIVE_REPO_PATH/compose.env" -- docker compose <subcommand>
```

Applies to `up`, `down`, `ps`, `logs`. Each job that wraps in `op run` needs `OP_SERVICE_ACCOUNT_TOKEN: ${{ secrets.OP_SERVICE_ACCOUNT_TOKEN }}` in its `env:` block.

### Match existing `deploy-stacks.sh` flag set

For parity with the SSH path:
```
up -d --build --pull always --quiet-pull --quiet-build --wait --remove-orphans
```
Collapse pull+up into one invocation (`--pull always` does both). `--remove-orphans` is non-optional — without it, renamed sidecars (old `<primary>_<sidecar>` → new `<primary>-<sidecar>`) leave stale containers.

### Health-status vocabulary alignment

The inline `health-check` job emits `outputs.status=healthy` / `failed` (semantic). The notify job's status-branching logic compares against `success` / `failure`. Without normalization, every successful deploy renders as a red "Failed" embed in Discord — every job runs green, but the message is wrong.

Fixed in `6b3cf2b` via a `case` statement that maps `healthy → success` and `failed → failure` at the top of the notify job's status computation. If you copy `deploy.yml` for a per-repo file (option 2 of the runs-on strategy), keep that normalization block intact. The pipeline-status icon block downstream consumes the normalized `$health_status`, so fixing once fixes both.

### One-shot containers (exit 0) must not fail the health gate

Stacks like `yas` use `service_completed_successfully` to gate workers/api on a one-shot migration container (alembic, etc.). After `up --wait` settles, that container is in state `exited` with exit code `0` — a *success*, not a failure.

The inline health-check job in `deploy.yml` accounts for this in its `unhealthy` jq selector:
```jq
[.[] | select(
  .Health == "unhealthy"
  or (.Health == "" and .State != "running" and .State != "exited")
  or (.State == "exited" and (.ExitCode // 0) != 0)
)] | length
```
Note `docker compose ps -a` (with `-a`) — without it, exited containers don't appear, which masks both the false-positive *and* the ability to spot a real one-shot failure post-hoc.

**SSH-path equivalent fixes:** `e9d37e4` (logic), `3684dd6` (parsing). The second is a sharp edge worth knowing if anyone rewrites the gate: Go-template `--format` strings like `'{{.Service}}\t{{.Health}}\t{{.ExitCode}}'` silently drop trailing fields when an intermediate field is empty (e.g. `.Health=""` for containers without a healthcheck), leaving downstream values unparseable in `bash` reads. Use `--format json | jq -r '[…] | @tsv'` instead — JSON enforces a fixed schema. The `deploy.yml` inline gate already operates on parsed JSON via `jq`, so it's not vulnerable today, but don't "simplify" it to Go templates.

### Private container registries need a `registry-login` job

Most private registries (GHCR, Docker Hub PRs, GitLab Container Registry, etc.) require cached creds in the runner host's `~/.docker/config.json` for `docker compose pull` to succeed. New self-hosted hosts won't have those creds on first deploy. GHCR is the most common gotcha — packages stay private even when their source repo is public.

The fix is a dedicated `registry-login` job that runs after `update-tree` and before any deploy job. Two-step pattern:

1. **One** `1password/load-secrets-action` step that pulls **all** username/token pairs in a single round trip (one map of `KEY: op://...` references in the step's `env:`).
2. **One `docker/login-action` step per registry**, each `continue-on-error: true` and `logout: false`, consuming `${{ steps.creds.outputs.* }}`.

```yaml
registry-login:
  needs: [prepare, update-tree]
  steps:
    - uses: 1password/load-secrets-action/configure@<sha>
      with: { service-account-token: ${{ secrets.OP_SERVICE_ACCOUNT_TOKEN }} }
    - id: creds
      uses: 1password/load-secrets-action@<sha>
      with: { unset-previous: true }
      env:
        GHCR_USERNAME: op://Docker/ghcr-pat/username
        GHCR_TOKEN:    op://Docker/ghcr-pat/pat
        DOCKERHUB_USERNAME: op://Docker/docker-hub/username
        DOCKERHUB_TOKEN:    op://Docker/docker-hub/token
        # ... (one pair per registry)
    - uses: docker/login-action@<sha>
      continue-on-error: true
      with:
        registry: ghcr.io
        username: ${{ steps.creds.outputs.GHCR_USERNAME }}
        password: ${{ steps.creds.outputs.GHCR_TOKEN }}
        logout: false
    # ... (one step per registry; omit `registry:` for Docker Hub)
```

**Why these tools, not alternatives:**
- `1password/load-secrets-action` (not `op read` / `op run` inline) — masks values in logs, exposes both env and step outputs, pairs with `unset-previous: true` for explicit cleanup. Matches the existing notify-job pattern. Reserve `op` CLI for the bulk `compose.env` resolution at deploy time, where it's the right tool.
- `docker/login-action` (not inline `echo … | docker login --password-stdin`) — handles password stdin piping correctly, masks credentials, and is the canonical action.
- **One** load step for **all** registries — minimizes round trips to 1Password and keeps the credential map in one place. Don't fragment into per-registry load steps.

**Failure mode:** load step is **fatal** (a missing 1P item should fail loud, not silently skip a registry); per-registry login is **non-fatal** via `continue-on-error: true` (a single misconfigured registry shouldn't block deploys that may not pull from it; cached creds from a prior run may still work). `logout: false` is critical — without it, the action wipes `~/.docker/config.json` at job end and the next job has no creds.

The login persists in `~/.docker/config.json` on the runner host, so a single job suffices — `deploy-dockge`, `deploy-existing`, `deploy-new`, and `rollback` all inherit the cached creds. Add `registry-login` to each deploy job's `needs:` and gate each `if:` on `needs.registry-login.result == 'success'`. **Also add it to `notify.needs`** and check `REGISTRY_LOGIN_RESULT == 'failure'` in the deploy_status block — otherwise a login failure cascades into `skipped` deploys, which the status logic mistakes for success.

PATs only need read/pull scope on each registry. Store each as a 1Password API Credential item (matching existing `docker-hub` shape: `username` + `token` fields, with `hostname` for human reference).

**SSH-path equivalent:** `71877b8` (GHCR only, via `op read` inline in `deploy-stacks.sh`/`rollback-stacks.sh`; the self-hosted version is broader because it covers all four registries the runner pulls from).

### Replacing the runner user (rename or reset)

If you misname the runner user during initial setup (e.g. created `gh-runner` then realized the convention is `deploy`), **don't try to `usermod -l`** — too many side-effects (home-dir name, group name, systemd unit user). Tear down and recreate:

```bash
# 1. Get a removal token (single-use)
REMOVAL_TOKEN=$(gh api -X POST repos/owine/<repo>/actions/runners/remove-token --jq .token)

# 2. Stop and uninstall the systemd service (as your sudo user)
sudo bash -c 'cd /home/<old-user>/actions-runner && ./svc.sh stop && ./svc.sh uninstall'

# 3. Deregister from GitHub (run as the old runner user, with the token)
sudo -iu <old-user> bash -c "cd ~/actions-runner && ./config.sh remove --token \"$REMOVAL_TOKEN\""

# 4. Delete the user — beware orphan processes
sudo userdel -r <old-user>
```

**Gotcha: orphan `op daemon` processes.** The runner spawns long-running `op` daemons during deploys. They can outlive the systemd service shutdown and hold the user open, causing `userdel` to fail with "user is currently used by process N." If `userdel` complains:

```bash
sudo kill <pid>     # or pkill -u <old-user>
sleep 2
sudo userdel -r <old-user>
```

Then create the new user, re-download the runner package (don't try to reuse the old install dir under the old home), and re-run `config.sh` with a fresh registration token. The new install gets a new uid; that's fine — uids are host-local, no need to match across hosts.

Both `compose-workflow` and the caller repo need `.github/actionlint.yaml`:
```yaml
self-hosted-runner:
  labels:
    - <runner-label>   # piwine, zendc, etc.
```
Without it, CI lint blocks PRs with "label X is unknown."

---

## Caller-side patterns that worked

### Two-stage rollout per repo (historical, used during the SSH→self-hosted migration)

1. **Add a `deploy-self-hosted.yml` to the caller** (workflow_dispatch only) calling the new reusable workflow. Smoke-test it.
2. **Replace the existing SSH-based `deploy.yml`'s `uses:`** to point at the new reusable workflow. Delete the pilot file.

Don't try to replace the SSH-based `deploy.yml` in one shot — leaves no manual escape hatch if something breaks. (For future *new* hosts, this two-stage isn't needed: just write the caller `deploy.yml` to point at the reusable workflow directly.)

### Concurrency group convention

`group: deploy-<repo-label>` (e.g. `deploy-piwine-office`). Survives workflow renames better than `${{ github.workflow }}-${{ github.ref }}`.

### SHA pinning

Always full 40-char SHA on the `uses:` line — Renovate's GitHub Actions datasource needs it for auto-bumps.

### Inputs that don't carry over

The old SSH-based reusable workflow had `args:` and `health-check-command-timeout:` inputs. The current `deploy.yml` doesn't expose equivalents — the per-stack loop handles timing differently. **Drop these inputs** from the caller; don't thread dead values.

---

## `runs-on` strategy — RESOLVED (2026-04-30)

We chose **option 1: parameterize via input.** Verified working on actions/runner v2.334.0 against piwine and piwine-office in the same workflow file. List-element interpolation `runs-on: [self-hosted, "${{ inputs.runner-label }}"]` is reliable on modern runners — the prior runbook's caution about version fragility no longer applies.

**Implementation pattern:**

```yaml
# In deploy.yml (the reusable workflow)
on:
  workflow_call:
    inputs:
      runner-label:
        description: "Custom self-hosted runner label (e.g. piwine, piwine-office)."
        required: true
        type: string

jobs:
  prepare:
    runs-on: [self-hosted, "${{ inputs.runner-label }}"]
    # ...
```

Each caller passes its own label:

```yaml
# In docker-piwine/.github/workflows/deploy-self-hosted.yml
with:
  runner-label: piwine
```

**Breaking-change handling when adding a required input:** callers pinned to the pre-input SHA fail with "invalid input: runner-label" on the next deploy. Bump every caller's SHA pin in the same push session, manually — Renovate eventually does this but with a window of broken deploys in between. Procedure: push the reusable-workflow change, get the new SHA, edit each caller's `uses:` line in the same minute, push.

**actionlint.yaml in the reusable-workflow's repo** must list **every** label any caller passes — otherwise `actionlint` blocks PRs to compose-workflow with "label X is unknown" once a new caller starts using a new label. Edit `compose-workflow/.github/actionlint.yaml` whenever a new host comes online:

```yaml
self-hosted-runner:
  labels:
    - piwine
    - piwine-office
    - zendc
```

---

## Phase 5 bake-in tracking

Things to record per migration to inform the next one:

- **Deploy duration baseline** (lint completion → deploy completion). Pilot baseline on piwine-office: ~3 min total. Compare to the SSH path's prior duration.
- **Flake rate** on stack recreation, especially compose `--wait` interactions during cascading restarts. Run 6 of the pilot hit a "No such container" race after partial-state rollbacks; once stable, deploys succeed cleanly. Watch over the first ~10 deploys.
- **Discord embed parity.** The new path's notify job dropped per-stack healthy/degraded/failed counts (the inline health-check is simpler than `health-check.sh`). If that detail matters in practice, expand the inline health-check to emit the counts. Otherwise leave it.
- **Anything Tailscale/SSH was implicitly providing** that's now missing. None observed in the pilot, but worth a check.

### zendc migration notes (2026-05-02)

- Host was already on Ubuntu 22.04 with `seed` as admin user. All 5 required tools (`docker jq timeout gh op`) were already on PATH; no installs needed.
- `/opt/compose` was already `seed:seed` so the `chown` step was a no-op — the `chmod -R g+rwX` + setgid + `safe.directory` + umask 002 still all required. Pattern was completely idempotent.
- All `${APPDATA_PATH}` bind mounts resolve to a path *outside* `/opt/compose` (1P-resolved), so the chmod recursion had zero blast radius into container data. Verify this before chmod on any new host: `grep '^\s*-' /opt/compose/*/compose.yaml | grep -v APPDATA_PATH` should only return system paths (`/etc/passwd`, `/mnt`, `/dev`, `/var/log`).
- Pre-existing `hetzner-vm` runner on the same GitHub repo did **not** interfere — it lacks the `zendc` label, and `runs-on: [self-hosted, zendc]` is intersection-matched. No action needed.
- Cutover hit a Renovate race twice in two minutes: Renovate bumped the SHA pin on `deploy.yml` (the *old* file) while we were trying to push the cutover (which switches `uses:` from `deploy.yml` to `deploy-local.yml`). Resolution was trivial — keep our `deploy-local.yml` line, take Renovate's bumped SHA. Lesson: bump the pin to *current* compose-workflow main when you cut over, not to the SHA you started from, to avoid one extra rebase.
- Both queued deploys (Renovate's bump + the cutover) ran cleanly on the new self-hosted runner because `workflow_run` reads the caller workflow file from default-branch HEAD at dispatch time, not at the head_sha. So even the deploy that "belonged to" the Renovate commit ran on the self-hosted path.

### Resolved issues

- **`housemanager` / `trips` deploy failures (piwine, 2026-04-30).** Initially looked like ghcr.io pull timeouts during `deploy-new`. The actual root cause was a permission issue: the SSH-path deploy that introduced these two stacks was running as `owine` with default umask 022, producing dirs mode 755 / files mode 644 — no group-write. The self-hosted deploy's `git reset --hard` then failed to unlink those files (the `deploy` user is in `owine` group but the bit wasn't set), surfacing as opaque "stack failed" symptoms in the deploy phase rather than the actual git error in update-tree (because the failure point was in a different step). Fixed by (a) one-time `chmod -R g+w /opt/compose` to repair residue, and (b) `umask 002` in `owine`'s shell rcs so future SSH-driven changes don't recreate the state. See path-ownership section above.

### Job consolidation (DONE 2026-04-30, commit `df6b173`)

The original structure was inherited from the GitHub-hosted SSH `deploy.yml` where matrix entries fan out to ephemeral runners in parallel. On a single self-hosted runner with concurrency=1, **matrix entries serialize** — no parallelism benefit, only per-job cold-start cost (env setup, secrets injection, dispatch handshake) multiplied by N stacks. The full piwine deploy was hitting 11 `deploy-existing` matrix entries running one-at-a-time = 11 sequential cold-starts.

**Final structure: 5 jobs** (down from 11 logical / 17 runtime jobs):

1. `prepare` — discover stacks, capture previous SHA, classify removed/existing/new.
2. `deploy` — **merged**. Steps: skip-gate → teardown-removed → tree update → 1P configure → load creds → 4× registry login → dockge → existing-stack loop → new-stack loop → cleanup-on-failure → summary outputs.
3. `health-check` — separate (distinct timeout profile, clean gate for rollback condition).
4. `rollback` — separate (must be reachable from *either* `deploy.result == 'failure'` or `health-check.result == 'failure'`; step-level `if: failure()` only sees prior steps in the same job).
5. `notify` — separate (`if: always()`, final aggregator).

**Key implementation details:**

- **Per-stack timeout** is enforced with `timeout $SERVICE_STARTUP_TIMEOUT` inside the loop, not step-level `timeout-minutes:`. Step-level would apply to the *whole loop*; the bash `timeout` command preserves the prior matrix's per-entry budget.
- **Per-stack failure isolation** uses `set +e` + a `failed=()` array; the loop step exits non-zero only at the end if any stack failed. Matches the prior matrix's `fail-fast: false` semantics.
- **Failed-stack lists** are surfaced as step outputs (`failed_stacks`) and appended to `$GITHUB_STEP_SUMMARY` for at-a-glance visibility — replaces the per-matrix-entry pass/fail in the GitHub UI's job list. The trade-off (no per-stack rows in the jobs panel) was deemed acceptable given the cold-start savings.
- **`deploy.outputs.deployed_anything`** replaces the prior cross-job condition `(deploy-existing.result == 'success' || deploy-new.result == 'success')` that gated `health-check`. Computed in the `summary` step from per-loop `succeeded` counters.
- **`deploy.outputs.skipped`** replaces `update-tree.outputs.skipped`. The notify job consumes it for the `deployment_needed` check.
- **Notify `deploy_status` simplification**: previously OR'd six job results (`UPDATE_TREE_RESULT`, `TEARDOWN_RESULT`, `REGISTRY_LOGIN_RESULT`, `DEPLOY_DOCKGE_RESULT`, `DEPLOY_EXISTING_RESULT`, `DEPLOY_NEW_RESULT`) — now just checks `DEPLOY_RESULT`. The `healthy/failed → success/failure` case statement is preserved verbatim.
- **`logout: false`** on every `docker/login-action` step (still required) — without it, the action wipes `~/.docker/config.json` at job-end and downstream `docker compose pull` fails.

**Validation:** pilot smoke-test on docker-piwine via `workflow_run` chain (lint → deploy) confirmed 5 jobs, correct step ordering, correct rollback fire on partial-deploy failure, correct skip-gate, correct Discord notification status. Pre-existing housemanager/trips stack issue surfaced identically to before — not a regression.

**Caller update procedure** (when bumping to a SHA that includes the refactor): no input changes, but bump the consumer SHA pin in the same push session that picks up the refactor commit. Renovate will follow but with a window of mismatch where neither `runner-label` nor the new outputs structure has stabilized.

---

## End-state cleanup (DONE 2026-05-03)

All three repos migrated and baked. Cleanup completed in a single push session:

- ✅ **Deleted** `compose-workflow/.github/workflows/deploy.yml` (the SSH-based reusable workflow). Verified zero callers across all three docker repos before removal.
- ✅ **Deleted** the SSH-using scripts: `deploy-stacks.sh`, `health-check.sh`, `rollback-stacks.sh`, `cleanup-stack.sh`. Plus `lib/ssh-helpers.sh` which was only sourced by these scripts and the SSH branch of `detect-stack-changes.sh`.
- ✅ **Simplified** `detect-stack-changes.sh` to local-only. Removed `--mode ssh` branch, `--ssh-user`/`--ssh-host` flags, `run_remote()` SSH dispatch, and the in-script cleanup-of-removed-stacks loop (that responsibility moved to deploy-local.yml's `Teardown removed stacks` step before this cleanup, so it was already redundant). Caller in `deploy-local.yml` updated to drop the now-rejected `--mode local` flag.
- ✅ **Tailscale references** were removed from CI long before this cleanup (the rewrite to self-hosted runners eliminated Tailscale dependency entirely). Verified no remaining `tailscale/github-action` references in workflows or active docs. Historical mentions in this runbook are intentional context and stay.
- ✅ **CLAUDE.md and README.md** rewritten to describe the deploy-local.yml-only architecture. Old SSH-multiplexing/Tailscale/SSH_USER+SSH_HOST narrative replaced with self-hosted-runner reality.

### Manual follow-up (DONE 2026-05-03)

- ✅ `gh secret delete SSH_USER --repo owine/docker-piwine`
- ✅ `gh secret delete SSH_HOST --repo owine/docker-piwine`
- ✅ `gh secret delete SSH_USER --repo owine/docker-piwine-office`
- ✅ `gh secret delete SSH_HOST --repo owine/docker-piwine-office`
- ✅ `gh secret delete SSH_USER --repo owine/docker-zendc`
- ✅ `gh secret delete SSH_HOST --repo owine/docker-zendc`

Each docker repo now has exactly one secret: `OP_SERVICE_ACCOUNT_TOKEN`.
