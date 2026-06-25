# Adding a New Self-Hosted Host

Generic, reusable procedure for bringing a new Docker-Compose node onto the
self-hosted-runner deploy system.

For the *history* of the original SSH→self-hosted migration and the incident
lessons behind these steps (umask 002, Renovate races, ghcr pull-timeout
misdiagnosis, etc.), see [`self-hosted-runner-migration.md`](self-hosted-runner-migration.md).

---

## Parameters

Pick these before starting and substitute throughout:

| Placeholder | Meaning |
|---|---|
| `<node>` | short node name / repo suffix |
| `<repo>` | caller repo |
| `<label>` | runner label (unique per host) |
| `<admin>` | human admin / SSH user on the host |
| `<arch>` | `linux/amd64` or `linux/arm64/v8` (lint) + `x64`/`arm64` (runner tarball) |
| `<has-dockge>` | `true` for Pi-style, `false` for datacenter/cloud |
| `<webhook>` | Discord webhook 1P ref |

---

## Phase A — Caller repo scaffolding

Mirror an existing same-shaped repo (zendc for `has-dockge: false`, piwine-office
for `has-dockge: true`). The repo needs:

```
.github/actionlint.yaml          # declares the <label> runner label
.github/renovate.json            # extends github>owine/compose-workflow
.github/workflows/lint.yml       # calls compose-lint.yml; platforms: "<arch>"
.github/workflows/deploy.yml     # calls deploy.yml; runner-label/has-dockge/webhook
.gitignore                       # MUST include `!compose.env` after `*.env`
.yamllint
compose.env                      # op:// references — MUST be tracked (force-add)
<stack>/compose.yaml             # one dir per stack
```

