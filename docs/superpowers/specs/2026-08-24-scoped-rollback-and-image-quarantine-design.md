# Scoped rollback and image quarantine

**Status:** Approved (design)
**Date:** 2026-08-24
**Scope:** `compose-workflow` reusable workflow (`deploy.yml`); new user skill `quarantine-image`; caller-repo `.github/renovate.json`

## Problem

A bad upstream image release (`ghcr.io/lukegus/termix:release-2.7.1`) could not start. That single stack
failure took down every subsequent deployment in `docker-piwine`. Two independent defects combined to
produce the outage, and neither one is fixed by fixing the other.

### Defect 1 — unbounded blast radius

`deploy.yml` rolls back by resetting the entire live tree:

```
rollback:
  - git -C "$LIVE_REPO_PATH" reset --hard "$PREVIOUS_SHA"     # deploy.yml:719
  - docker compose up ... for every existing + removed stack   # deploy.yml:736-748
```

One stack's failure therefore reverts the configuration of all fifteen stacks in the repo. Stacks that
deployed successfully moments earlier are silently rolled backwards for a reason unrelated to them.

### Defect 2 — the failure is self-perpetuating

Rollback changes the live tree; it does not change `main`. The bad `image:` line is still committed.
Every deploy begins with `git reset --hard "$TARGET_REF"` (`deploy.yml:283`), so the next commit to land
— any unrelated Renovate PR — re-applies the bad image, fails again, and rolls back again. The pipeline
stays red indefinitely and no further changes reach the host.

The obvious manual fix, `git revert` of the bad bump, does not hold. `compose-workflow/default.json`
groups every `minor`/`patch`/`digest` update into `all-deps` with `automerge: true` and
`minimumReleaseAge: "1 hour"`. Reverting makes the old version current again; Renovate observes a newer
tag available and re-proposes and re-merges it within the hour. **Revert alone is structurally incapable
of holding**, because Renovate has no memory of a version being bad.

## Design

Two independent changes that compose. Change A makes a bad release *survivable*. Change B makes it
*stop recurring*. Neither is sufficient alone.

---

## Change A — scoped rollback in `deploy.yml`

Rollback gains a per-stack path used when the failure is provably confined to stack directories. The
existing whole-tree path is retained unchanged as the fallback for every other case.

### A1. `prepare` classifies rollback scope

New step after `Get changed files` (`deploy.yml:120`). It reads the `all_changed_files` JSON already
produced by `tj-actions/changed-files` and takes the first path segment of each changed path.

| Condition | `rollback_scope` |
|---|---|
| Every changed path's first segment is a known stack directory | `per-stack` |
| Any changed path is a root file (`compose.env`, `.github/**`, `README.md`, …) | `whole-tree` |
| `changed-files` step was skipped (`previous_sha == target-ref`, e.g. `force-deploy`) | `whole-tree` |

New `prepare` job output: `rollback_scope`.

The `whole-tree` default on uncertainty is deliberate. `compose.env` is repo-root and shared by every
stack via `op run --env-file="$LIVE_REPO_PATH/compose.env"`. A failure caused by a renamed variable or a
dead 1Password reference lives *outside* any stack directory, so reverting one stack directory would fix
nothing. Whole-tree reset is the correct behavior for that case and must remain reachable.

### A2. `health-check` names its casualties

`health-check` builds a `failed=()` array but currently exposes only `status`. Add a `failed_stacks`
JSON output alongside it.

Without this, a *health* failure (as distinct from a *deploy* failure) has no stack list to scope
against, and every health failure would silently degrade to whole-tree rollback — losing most of the
benefit of this change, since health failures are the common shape of a bad image release.

### A3. `rollback` gains a per-stack branch

A new first step unions the culprit lists:

```
culprits = deploy.outputs.existing_failed_stacks
         ∪ deploy.outputs.new_failed_stacks
         ∪ health-check.outputs.failed_stacks
```

Then two mutually exclusive branches:

**Per-stack** — when `rollback_scope == 'per-stack'` AND `culprits` is non-empty. For each culprit:

| Culprit type | Action |
|---|---|
| new stack | `docker compose down`; stays gone (matches current behavior) |
| existing stack | `git checkout $PREVIOUS_SHA -- <stack>/`, then `op run --no-masking --env-file="$LIVE_REPO_PATH/compose.env" -- docker compose up -d --quiet-pull --wait --remove-orphans` |

