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

### Changes to `detect-stack-changes.sh`

All detector functions are updated to use the effectively-present predicate. The aggregation and JSON-output layers are unchanged.

- **`detect_removed_stacks_gitdiff`** — detect either `compose.yaml` deletion *or* `.disabled` addition between SHAs. Both signal a removed-effectively-present transition. Pattern becomes `'^[^/]+/(compose\.yaml|\.disabled)$'` with diff-filter `D` for compose.yaml and `A` for `.disabled`.
- **`detect_removed_stacks_tree`** — compute effective-present sets on both sides (target SHA tree and live tree) using `git cat-file -e` for `compose.yaml` and `.disabled`. Removed set = present-in-live ∧ ¬present-in-target.
- **`detect_removed_stacks_discovery`** — accept either `<stack>/compose.yaml` or `<stack>/.disabled` entries from the changed-files JSON. For `.disabled`, the file must be an *addition* (the changed-files action distinguishes adds from deletes; we filter accordingly).
- **`detect_new_stacks_gitdiff`** — detect either `compose.yaml` addition *or* `.disabled` deletion between SHAs where the result is effectively-present in the target.
- **`detect_new_stacks_tree`** — symmetric to removed: present-in-target ∧ ¬present-in-live.
- **`detect_new_stacks_input`** — input filter already takes the effectively-present discover-stacks output, so this function works unchanged.

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

A new `disabled_stacks` job output is emitted from the same step by enumerating directories that contain `.disabled` alongside a `compose.yaml`. This output drives visibility only — no deploy step branches on it.

### Changes to notify and PR comment

- `build-pr-comment.sh` — accept a new `--disabled-stacks` argument; render a "🛑 Disabled: foo, bar" line in the PR comment body when the list is non-empty, positioned adjacent to the existing "🗑️ Removed" line.
- `deploy.yml` notify job — pass `prepare.outputs.disabled_stacks` through to the PR comment builder and include the same "🛑 Disabled" line in the Discord embed fields when non-empty.

### Caller-repo workflow: no changes

Lint discovery in caller repos does not filter `.disabled` — disabled stacks continue to receive YAML linting and `docker compose config` validation. This is intentional: keeps the disabled compose file from rotting silently between disable and re-enable.

## Testing

### Unit (script-level)

Extend the existing testing harness under `scripts/testing/` with a fixture covering each transition row from the table above. For each row:

1. Construct a two-SHA scenario in a throwaway git repo (CURRENT_SHA and TARGET_SHA with the appropriate `compose.yaml` / `.disabled` states).
2. Run `detect-stack-changes.sh` against the scenario.
3. Assert the resulting `removed_stacks`, `existing_stacks`, `new_stacks` JSON outputs match expected.

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
