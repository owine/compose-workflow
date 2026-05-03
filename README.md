# Compose Workflow

Reusable GitHub Actions workflows for Docker Compose deployments across multiple repositories. Provides centralized lint and deploy automation with self-hosted-runner-based deployment to the host on which compose stacks live.

## Architecture

As of 2026-05-02, deployment uses **self-hosted GitHub Actions runners that live on the deployment hosts themselves** — there is no SSH-from-CI path. The runner runs as a `deploy` user, in the `docker` group and the admin's group, and pulls jobs from GitHub. Eliminates the SSH-key/Tailscale/sudo-rule class of issues that plagued the prior design.

Three caller repos use this workflow:
- `docker-piwine` — runner label `piwine`
- `docker-piwine-office` — runner label `piwine-office`
- `docker-zendc` — runner label `zendc`

## Key Features

- 🔒 **Security first** — input validation, GitGuardian secret scanning, 1Password integration
- 🏠 **Self-hosted deploy** — no inbound network access required; runner pulls jobs from GitHub
- 🔄 **Automatic rollback** — `git reset --hard <previous_sha>` + redeploy on deploy or health failure
- 🔍 **Failure diagnostics** — on stack failure, dumps `docker compose ps -a`, healthcheck history (`.State.Health.Log`), and scoped service logs
- 📊 **Discord notifications** — pipeline-status icon line with deploy/health/rollback states, commit link, user mention on failure
- 🚦 **Critical stack detection** — auto-detects from `com.compose.tier: infrastructure` labels
- 🔐 **Multi-registry auth** — single 1P round trip + `docker/login-action` per registry (ghcr.io, docker.io, registry.gitlab.com, custom GitLab)

## Available Workflows

### `compose-lint.yml` — validation

Parallel GitGuardian + yamllint + `docker compose config` validation. Runs on GitHub-hosted runners (no host access needed).

```yaml
jobs:
  lint:
    uses: owine/compose-workflow/.github/workflows/compose-lint.yml@main
    secrets: inherit
    with:
      stacks: '["stack1", "stack2", "stack3"]'
      webhook-url: "op://Docker/discord-github-notifications/<env>_webhook_url"
      repo-name: "my-docker-repo"
      target-repository: ${{ github.repository }}
      target-ref: ${{ github.sha }}
      discord-user-id: "op://Docker/discord-github-notifications/user_id"
      # plus event-context inputs (see compose-lint.yml for the full list)
```

### `deploy-local.yml` — self-hosted deploy

5-job pipeline: prepare → deploy → health-check → rollback → notify. Runs on `[self-hosted, <runner-label>]`.

```yaml
on:
  workflow_run:
    workflows: ["Lint Docker Compose"]
    types: [completed]
    branches: [main]
  workflow_dispatch:
    inputs:
      force-deploy:
        type: boolean
        default: false

concurrency:
  group: deploy-<repo-label>
  cancel-in-progress: false

jobs:
  deploy:
    if: ${{ github.event.workflow_run.conclusion == 'success' || github.event_name == 'workflow_dispatch' }}
    uses: owine/compose-workflow/.github/workflows/deploy-local.yml@<sha>
    secrets: inherit
    with:
      runner-label: piwine                  # or piwine-office, zendc
      live-repo-path: /opt/compose
      repo-name: "docker-piwine"
      webhook-url: "op://Docker/discord-github-notifications/piwine_webhook_url"
      discord-user-id: "op://Docker/discord-github-notifications/user_id"
      target-ref: ${{ github.event.workflow_run.head_sha || github.sha }}
      has-dockge: true                      # false for zendc
      force-deploy: ${{ inputs.force-deploy || false }}
```

Optional inputs: `live-dockge-path` (when `has-dockge: true`), `auto-detect-critical` (default `true`), `critical-services` (manual override), `image-pull-timeout`, `service-startup-timeout`, `failed-container-log-lines`.

## Required Configuration

### Repository structure (caller repo)

```
├── .yamllint                     # yamllint configuration
├── compose.env                   # env file with op:// references
├── .github/
│   ├── actionlint.yaml           # declares the runner-label
│   └── workflows/
│       ├── lint.yml              # calls compose-lint.yml
│       └── deploy.yml            # calls deploy-local.yml
├── stack1/compose.yaml
├── stack2/compose.yaml
└── ...
```

`actionlint.yaml` must declare the runner label or PRs fail with "label X is unknown":
```yaml
self-hosted-runner:
  labels:
    - piwine     # whichever label this repo's deploy.yml passes as runner-label
```

