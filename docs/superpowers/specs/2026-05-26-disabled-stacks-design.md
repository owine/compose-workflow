# Disabled stacks via `.disabled` marker

**Status:** Approved (design)
**Date:** 2026-05-26
**Scope:** `compose-workflow` reusable workflows (`deploy.yml`, `detect-stack-changes.sh`, optional notify paths)

## Problem

There is currently no way to temporarily disable a Docker Compose stack without deleting it from the repository. The only path to "stop running stack X" is to delete its `compose.yaml`, which loses local edits, history co-location, and configuration context. When you want to re-enable later, you restore from git, which is workable but awkward — and during the disabled window, the compose file is gone from the working tree entirely.

We want a first-class disabled state that:

1. Causes the deployment pipeline to run `docker compose down` against the stack on the disable transition (same teardown the workflow already runs for deleted stacks).
2. Leaves the compose file and stack directory in place so they remain editable, lintable, and recoverable without git surgery.
3. Allows a one-line re-enable that brings the stack back via the normal new-stack deploy path.
4. Does not require changes to caller repositories beyond `touch <stack>/.disabled`.

## Design

### Marker file

A stack is disabled when an empty `.disabled` file exists alongside its `compose.yaml`:

```
baikal/
├── compose.yaml
└── .disabled
```

Presence of the file is the entire signal. The file body is reserved for future use (e.g. a human-readable reason) but is unused today. Disabling is `touch <stack>/.disabled && git add <stack>/.disabled`. Re-enabling is `git rm <stack>/.disabled`.

### Core predicate: "effectively present"

A stack is **effectively present** at a given SHA iff:

```
compose.yaml exists  AND  .disabled does NOT exist
```

This single predicate replaces every "has `compose.yaml`" check inside `scripts/deployment/detect-stack-changes.sh`. With that substitution, the existing three-bucket classifier (removed / existing / new) yields exactly the right behavior for every transition:

| Transition | CURRENT_SHA | TARGET_SHA | Classified as | Action |
|---|---|---|---|---|
| Disable | enabled | disabled | **removed** | `docker compose down` (teardown step at `deploy.yml:218`) |
| Re-enable | disabled | enabled | **new** | `docker compose up --wait` (new-stack deploy step) |
| Stay disabled | disabled | disabled | (excluded) | no-op |
| Born disabled | absent | disabled | (excluded) | no-op |
| Delete while disabled | disabled | absent | (excluded) | no-op (already torn down at disable time) |
| Normal delete | enabled | absent | **removed** | `docker compose down` (unchanged) |
| Normal add | absent | enabled | **new** | `docker compose up --wait` (unchanged) |
| Normal update | enabled | enabled | **existing** | `docker compose up --wait` (unchanged) |

The disable transition piggybacks on the removed-stack pathway. The teardown step reads compose files from the pre-reset live tree, so it tears down using the still-present `compose.yaml` — the `.disabled` marker does not interfere because teardown happens *before* `git reset --hard` updates the working tree.

**Operational assumption:** The "delete while disabled" row is a no-op because the design assumes the stack was already torn down at the prior disable event. If you push a single commit that goes straight from enabled → absent (skipping the disabled state), the existing "normal delete" row handles it. The pathological case is pushing one commit that disables a stack and a second commit that deletes the directory *before the disable deploy has run* — there, the disable transition gets collapsed into a delete, but the teardown still fires correctly because the live tree's pre-reset state still has `compose.yaml` without `.disabled`, which the removed-tree detector picks up via "live-effective ∖ target-effective."

### Changes to `detect-stack-changes.sh`

All detector functions are updated to use the effectively-present predicate. The aggregation and JSON-output layers are unchanged.

**Critical guard for both directions:** every detector must classify a stack only when the effective-presence state *actually transitioned* between CURRENT and TARGET. Naive pattern matching on file-change diffs is insufficient because two pathological rows from the transition table would otherwise leak into the wrong bucket:

- **Born disabled (absent → disabled)**: a single commit adds both `compose.yaml` and `.disabled`. A naive removed detector keyed on "`.disabled` addition" would flag this for teardown, but the stack was never effectively present in CURRENT and there is nothing to tear down.
- **Delete while disabled (disabled → absent)**: a naive removed detector keyed on "`compose.yaml` deletion" would flag this, but the stack was already disabled (and therefore already torn down at the prior disable event).

Both cases must be excluded. The fix is to gate every removed candidate on **effectively-present in CURRENT_SHA** and every new candidate on **effectively-present in TARGET_SHA**, evaluated via `git cat-file -e` against the respective tree.

Detector-by-detector changes:

