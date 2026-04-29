# Self-Hosted Runner Migration Runbook

Operational reference for migrating a docker-compose repo from the SSH-based `deploy.yml` to the workflow-native `deploy-local.yml`. Distilled from the `docker-piwine-office` pilot (2026-04-29). Read this *before* starting host setup on the next host.

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

### Path ownership

```bash
sudo chown -R deploy:deploy /opt/compose /opt/dockge   # zendc has no /opt/dockge
sudo chmod -R g+rwX /opt/compose /opt/dockge
sudo find /opt/compose /opt/dockge -type d -exec chmod g+s {} \;   # sgid: new files inherit deploy group
sudo usermod -aG deploy <your-admin-user>   # so you can also write/git in /opt/compose
```

### Runner registration

Standard. Capture in your runbook:
- Runner version pinned (e.g. `v2.334.0`); refresh once per migration
- Label per repo (`piwine-office`, `piwine`, `zendc`) — not just `self-hosted`
- `sudo ./svc.sh install deploy` (the `deploy` arg makes systemd run *as* deploy — easy to miss)

---

## Workflow gotchas

These all bit the pilot. The `deploy-local.yml` reusable workflow handles them; if writing a new caller or modifying the reusable workflow, validate each.

### Auth boundary: workspace vs. live tree

The deploy user has **no GitHub credentials**. The runner workspace (`$GITHUB_WORKSPACE`) does, via `actions/checkout`'s `extraheader`. Two consequences:

1. **Change detection runs against `$GITHUB_WORKSPACE`, not `/opt/compose`.** `detect-stack-changes.sh` does `git fetch` internally; pointed at `/opt/compose`, that fetch fails. The runner's workspace already has full history at target_ref. Pass `--live-repo-path "$GITHUB_WORKSPACE"` to the script for *detection only*.

2. **`update-tree` cannot `git fetch` from `/opt/compose`'s origin.** Pattern: `actions/checkout` into the workspace, then `git -C /opt/compose fetch "$GITHUB_WORKSPACE" "$TARGET_REF"` — fetch from the *local path*, no network auth needed.

### Required script arguments

| Script | Required args (caller must pass) |
|---|---|
| `detect-stack-changes.sh` | `--mode local --current-sha --target-ref --live-repo-path --input-stacks --removed-files` |
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

### `actionlint.yaml` per repo

Both `compose-workflow` and the caller repo need `.github/actionlint.yaml`:
```yaml
self-hosted-runner:
  labels:
    - <runner-label>   # piwine, zendc, etc.
```
Without it, CI lint blocks PRs with "label X is unknown."

---

## Caller-side patterns that worked

### Two-stage rollout per repo

1. **Add `deploy-local.yml` to the caller** (workflow_dispatch only). Smoke-test it.
2. **Replace `deploy.yml`'s `uses:`** to point at the new reusable workflow. Delete the `deploy-local.yml` pilot file.

Don't try to replace `deploy.yml` in one shot — leaves no manual escape hatch if something breaks.

### Concurrency group convention

`group: deploy-<repo-label>` (e.g. `deploy-piwine-office`). Survives workflow renames better than `${{ github.workflow }}-${{ github.ref }}`.

### SHA pinning

Always full 40-char SHA on the `uses:` line — Renovate's GitHub Actions datasource needs it for auto-bumps.

### Inputs that don't carry over

The old SSH `deploy.yml` had `args:` and `health-check-command-timeout:` inputs. `deploy-local.yml` doesn't expose equivalents — the matrix per-stack approach handles timing differently. **Drop these inputs** from the new caller; don't thread dead values.

---

## `runs-on` strategy decision (REQUIRED before 2nd repo migration)

The reusable `deploy-local.yml` currently hardcodes `runs-on: [self-hosted, piwine-office]`. Three options for piwine and zendc:

1. **Parameterize via input:** `runs-on: [self-hosted, "${{ inputs.runner-label }}"]`. Cleanest, but GitHub Actions has had inconsistent behavior for input interpolation in `runs-on` arrays across runner versions. Verify with a smoke-test workflow on the actual runner version before relying on it.
2. **Per-repo workflow file:** `deploy-local-piwine.yml`, `deploy-local-zendc.yml`. Verbose, but unambiguous and easy to debug.
3. **Single-entry matrix wrapping the runs-on:** workaround that pushes the input through matrix expansion. Extra YAML layer.

**Recommendation:** option 2. You only have two repos left to migrate; the duplication cost is bounded, and there's no version-fragility risk.

---

## Phase 5 bake-in tracking

Things to record per migration to inform the next one:

- **Deploy duration baseline** (lint completion → deploy completion). Pilot baseline on piwine-office: ~3 min total. Compare to the SSH path's prior duration.
- **Flake rate** on stack recreation, especially compose `--wait` interactions during cascading restarts. Run 6 of the pilot hit a "No such container" race after partial-state rollbacks; once stable, deploys succeed cleanly. Watch over the first ~10 deploys.
- **Discord embed parity.** The new path's notify job dropped per-stack healthy/degraded/failed counts (the inline health-check is simpler than `health-check.sh`). If that detail matters in practice, expand the inline health-check to emit the counts. Otherwise leave it.
- **Anything Tailscale/SSH was implicitly providing** that's now missing. None observed in the pilot, but worth a check.

---

## End-state cleanup

After all three repos (`piwine-office`, `piwine`, `zendc`) have migrated and baked:

- Delete `deploy.yml` (the SSH workflow) from `compose-workflow/.github/workflows/`.
- Delete the SSH-using scripts that have no remaining callers: `deploy-stacks.sh`, `health-check.sh`, `rollback-stacks.sh`, `cleanup-stack.sh` (verify nothing else calls them first).
- `detect-stack-changes.sh` keeps both modes — local was added, ssh stays in case any other consumer emerges, but can be simplified to local-only if confirmed unused.
- Remove `tailscale/github-action` cache config and Tailscale OAuth secret refs from CI.
- Delete `SSH_USER` / `SSH_HOST` repo secrets across all three repos once nothing references them.
