#!/usr/bin/env bash
# Script Name: ensure-shared-networks.sh
# Purpose: Create cross-stack bridge networks that stacks join as
#          `external: true`, if they don't already exist.
# Usage: ./ensure-shared-networks.sh proxy backup
#
# Why outside Compose: a network owned by one Compose project (the old
# `dockge_default`) makes deploy order load-bearing on a fresh host — every
# other stack fails "declared as external, but could not be found" until the
# owner is up — and the owner's `down` tries to remove a network every other
# stack is attached to. Networks created here belong to no project.
#
# Idempotent: an existing network is reused untouched, never recreated —
# recreating would detach every container on it, and Docker network labels
# are immutable, so a missing label cannot be added in place.
#
# The `com.compose-workflow.shared` label exempts these networks from the
# docker-prune job's `docker network prune`. A pre-existing network without
# it (made by hand, or owned by a Compose project) is reused with a warning:
# prune removes it whenever no container is attached. The next deploy or
# rollback recreates it labelled, but anything started in between fails.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

readonly SHARED_LABEL="com.compose-workflow.shared=true"

for net in "$@"; do
  if [[ ! "$net" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
    log_error "invalid network name: $net"
    exit 1
  fi

  if labels=$(docker network inspect "$net" --format \
      '{{ index .Labels "com.compose-workflow.shared" }}|{{ index .Labels "com.docker.compose.project" }}' \
      2>/dev/null); then
    shared="${labels%%|*}"
    project="${labels#*|}"
    if [[ -n "$project" ]]; then
      echo "::warning::shared network $net is owned by Compose project '$project'; its 'down' will try to remove it"
    fi
    if [[ "$shared" != "true" ]]; then
      echo "::warning::shared network $net predates this script (no ${SHARED_LABEL%%=*} label), so docker network prune removes it when nothing is attached; recreate it once it is idle: docker network rm $net"
    fi
    log_success "$net exists"
  else
    docker network create --driver bridge --label "$SHARED_LABEL" "$net" >/dev/null
    log_success "created $net"
  fi
done