- **`detect_removed_stacks_gitdiff`** — find candidate stack names from diff entries matching `'^[^/]+/(compose\.yaml|\.disabled)$'` (compose.yaml with diff-filter `D`, `.disabled` with diff-filter `A`). For each candidate, emit it only if it was effectively-present in CURRENT_SHA: `git cat-file -e $CURRENT_SHA:<stack>/compose.yaml` succeeds AND `git cat-file -e $CURRENT_SHA:<stack>/.disabled` fails.
- **`detect_removed_stacks_tree`** — compute the effective-present set on each side. Live side: directory contains `compose.yaml` AND not `.disabled` on the filesystem. Target side: `git cat-file -e $TARGET_SHA:<dir>/compose.yaml` AND not `git cat-file -e $TARGET_SHA:<dir>/.disabled`. Removed set = live-effective ∖ target-effective.
- **`detect_removed_stacks_discovery`** — accept candidate stack names from changed-files JSON entries matching either `<stack>/compose.yaml` (deletion) or `<stack>/.disabled` (addition). The action distinguishes adds from deletes via the `deleted_files` / `added_files` outputs; the workflow already passes deleted only, so add a second pass for added `.disabled` files. Apply the same effectively-present-in-CURRENT guard before emitting.
- **`detect_new_stacks_gitdiff`** — find candidates from `compose.yaml` additions (diff-filter `A`) and `.disabled` deletions (diff-filter `D`). Emit only if effectively-present in TARGET_SHA: `git cat-file -e $TARGET_SHA:<stack>/compose.yaml` succeeds AND `git cat-file -e $TARGET_SHA:<stack>/.disabled` fails.
- **`detect_new_stacks_tree`** — symmetric to removed-tree: target-effective ∖ live-effective.
- **`detect_new_stacks_input`** — input filter takes the (already disabled-filtered) discover-stacks output, so this function works unchanged.

Workflow inputs: the discovery branch must also receive added-files JSON, not just deleted. Update the `Detect stack changes` step in `deploy.yml` (around line 145) to pass both `deleted_files` and `added_files` outputs from `tj-actions/changed-files`; the script gains a `--added-files` flag mirroring `--removed-files`.

### Changes to `deploy.yml` `prepare` job

The `Discover stacks` step (deploy.yml:123–143) gains one filter: skip directories where `.disabled` is present. After change:

```bash
for dir in */; do
  dir_name=$(basename "$dir")
  if [[ -f "$dir/compose.yml" || -f "$dir/compose.yaml" ]] \
     && [[ ! -f "$dir/.disabled" ]]; then
    stacks+=("\"$dir_name\"")
  fi
done
```

A new `disabled_stacks` job output is emitted from the same step as a JSON array (consistent with the existing `removed_stacks` / `existing_stacks` / `new_stacks` outputs), enumerating directories that contain `.disabled` alongside a `compose.yaml`. This output drives visibility only — no deploy step branches on it.

### Changes to notify and PR comment

- `build-pr-comment.sh` — accept a new `--disabled-stacks` argument; render a "🛑 Disabled: foo, bar" line in the PR comment body when the list is non-empty, positioned adjacent to the existing "🗑️ Removed" line.
- `deploy.yml` notify job — pass `prepare.outputs.disabled_stacks` through to the PR comment builder and include the same "🛑 Disabled" line in the Discord embed fields when non-empty.

### Caller-repo workflow: no changes

Lint discovery in caller repos does not filter `.disabled` — disabled stacks continue to receive YAML linting and `docker compose config` validation. This is intentional: keeps the disabled compose file from rotting silently between disable and re-enable. Future contributors tempted to "fix" the caller-side discovery snippet (e.g. the example in the root `CLAUDE.md`) for consistency with the deploy-side filter should be deterred — the asymmetry is by design.

## Testing

### Unit (script-level)

Extend the existing testing harness under `scripts/testing/` with a fixture covering each transition row from the table above. For each row:

1. Construct a two-SHA scenario in a throwaway git repo (CURRENT_SHA and TARGET_SHA with the appropriate `compose.yaml` / `.disabled` states).
2. Run `detect-stack-changes.sh` against the scenario.
3. Assert the resulting `removed_stacks`, `existing_stacks`, `new_stacks` JSON outputs match expected.

The fixture set must explicitly include a **born-disabled** row: a commit that adds both `compose.yaml` and `.disabled` simultaneously, asserted to produce empty removed/existing/new — this catches regressions of the effectively-present-in-CURRENT guard, which is the failure mode where the discovery detector or gitdiff detector would naively flag the `.disabled` addition as a removal. Similarly include a **delete-while-disabled** row to catch the symmetric naive-removal regression.

Also run `shellcheck scripts/deployment/detect-stack-changes.sh` after edits.

### Integration (workflow-level)

`actionlint` and `yamllint --strict` on the modified `deploy.yml`.

### Manual smoke test

Pick one low-stakes stack (e.g. `dozzle` in `docker-piwine-office`):

1. `touch dozzle/.disabled`, commit, push. Verify:
   - Discord notification shows "🛑 Disabled: dozzle".
   - On the host, `docker compose ps` shows no `dozzle` containers running.
   - The `dozzle/compose.yaml` is still present in `/opt/compose/dozzle/`.
2. `git rm dozzle/.disabled`, commit, push. Verify:
   - Stack is classified as new (visible in deploy logs).
   - Containers are running again after deploy completes.
   - Health check passes (if dozzle is in the critical-stacks list — it is for piwine).

## Out of scope (explicit YAGNI)

- Reason strings or metadata in the marker file body.
- A central registry or dashboard of disabled stacks across repos.
- Per-environment disable semantics (use branches or repo-level config if this need arises).
- CLI tooling — `touch` and `git rm` are sufficient.
- Treating the marker file as a special-case "modification" for lint trigger purposes; existing path-based triggers cover it.

## Files affected

```
compose-workflow/
├── scripts/deployment/
│   ├── detect-stack-changes.sh     # predicate update across 6 detector functions
│   └── build-pr-comment.sh         # new --disabled-stacks arg + render line
└── .github/workflows/
    └── deploy.yml                   # discover-stacks filter, disabled_stacks output, notify wiring
```

No changes required in caller repositories (`docker-piwine`, `docker-piwine-office`, `docker-zendc`).