Gotchas:
- **`compose.env` must be tracked.** `.gitignore` has `*.env`; add an explicit
  `!compose.env` negation so the file (op:// references only, no secret values)
  stays in the repo. The deploy reads `$LIVE_REPO_PATH/compose.env` and the live
  tree is reset to repo HEAD — an untracked env file would never reach the host.
- `deploy.yml`: set `runner-label: <label>`, `has-dockge: <has-dockge>`,
  `concurrency.group: deploy-<label>`, `live-repo-path: /opt/compose` (omit
  `live-dockge-path` when `has-dockge: false`).
- `lint.yml`: set `platforms: "<arch>"` and `repo-name`/`target-repository`.
- Pin the reusable-workflow `uses:` to the current 40-char compose-workflow SHA.

## Phase B — compose-workflow + GitHub config

1. **Declare the label** in `compose-workflow/.github/actionlint.yaml` (add
   `<label>`). Without it, actionlint blocks PRs to compose-workflow with
   "label X is unknown" once the caller uses `runs-on: [self-hosted, <label>]`.
2. **Create the GitHub repo** (`owine/<repo>`, private) and push `main`.
3. **Repo secret** — exactly one: `OP_SERVICE_ACCOUNT_TOKEN`:
   ```bash
   op read "op://Private/<git-deployment-token-item>/credential" \
     | gh secret set OP_SERVICE_ACCOUNT_TOKEN -R owine/<repo>
   ```
4. **Repo settings** (match the fleet):
   ```bash
   gh api -X PATCH repos/owine/<repo> \
     -F allow_auto_merge=true -F allow_merge_commit=false \
     -F allow_rebase_merge=true -F allow_squash_merge=true \
     -F allow_update_branch=true -F delete_branch_on_merge=true -F has_wiki=false
   ```
5. **Branch ruleset** ("Lint to Merge") — copy from an existing repo:
   ```bash
   gh api repos/owine/docker-piwine/rulesets/<id> \
     --jq '{name,target,enforcement,conditions,rules,bypass_actors}' > /tmp/rs.json
   gh api -X POST repos/owine/<repo>/rulesets --input /tmp/rs.json
   ```
   Requires the `lint / lint-summary` check (same name on every caller, since all
   use `compose-lint.yml`), squash+rebase merge methods, linear history, admin bypass.

## Phase C — 1Password items (Docker vault)

- `<node>-common` — **API Credential** category; populate the built-in `hostname`
  field (do NOT add a duplicate) + a custom `appdata_path` field. Reference as
  `op://Docker/<node>-common/hostname` and `.../appdata_path`.
- `<node>-<stack>-agent-tailscale-authkey` — **API Credential** per agent stack;
  token in the concealed `credential` field. Reference as
  `op://Docker/<node>-<stack>-agent-tailscale-authkey/credential`.

The "Git Deployment" service account must have Docker-vault read access (it
already does for the existing fleet, so new items in that vault are covered).

## Phase D — Host prep

Admin (`<admin>`) needs passwordless sudo. Host tooling, by class:

- **Required** (deploy fails without): `docker` (+ compose plugin), `git`, `jq`,
  `op`, `timeout`, plus standard coreutils (`grep`/`sed`/`awk`/`sort`/`comm`/`diff`/
  `find`/`mktemp`/`xargs`).
- **Bootstrap only**: `curl`, `tar` (download + extract the runner).
- **Recommended** (NOT invoked by the deploy workflow, but install for fleet parity
  + on-host troubleshooting): `gh`. The only `gh` usage in `deploy.yml` is the
  `notify` job, which runs GitHub-hosted — but every host carries `gh` for
  `gh api repos/<repo>/actions/runners`, journal lookups, etc. (This corrects the
  older migration runbook's table, which listed `gh` as flatly "required".)
- **Provided by the runner — do NOT install on the host**: Node.js. JS actions
  (`actions/checkout`, `changed-files`, the 1Password / docker-login actions) run
  on the Node bundled in `actions-runner/externals/`; a system `node` is not a
  host dependency.

Verify:
```bash
sudo -u deploy bash -lc 'for t in docker git jq op timeout gh; do command -v $t >/dev/null || echo MISSING:$t; done'
```

```bash
# deploy user (runs the runner), in docker group
sudo useradd -m -s /bin/bash deploy 2>/dev/null || true
sudo usermod -aG docker deploy

# Clone /opt/compose. If <admin> has no GitHub creds on the host, clone via a
# git bundle from a machine that does (avoids putting a token on the host):
#   (local)  git -C <repo> bundle create /tmp/<node>.bundle --all
#   (local)  scp /tmp/<node>.bundle <admin>@<host>:/tmp/
sudo mkdir -p /opt/compose && sudo chown <admin>:<admin> /opt/compose
git clone /tmp/<node>.bundle /opt/compose
git -C /opt/compose remote set-url origin https://github.com/owine/<repo>.git

# Path ownership: admin owns the tree, deploy gets group access (NOT chown deploy)
sudo chown -R <admin>:<admin> /opt/compose
sudo chmod -R g+rwX /opt/compose
sudo find /opt/compose -type d -exec chmod g+s {} +     # setgid → inherit group
sudo usermod -aG <admin> deploy                          # deploy in admin's group
sudo -u deploy git config --global --add safe.directory /opt/compose
echo 'umask 002' | sudo tee -a /home/<admin>/.zshrc /home/<admin>/.bashrc  # CRITICAL
```

Why each matters: `safe.directory` (git refuses a tree owned by another uid),
setgid + `umask 002` (so admin-created files stay group-writable, or the runner's
`git reset --hard` fails). See the migration runbook for the full diagnosis.

Optional smoke (catches op-scope / volume issues before any CI loop) — transport
the token via an `scp`'d `0600` file, **never** `secret | ssh host 'bash -s' <<EOF`
(the heredoc and the pipe both claim ssh stdin and the secret leaks):
```bash
sudo -u deploy bash -lc 'OP_SERVICE_ACCOUNT_TOKEN=$(cat /tmp/.optoken) \
  op run --no-masking --env-file=/opt/compose/compose.env -- \
  docker compose -f /opt/compose/<stack>/compose.yaml config >/dev/null && echo OK'
```

## Phase E — Runner registration

Runners **self-update**, so the pinned version is only a bootstrap.

```bash
# as deploy: download + extract (use x64 or arm64 to match <arch>)
sudo -u deploy bash -lc '
  mkdir -p ~/actions-runner && cd ~/actions-runner
  curl -fsSL -o r.tgz https://github.com/actions/runner/releases/download/v<VER>/actions-runner-linux-<arch>-<VER>.tar.gz
  tar xzf r.tgz && rm r.tgz'
sudo /home/deploy/actions-runner/bin/installdependencies.sh

# register (token is single-use, ~1h TTL — pass via env, not a pipe+heredoc)
REG=$(gh api -X POST repos/owine/<repo>/actions/runners/registration-token --jq .token)
sudo -u deploy bash -lc "cd ~/actions-runner && ./config.sh \
  --url https://github.com/owine/<repo> --token $REG \
  --labels <label> --name <label>-runner --unattended --replace"

# install + start as a systemd service running AS deploy
sudo bash -c 'cd /home/deploy/actions-runner && ./svc.sh install deploy && ./svc.sh start'
```

Run everything against `~deploy` via `sudo -u deploy` — `/home/deploy` is mode 700,
so the admin user can't `ls` it directly.

Verify online:
```bash
gh api repos/owine/<repo>/actions/runners \
  --jq '.runners[]|{name,status,busy,labels:[.labels[].name]}'
```

## Phase F — First deploy

The auto-triggered deploy from the initial push **skips** ("already at target
commit") because `/opt/compose` was cloned at the exact pushed SHA. Force it once:

```bash
gh workflow run deploy.yml -R owine/<repo> -f force-deploy=true
gh run watch <run-id> -R owine/<repo> --exit-status
```

Subsequent normal pushes deploy without `--force` (the live tree will sit behind
the new commit).

## Verification

```bash
ssh <admin>@<host> 'sudo -u deploy docker ps --format "{{.Names}}\t{{.Status}}"'
```
Expect every container `Up … (healthy)`, and Tailscale sidecars to hold a tailnet
IP (`docker exec <stack>-agent-tailscale tailscale ip -4`).

## Checklist

- [ ] Caller repo scaffolded; `compose.env` tracked via `!compose.env`
- [ ] `<label>` added to `compose-workflow/.github/actionlint.yaml`
- [ ] GitHub repo created + pushed; `OP_SERVICE_ACCOUNT_TOKEN` secret set
- [ ] Repo merge settings + "Lint to Merge" ruleset applied
- [ ] 1Password `<node>-common` + per-stack authkey items populated
- [ ] Host: `deploy` user, `/opt/compose` clone, ownership/setgid/`safe.directory`/`umask 002`
- [ ] Runner registered + systemd service active & enabled
- [ ] First deploy forced; containers healthy + on tailnet