No `--pull always` and no `--build`, matching the current rollback step: the stack lands on the
locally-tagged previous image kept on disk by the docker-prune policy, so recovery does not depend on a
registry being reachable mid-incident. Healthy stacks are never touched.

**Whole-tree** — every other case. Today's exact behavior, unchanged: tear down new stacks,
`git reset --hard "$PREVIOUS_SHA"`, re-up existing + removed.

### A4. Partial checkout leaves the live tree dirty — and that is safe

`git checkout $PREVIOUS_SHA -- <stack>/` leaves the live tree with `HEAD` at the target SHA but one
directory's content staged at the previous SHA. No cleanup step is required: every deploy begins with
`git -C "$LIVE_REPO_PATH" reset --hard "$TARGET_REF"` (`deploy.yml:283`), which restores a clean tree
before anything else runs. No drift accumulates across runs.

### A5. `notify` reports which path ran

The Discord message currently renders a pipeline line such as `✅ Deploy → ❌ Health → ✅ Rollback`.
Extend the rollback segment with the scope and culprit list:

```
🔄 Rollback: per-stack (termix)
🔄 Rollback: whole-tree
```

Without this, a narrowly-scoped rollback is indistinguishable in the alert from a full fleet revert —
which is precisely the distinction the on-call reader needs first.

### What Change A explicitly does not fix

With no auto-quarantine, the bad `image:` line remains on `main`. The next deploy re-applies it, fails
on that stack, and rolls that stack back again. Unrelated updates in the same commit still land
successfully — that is the win — but the run is still red and still pages. Stopping recurrence is
Change B.

---

## Change B — the `quarantine-image` skill

### B1. The blocking mechanism

Renovate's `allowedVersions` accepts either a version *range* interpreted by the active versioning
scheme, or a *regex* delimited by forward slashes, with `!/…/` as the negated (exclude) form.

**The negated regex is the correct mechanism here, and range syntax such as `!=release-2.7.1` is not.**
Ranges are interpreted by the versioning scheme, and these repos pin several images to custom `regex:`
versioning schemes where range operators are not dependable:

```json
{ "matchPackageNames": ["ghcr.io/lukegus/termix"],
  "versioning": "regex:^release-(?<major>\\d+)\\.(?<minor>\\d+)\\.(?<patch>\\d+)$" }
```

A negated regex filters the **raw version string** before any versioning scheme parses it. One mechanism
therefore covers every tag format in the fleet — `release-2.7.1`, LSIO's `4.2.1-ls286`, homebridge's
`2026-08-24`:

```json
{ "matchPackageNames": ["ghcr.io/lukegus/termix"],
  "allowedVersions": "!/^release-2\\.7\\.1$/" }
```

Because `allowedVersions` filters at lookup time, a blocked version is not merely un-automerged — it is
invisible to Renovate. Paired with reverting the compose file, that is what makes a revert hold.

### B2. Shape and invocation

A single `~/.claude/skills/quarantine-image/SKILL.md`, matching the existing `renovate-trigger` and
`renovate-dashboard-triage` convention: prose with inline bash recipes, no helper scripts, no plugin
packaging.

```
/quarantine-image <stack> <bad-version> "<reason>"
/quarantine-image --unblock <stack>
```

The stack name locates the repo by globbing `docker-piwine*/<stack>/compose.yaml`. A name matching more
than one repo is an error, not a guess.

### B3. Quarantine steps

1. **Resolve the image.** Read the `image:` line from the stack's compose file; split package name
   (`ghcr.io/lukegus/termix`) from tag and digest. For multi-service stacks, the supplied bad version
   identifies which service.

2. **Find the last-known-good line.** Walk `git log -p -- <stack>/compose.yaml` back to the commit
   before the bad version landed and take that `image:` line **verbatim** — tag and digest together,
   exactly as Renovate originally wrote them. The skill never composes a `@sha256:` by hand; it restores
   a tag/digest pair a real Renovate run already verified.

