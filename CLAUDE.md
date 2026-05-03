# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Centralized Docker Compose Workflow Management

This repository contains **reusable GitHub Actions workflows** that provide centralized CI/CD automation for Docker Compose environments. The goal is to eliminate code duplication while maintaining environment-specific configurations.

### Repository Purpose

**compose-workflow** serves as a centralized workflow hub providing reusable CI/CD workflows for Docker Compose deployments across multiple repositories. As of 2026-05-02, all three caller repos (`docker-piwine`, `docker-piwine-office`, `docker-zendc`) deploy via **self-hosted GitHub Actions runners** that live on the deployment hosts themselves — there is no longer any SSH-from-CI deploy path.

### Workflow Architecture

Three reusable workflows live in `.github/workflows/`:

#### 1. Compose Lint Workflow (`compose-lint.yml`)
- **Purpose**: Validates Docker Compose files and detects secrets
- **Features**:
  - GitGuardian scanning for secret detection (push events only)
  - YAML linting with yamllint
  - Docker Compose validation
  - Parallel execution of all validation tasks
  - Discord notifications with detailed status
- **Runs on**: GitHub-hosted Ubuntu runners (no host access required for lint)
- **Key inputs**:
  - `stacks` — JSON array of stack names to lint
  - `webhook-url` — 1Password reference to Discord webhook
  - `repo-name` — Repository name for notifications
  - `target-repository`, `target-ref` — Checkout coordinates
  - `discord-user-id` — 1Password reference to Discord user ID for failure mentions

#### 2. Deploy Workflow (`deploy-local.yml`)
- **Purpose**: Deploys to caller repo's host via a self-hosted runner that lives on the host itself
- **Runs on**: `[self-hosted, <runner-label>]` (e.g. `[self-hosted, piwine]`)
- **5 jobs** (consolidated 2026-04-30 from a prior 11-job structure — single-runner concurrency=1 means matrices serialize anyway):
  1. **`prepare`** — discover stacks, capture previous SHA, classify removed/existing/new, detect critical stacks
  2. **`deploy`** — skip-gate, teardown removed, update tree from workspace (no `git fetch` from origin needed; runner has no GitHub creds), 1P configure, multi-registry login (ghcr/dockerhub/gitlab/gitlab-zenterprise), dockge (optional), existing stacks, new stacks, cleanup-on-failure, summary outputs
  3. **`health-check`** — validate critical stacks via inline `docker compose ps -a` parsing (no separate script). Skips one-shot exit-0 containers (e.g. migration sidecars gated via `service_completed_successfully`)
  4. **`rollback`** — `git reset --hard <previous_sha>` + redeploy if `deploy` or `health-check` failed
  5. **`notify`** — Discord webhook with status, pipeline icon line, and PR comment posting (when invoked from a PR-triggering chain)
- **Key inputs**:
  - `runner-label` — e.g. `piwine`, `piwine-office`, `zendc`. Combined with implicit `self-hosted`
  - `live-repo-path` — absolute path on the runner host (typically `/opt/compose`)
  - `live-dockge-path` — absolute path to dockge tree (when `has-dockge: true`)
  - `repo-name`, `webhook-url`, `discord-user-id`, `target-ref`
  - `has-dockge` — boolean (`true` for piwine/piwine-office, `false` for zendc)
  - `force-deploy` — skip the "already at target SHA" gate
  - `auto-detect-critical` — read `com.compose.tier: infrastructure` labels (default: true)
  - `critical-services` — manual JSON array (when auto-detect is false)
  - `image-pull-timeout`, `service-startup-timeout` — bound long pulls/waits
  - `failed-container-log-lines` — diagnostic log tail size on failure (default: 50)

#### 3. Workflow Lint (`workflow-lint.yml`)
- **Purpose**: yamllint + actionlint for the workflow files themselves

### Why this design

