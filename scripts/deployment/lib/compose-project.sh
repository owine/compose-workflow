#!/usr/bin/env bash
# Compose project resolution for the no-env compose calls in deploy.yml.
#
# `ps`/`logs`/`down` run without `op run`, so they must not parse the stack's
# compose file (its syntax may need ${VARS}). Instead the project is resolved
# from the containers' labels and addressed by name from /.
#
# deploy.yml copies this file to $RUNNER_TEMP/compose-project.sh in each job
# that needs it; source it from there. Requires LIVE_REPO_PATH.

# Compose's own project-name normalisation (compose-go NormalizeProjectName):
# lowercase, keep [a-z0-9_-], strip leading _ and -.
compose_normalize_name() {
  local s
  s=$(tr '[:upper:]' '[:lower:]' <<<"$1" | tr -cd 'a-z0-9_-')
  s="${s#"${s%%[!_-]*}"}"
  printf '%s' "$s"
}

# usage: compose_projects <stack>  -> the stack's Compose project name(s), one per line
#
# 1. Every distinct project whose containers have working_dir=<live tree>/<stack>.
#    Covers a top-level `name:` and dir names Compose normalises, and returns
#    leftovers from a renamed project too.
# 2. Otherwise, containers of the stack's default project name that were created
#    from another dir. If every such dir is also named <stack> (an older checkout
#    or manual `up` of the same stack; reusing a container never refreshes its
#    working_dir label) that project is returned, with a warning. If any dir has
#    a different name it is a foreign project: nothing is returned, with a
#    warning, because `-p <name> down` would act on it.
# 3. No containers at all: nothing is returned (down is a no-op, ps is empty).
#
# Returns 1 (with a warning) if a `docker ps` lookup fails, so a broken docker
# can't pass for "no containers" and turn a teardown into a silent no-op.
#
# Diagnostics go to stderr (stdout is the result); GitHub parses ::warning::
# from either stream.
compose_projects() {
  local stack="$1" dir="${LIVE_REPO_PATH%/}/$1" out p name others d stale=true
  # Captured before sort so docker's exit status is checked without relying on
  # the caller's pipefail.
  if ! out=$(docker ps -a --filter "label=com.docker.compose.project.working_dir=$dir" \
        --format '{{.Label "com.docker.compose.project"}}'); then
    echo "::warning::$stack: docker ps failed; cannot resolve its Compose project" >&2
    return 1
  fi
  p=$(sort -u <<<"$out")
  if [[ -n "$p" ]]; then
    printf '%s\n' "$p"
    return 0
  fi

  name=$(compose_normalize_name "$stack")
  [[ -n "$name" ]] || return 0
  if ! out=$(docker ps -a --filter "label=com.docker.compose.project=$name" \
        --format '{{.Label "com.docker.compose.project.working_dir"}}'); then
    echo "::warning::$stack: docker ps failed; cannot resolve its Compose project" >&2
    return 1
  fi
  others=$(sort -u <<<"$out")
  [[ -n "$others" ]] || return 0

  while IFS= read -r d; do
    [[ "${d%/}" == */"$stack" ]] || stale=false
  done <<<"$others"
  if [[ "$stale" == true ]]; then
    echo "::warning::$stack: containers were created from $(paste -sd, - <<<"$others"), not $dir; using project '$name'. Recreate them from $dir to refresh the label." >&2
    printf '%s\n' "$name"
  else
    echo "::warning::$stack: no containers under $dir, and project '$name' belongs to $(paste -sd, - <<<"$others"); leaving it alone." >&2
  fi
}

# usage: compose_p <stack> <compose args...>
# Runs compose against each of the stack's projects by name from / (no compose
# file there), so the stack's compose file is never parsed. stdin is /dev/null
# so compose can't eat the loop input. Non-zero if the project lookup failed or
# the command failed for any project; zero (and no output) if the stack has no
# project.
compose_p() {
  local stack="$1" projs proj rc=0
  shift
  # Not `done < <(compose_projects …)`: a process substitution's exit status is lost.
  projs=$(compose_projects "$stack") || return 1
  while IFS= read -r proj; do
    [[ -n "$proj" ]] || continue
    (cd / && docker compose -p "$proj" "$@" </dev/null) || rc=$?
  done <<<"$projs"
  return "$rc"
}