3. **Write the block.** Add or extend a `packageRules` entry in the **consuming repo's**
   `.github/renovate.json` — never the shared `compose-workflow/default.json`, since a bad `termix`
   build is not `docker-piwine-office`'s problem.

   | Case | Action |
   |---|---|
   | No existing block for the package | Append a new rule object with the negated-regex `allowedVersions` |
   | A block already exists | Widen the alternation in place: `!/^release-(2\.7\.1\|2\.8\.0)$/` |

   Extending in place rather than appending matters: two `packageRules` entries matching the same
   package both apply, and the later `allowedVersions` silently wins, discarding the earlier block.

   This rule is kept **separate** from the package's existing `versioning` rule
   (`docker-piwine/.github/renovate.json:19-23`). Renovate merges matching rules in order, so the two
   coexist, and keeping them apart lets `--unblock` delete a whole object instead of surgically editing
   a shared one.

4. **Commit both files together, atomically.** The ordering is load-bearing: the compose revert makes
   `2.7.0` current *in the same commit* that makes `2.7.1` invisible. Split across two commits, there is
   a window in which the pinned-current version is also the blocked version — a state Renovate handles
   badly. The commit message records the reason and the failing run.

5. **Report and stop.** Print the diff and push. The skill does **not** trigger a Renovate run; it
   points at the existing `renovate-trigger` skill rather than reimplementing it.

### B4. `--unblock`

Removes the package's rule object and its comment from `.github/renovate.json`, commits, and notes that
Renovate will offer the previously-blocked version again on its next run. It does not touch the compose
file: by the time you unblock, you want the newest version, not the one you blocked.

### B5. Block lifecycle

Blocks are single-version and therefore self-expiring in effect. When upstream ships `2.7.2`, Renovate
offers it normally; the stale rule sits inert and documented until pruned. `--unblock` is the manual
prune. No scheduled audit and no expiry metadata — that machinery would cost more than the stale JSON
objects it removes.

### B6. Cases the skill must refuse rather than guess

| Case | Behavior |
|---|---|
| Stack name matches zero or multiple repos | Error; ask the user to disambiguate |
| No prior version in history (bad version was the first ever pinned) | Error; nothing to revert to, tell the user to fix forward |
| `image:` uses a floating tag (`:latest`) | Error; there is no version to block — the answer is a digest pin, not a quarantine |

---

## Worked example: the termix incident under this design

1. Renovate merges `release-2.7.1`; the image cannot start.
2. Deploy fails on `termix` only. `rollback_scope` is `per-stack` (only `termix/compose.yaml` changed),
   so `termix/` reverts to `release-2.7.0` and comes back up. The other fourteen stacks keep their new
   configuration. Discord reports `🔄 Rollback: per-stack (termix)`.
3. Operator runs `/quarantine-image termix release-2.7.1 "container exits on boot"`. One commit reverts
   the compose line and adds `"allowedVersions": "!/^release-2\\.7\\.1$/"`.
4. Subsequent deploys are green. Renovate never re-proposes `2.7.1`.
5. Upstream ships `2.7.2`; Renovate offers it through the normal `all-deps` path. The stale block
   remains until `/quarantine-image --unblock termix`.

## Testing

| Change | Verification |
|---|---|
| A1 scope classifier | Unit-test the path-segment logic against fixture file lists: stack-only, root-only, mixed, empty |
| A2 health-check output | Assert `failed_stacks` JSON is well-formed and matches `status=failed` |
| A3 per-stack branch | Deploy a deliberately-broken image to one non-critical stack on the office Pi; assert only that stack reverts and the others stay at the new SHA |
| A3 whole-tree fallback | Same, with a `compose.env` edit in the commit; assert whole-tree reset runs |
| A5 notify | Inspect the rendered Discord payload for both scopes |
| B | `npx --yes renovate-config-validator` on the edited `.github/renovate.json`; confirm on the Dependency Dashboard that the blocked version no longer appears |

## Out of scope

- Automatic quarantine from the deploy workflow. The workflow cannot distinguish a bad image from a bad
  healthcheck, a bad config change, or a transient registry blip, and a false positive would block a
  good version.
- Changes to `minimumReleaseAge` or automerge policy in `default.json`. Preventing bad releases from
  being adopted at all is a separate trade-off from recovering when one is.
- Expiry metadata or scheduled auditing of blocks (see B5).