A prior attempt (~2026-04-27) used `tailscale/github-action` to dial *into* hosts from GitHub-hosted runners and SSH from there. Sudo friction with the Tailscale action and SSH-key juggling led to the rewrite: put the runner *on* the host as a `deploy` user (member of `docker` and the admin's group, via `safe.directory` for the admin-owned `/opt/compose` tree). Eliminates the entire SSH-key/Tailscale/sudo-rule class of issues, and removes all network round trips during a deploy except registry pulls and 1P calls.

## Workflow Configuration

### Required Secrets

Calling repositories need exactly **one** secret:

- `OP_SERVICE_ACCOUNT_TOKEN` — 1Password service account token. Used by both `compose-lint.yml` (for GitGuardian's API key) and `deploy-local.yml` (for `op run` env-file resolution + multi-registry credentials + Discord webhook).

The previously-required `SSH_USER` / `SSH_HOST` secrets are no longer used and can be deleted from caller repos.

### Repository Structure Requirements

Calling repos must have:

```
├── .yamllint                     # yamllint configuration
├── compose.env                   # env file with op:// references
├── .github/
│   ├── actionlint.yaml           # declares the runner-label (`piwine`, etc.)
│   └── workflows/
│       ├── lint.yml              # calls compose-lint.yml
│       └── deploy.yml            # calls deploy-local.yml
├── stack1/
│   └── compose.yaml
├── stack2/
│   └── compose.yaml
└── ...
```

`actionlint.yaml` is mandatory — without it, CI lint blocks PRs with "label X is unknown" once a workflow uses `runs-on: [self-hosted, <label>]`:

```yaml
self-hosted-runner:
  labels:
    - <runner-label>
```

### Self-hosted runner host requirements

For `deploy-local.yml` to function, the host must have:

| Tool | Why |
|---|---|
| `docker` | Compose ops |
| `jq` | JSON parsing in workflow steps |
| `timeout` (coreutils) | Bound long pulls/waits |
| `gh` | Commit message lookups in notify job |
| `op` (1Password CLI) | env-file resolution at deploy time |

Plus a `deploy` user running the GitHub Actions runner as a systemd service, in the `docker` group and the admin's group, with `safe.directory` configured for the live tree. See `docs/superpowers/runbooks/self-hosted-runner-migration.md` for the full host-prep playbook (path ownership pattern, setgid, `umask 002` for both admin and runner users).

### Healthcheck Requirements for --wait Flag

`deploy-local.yml` invokes `docker compose up --wait`, which only verifies services that have healthchecks defined. Services without healthchecks will start but won't gate the deploy. Patterns:

```yaml
# HTTP/Web Services
healthcheck:
  test: ["CMD-SHELL", "curl -f http://localhost:PORT || exit 1"]
  interval: 30s
  timeout: 10s
  start_period: 60s
  retries: 3

# Database (PostgreSQL)
healthcheck:
  test: ["CMD-SHELL", "pg_isready -U ${DB_USER}"]
  interval: 5s
  timeout: 5s
  retries: 5
```

### One-shot containers must exit 0

Services gated via `service_completed_successfully` (alembic migrations, db seeds, etc.) end up in state `exited` after `up --wait` settles. The health-check job's jq selector treats `exited + ExitCode=0` as success, not failure — so one-shot completion gates do not trip the rollback path. If you add a one-shot, ensure it can actually exit zero in the happy case.

### Discord Webhook Configuration

Webhook URLs are stored in 1Password and referenced at workflow-call time:

```yaml
webhook-url: "op://Docker/discord-github-notifications/<env>_webhook_url"
```

The notify job uses `1password/load-secrets-action` to resolve the reference, sends via `sarisia/actions-status-discord`, and unloads at the end.

### Critical Stack Auto-Detection

The deploy workflow auto-detects critical stacks by scanning each stack's `compose.yaml` for labels on any service:

```yaml
services:
  traefik:
    labels:
      com.compose.tier: infrastructure   # marks the *stack* as critical
      # OR
      com.compose.critical: true
```

The `prepare` job's `detect-critical-stacks.sh` builds a JSON array of stacks containing such labels; `health-check` uses it to decide which stacks gate the rollback. To override:

```yaml
with:
  auto-detect-critical: false
  critical-services: '["stack1", "stack2"]'
```

Examples of stacks typically marked critical:
- **Reverse proxies** (`swag`, `traefik`) — all external access depends on them
- **Container management** (`portainer`, `dockge`) — needed for manual intervention if other stacks fail
- **Authentication** (`authelia`) — SSO gateway
- **Monitoring** (`dozzle`, `beszel`, `uptime-kuma`) — operational visibility

## Modular Scripts

### `scripts/linting/`

Used by `compose-lint.yml`:

- **`lib/env-helpers.sh`** — `create_temp_env()` generates temporary .env files with placeholders, eliminating env warnings during compose validation
- **`lib/common.sh`** — colored logging, `validate_stack_name`, GitHub Actions output helpers
- **`validate-stack.sh`** — parallel YAML lint + `docker compose config` per stack
- **`lint-summary.sh`** — aggregates GitGuardian, actionlint, and stack-validation results into a final status report

### `scripts/deployment/`

Used by `deploy-local.yml`. The deploy/health/rollback logic is **inlined as workflow steps**, so this directory is small:

- **`lib/common.sh`** — colored logging, `validate_stack_name` / `validate_sha` / `validate_op_reference`, GitHub Actions output helpers
- **`detect-stack-changes.sh`** — three-method detection (git diff, tree comparison, discovery analysis) for removed/existing/new stacks. Runs locally on the runner against the workspace checkout (which has full history + GitHub creds), then the workflow uses the classifications to drive teardown / sequential deploy. Cleanup of removed stacks happens in the workflow's `Teardown removed stacks` step, not in this script.
- **`detect-critical-stacks.sh`** — scans for `com.compose.tier: infrastructure` labels, emits JSON array
- **`build-pr-comment.sh`** — builds the deploy-status PR comment body (used by the notify job's PR-comment step)

The previously-existing `deploy-stacks.sh`, `health-check.sh`, `rollback-stacks.sh`, `cleanup-stack.sh`, and `lib/ssh-helpers.sh` were removed when `deploy-local.yml` replaced the SSH-based `deploy.yml` — their logic now lives directly in the workflow file.

## Development Commands

```bash
# Lint workflow files
actionlint .github/workflows/compose-lint.yml \
           .github/workflows/deploy-local.yml \
           .github/workflows/workflow-lint.yml
yamllint --strict .github/workflows/*.yml

# Lint deployment scripts
shellcheck scripts/deployment/*.sh scripts/linting/*.sh

# Test workflows locally
./scripts/testing/test-workflow.sh
./scripts/testing/validate-compose.sh
```

### Validating compose files in a caller repo

```bash
yamllint --strict --config-file .yamllint stack/compose.yaml
docker compose -f stack/compose.yaml config
```

## Workflow Features

### Lint Pipeline

- Parallel GitGuardian + YAML lint
- GitGuardian secret detection on push events (1Password-backed API key)
- yamllint formatting validation
- `docker compose config` syntax validation
- Matrix strategy: each stack tested independently
- Discord notifications

### Deploy Pipeline

- **Smart deployment** — skips if `/opt/compose` HEAD already matches target SHA (override with `force-deploy`)
- **Per-stack failure isolation** — `set +e` + `failed=()` array within the deploy loop matches the prior matrix's `fail-fast: false`
- **Per-stack timeout** — `timeout $SERVICE_STARTUP_TIMEOUT` inside each loop iteration (not step-level — that would apply to the whole loop)
- **Native health verification** — `docker compose up --wait` for atomic readiness
- **Multi-registry auth** — single `1password/load-secrets-action` step pulls all four registry credential pairs, four `docker/login-action` steps with `logout: false` and `continue-on-error: true` so a single misconfigured registry doesn't block deploys that may not pull from it
- **Sequential existing-then-new** — new stacks only deploy if existing stacks succeeded
- **Failure diagnostics** — on stack failure or health failure, dumps `docker compose ps -a`, `docker inspect` of `.State.Health.Log` (probe history with exit codes + stdout), and `docker compose logs --tail N` scoped to the failing service
- **Automatic rollback** — `git reset --hard <previous_sha>` + redeploy if deploy or health-check failed
- **Discord notifications** — pipeline-status icon line, removed-stacks list, commit link, user mention on failure

## Security Integration

### Secret Management

- All secrets use 1Password references (`op://Vault/Item/field`)
- GitGuardian scanning prevents accidental secret commits
- 1Password service account token provides CI/CD access
- Secrets resolve at runtime via `op run --env-file=…` and `1password/load-secrets-action`
- Multi-registry credentials (ghcr/dockerhub/gitlab/gitlab-zenterprise) cached in the runner host's `~/.docker/config.json` via `docker/login-action` with `logout: false`

### Network model

- **No inbound network access required for deploys** — the runner is on the host. CI never connects *to* the host; the host pulls jobs *from* GitHub.
- **Outbound network** — runner → GitHub Actions API, runner → image registries, runner → 1Password, runner → Discord webhook
- **No Tailscale dependency** — the prior SSH-based path required Tailscale for zero-trust networking; the self-hosted runner approach makes this unnecessary

### Input Security

- Stack names validated against `^[a-zA-Z0-9._-]+$` before use in compose calls
- Target refs validated as 40-char hex SHAs
- Webhook URLs validated for 1Password format

## Workflow Maintenance

### Updating Workflows

1. Run `actionlint` and `yamllint --strict` on the modified workflow file
2. For bash logic changes, run `shellcheck` on the affected script
3. For deploy-local.yml changes, callers will pick up the new SHA via Renovate auto-bumps. Breaking changes (new required input) need a coordinated push: bump every caller's pin in the same minute to avoid a window of broken deploys
4. Update CLAUDE.md and README.md when behavior changes

### Adding a new self-hosted host

Follow `docs/superpowers/runbooks/self-hosted-runner-migration.md`. Highlights:
- Pick a unique runner label (e.g. `zendc`)
- Add the label to **both** `compose-workflow/.github/actionlint.yaml` and the caller repo's `.github/actionlint.yaml`
- Run host prep (deploy user, path ownership pattern, `safe.directory`, umask 002 in admin's rcs)
- Register the runner as a systemd service running as `deploy`

### Renovate

- GitHub Actions dependencies (including the SHA pin on `uses: owine/compose-workflow/.github/workflows/deploy-local.yml@<sha>`) are auto-bumped
- Major version bumps are grouped separately for review

## Repository Structure

```
├── .github/
│   ├── actionlint.yaml           # self-hosted runner labels
│   └── workflows/
│       ├── compose-lint.yml      # reusable lint workflow
│       ├── deploy-local.yml      # reusable deploy workflow (self-hosted)
│       └── workflow-lint.yml     # reusable workflow-file lint
├── scripts/
│   ├── linting/
│   │   ├── lib/
│   │   │   ├── env-helpers.sh    # temp .env generation
│   │   │   └── common.sh         # logging + helpers
│   │   ├── validate-stack.sh
│   │   └── lint-summary.sh
│   ├── deployment/
│   │   ├── lib/
│   │   │   └── common.sh         # logging + validation
│   │   ├── detect-stack-changes.sh
│   │   ├── detect-critical-stacks.sh
│   │   └── build-pr-comment.sh
│   └── testing/
│       ├── test-workflow.sh
│       ├── validate-compose.sh
│       └── README.md
├── docs/
│   └── superpowers/
│       ├── plans/                # historical plan docs
│       ├── specs/                # historical design docs
│       └── runbooks/
│           └── self-hosted-runner-migration.md
├── CLAUDE.md
└── README.md
```

## Troubleshooting

### Runner offline

```bash
gh api repos/owine/<caller-repo>/actions/runners --jq '.runners[] | {name, status}'
```

If status is `offline`:
```bash
ssh <admin>@<host> 'sudo systemctl status actions.runner.owine-<caller-repo>.<host>.service'
sudo journalctl -u 'actions.runner.owine-*' -n 50
```

Common causes: host reboot without `enabled` on the unit, network blip, expired runner registration.

### Permission denied during `git reset --hard` in deploy

Likely the path-ownership pattern broke — usually because the admin user's `umask` reverted to 022 and a new file/dir was created without group-write. One-time repair + permanent fix:

```bash
sudo chmod -R g+w /opt/compose
sudo find /opt/compose -type d -exec chmod g+s {} +
echo 'umask 002' | sudo tee -a /home/<admin>/.zshrc /home/<admin>/.bashrc
```

See the runbook's "umask 002 for the admin user is required (not optional)" section for the full diagnosis.

### Registry login failing

Per-registry login is non-fatal (`continue-on-error: true`). Cached creds in the runner's `~/.docker/config.json` from a prior successful run may carry through. If a particular stack fails to pull:

```bash
ssh <admin>@<host> 'sudo -iu deploy cat ~/.docker/config.json | jq .auths'
```

Verify the relevant registry has `auth: <base64>`. If missing, check the 1P references in `deploy-local.yml`'s registry-login steps and the service account's permissions.

### Health check fails but containers look fine manually

The selector treats these as unhealthy:
- `Health == "unhealthy"`
- `State == "exited" && ExitCode != 0`
- `Health == "" && State != "running" && State != "exited"`

So a *clean* one-shot exit (`exited`, `ExitCode=0`) is **fine**. A non-zero exit is not. A no-healthcheck running service is fine. A no-healthcheck stopped service is not.

If you see false positives, check the diagnostic dump in the failed run — it shows the exact ps output the selector saw.

### Discord notification has wrong color/title

The notify job normalizes `health-check.outputs.status` (`healthy`/`failed`) to `success`/`failure` for the embed. If you see a green deploy showing as red in Discord, check that the case-statement at the top of `compose status` step is intact — copy/paste of the workflow into a per-repo file is the most common cause of breakage.

# important-instruction-reminders
Do what has been asked; nothing more, nothing less.
NEVER create files unless they're absolutely necessary for achieving your goal.
ALWAYS prefer editing an existing file to creating a new one.
NEVER proactively create documentation files (*.md) or README files. Only create documentation files if explicitly requested by the User.