### Required secrets

Calling repos need exactly **one** secret:

- `OP_SERVICE_ACCOUNT_TOKEN` — 1Password service account token. Used by both lint (GitGuardian API key) and deploy (env-file resolution + multi-registry credentials + Discord webhook).

The previously-required `SSH_USER` / `SSH_HOST` secrets are no longer used by `deploy-local.yml` and can be deleted from caller repos.

### 1Password references

```
op://Docker/discord-github-notifications/<env>_webhook_url
op://Docker/discord-github-notifications/user_id
op://Docker/ghcr-pat/{username,pat}
op://Docker/docker-hub/{username,token}
op://Docker/gitlab-registry/{username,token}
op://Docker/gitlab-container-zenterprise/{username,token}
op://Docker/gitguardian/api_key
```

### Self-hosted runner host requirements

The runner host needs `docker`, `jq`, `timeout` (coreutils), `gh`, and `op` (1Password CLI) on the `deploy` user's PATH. Plus a registered runner systemd service running as `deploy`. Full host-prep playbook in [`docs/superpowers/runbooks/self-hosted-runner-migration.md`](docs/superpowers/runbooks/self-hosted-runner-migration.md) — covers path-ownership pattern (admin owns tree, deploy in admin's group via `safe.directory`), setgid + group-write, and the **mandatory umask 002** for both admin and runner users.

### Healthcheck requirements for `--wait`

`deploy-local.yml` invokes `docker compose up --wait`, which only verifies services that have healthchecks defined. Services without healthchecks start but don't gate the deploy. See CLAUDE.md for healthcheck patterns.

One-shot containers (e.g. migration sidecars gated via `service_completed_successfully`) end up `exited` with code 0 — the health-check job recognizes this as success.

## Testing and Development

```bash
# Lint workflow files
actionlint .github/workflows/compose-lint.yml \
           .github/workflows/deploy-local.yml \
           .github/workflows/workflow-lint.yml
yamllint --strict .github/workflows/*.yml

# Lint deployment scripts
shellcheck scripts/deployment/*.sh scripts/linting/*.sh

# Local testing utilities
./scripts/testing/test-workflow.sh
./scripts/testing/validate-compose.sh
```

## Security

### Input validation

- Stack names validated against `^[a-zA-Z0-9._-]+$` before any `docker compose` invocation
- Target refs validated as 40-char hex SHAs
- Webhook URLs validated as 1Password references

### Secret management

- All secrets stored in 1Password (no plaintext in repos or workflow files)
- `op run --env-file=…` resolves references at deploy time
- `1password/load-secrets-action` for individual values (registry creds, Discord webhook)
- Multi-registry creds cached in the runner host's `~/.docker/config.json` via `docker/login-action` with `logout: false`

### Network model

- **No inbound network access** to deployment hosts is required for CI — runners on the host pull jobs from GitHub
- Outbound: runner → GitHub Actions API, image registries, 1Password, Discord webhook
- No Tailscale dependency (the prior SSH-based design needed it; the self-hosted approach makes it unnecessary)

## Troubleshooting

| Symptom | First thing to check |
|---|---|
| Runner shows `offline` in GitHub | `sudo systemctl status actions.runner.<...>.service` on the host |
| `git reset --hard` permission denied | `umask 002` missing in admin user's `.zshrc`/`.bashrc` — see runbook |
| Stack fails with no log lines | Check the failure diagnostic dump in the run — `compose ps -a` + `inspect Health.Log` + scoped `compose logs` should be there |
| Discord embed wrong color | Verify the `case` statement in notify job's status step still maps `healthy → success` and `failed → failure` |
| GitGuardian failure | Verify `OP_SERVICE_ACCOUNT_TOKEN` and that the 1P service account has access to the GitGuardian API key |

For self-hosted runner setup or migration of a new host, see [the runbook](docs/superpowers/runbooks/self-hosted-runner-migration.md).

## Version management

- **Latest**: `@main` for newest features
- **Pinned**: full 40-char SHA on the `uses:` line — Renovate auto-bumps this on the caller side

## Contributing

1. Run `actionlint`, `yamllint --strict`, and `shellcheck` on changed files
2. Update CLAUDE.md and README.md when behavior changes
3. For breaking changes (new required input on a reusable workflow), bump every caller's SHA pin in the same push session — Renovate eventually does this but with a window of broken deploys in between

## License

Private repository, internal use only.
