#!/usr/bin/env bash
#
# Image Platform Manifest Validation
# Verifies each digest-pinned image in a stack's compose file publishes a
# manifest for the requested target platform(s). Catches the Docker Hub
# publish-race failure mode where an OCI image index is pushed before its
# per-platform child manifests, which presents as
#   "no matching manifest for linux/<arch>/<variant>"
# at deploy time.
#
# Usage:
#   validate-image-platforms.sh --stack STACK_NAME --platforms PLAT[,PLAT...]
#
# Platform examples: linux/amd64, linux/arm64/v8, linux/arm/v7
#
# Behavior:
#   - Only checks images with a @sha256:... digest (Renovate pins).
#   - Untagged or tag-only refs are skipped (no race risk by digest).
#   - Single-manifest (non-index) images are skipped with a notice — the
#     digest is platform-specific by construction.
#   - imagetools inspect failures → exit 1. The lint job authenticates to
#     every registry we pull from (see the login steps in compose-lint.yml),
#     so a failure here means a real problem — bad digest, deleted image, or
#     broken credentials — not merely an unauthenticated runner.
#     Transient-looking failures are retried; definitive ones (auth rejected,
#     manifest unknown) fail immediately since retrying cannot help.
#   - Missing target platform in a fetched index → exit 1.
#
# Exit codes:
#   0 - All checked images publish the requested platform(s)
#   1 - An image is missing a requested platform manifest, or could not be
#       inspected at all
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/env-helpers.sh
source "$SCRIPT_DIR/lib/env-helpers.sh"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

STACK=""
PLATFORMS=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --stack)
      STACK="$2"
      shift 2
      ;;
    --platforms)
      PLATFORMS="$2"
      shift 2
      ;;
    *)
      log_error "Unknown argument: $1"
      exit 1
      ;;
  esac
done

require_var STACK
require_var PLATFORMS
validate_stack_name "$STACK"

IFS=',' read -ra REQ_PLATFORMS <<< "$PLATFORMS"
for p in "${REQ_PLATFORMS[@]}"; do
  if [[ ! "$p" =~ ^[a-z0-9]+/[a-z0-9]+(/v?[0-9a-z]+)?$ ]]; then
    log_error "Invalid platform '$p' (expected os/arch[/variant], e.g. linux/arm64/v8)"
    exit 1
  fi
done

COMPOSE_FILE="./$STACK/compose.yaml"
if [[ ! -f "$COMPOSE_FILE" ]]; then
  log_error "Compose file not found: $COMPOSE_FILE"
  exit 1
fi

echo "🔎 Image platform manifest check: $STACK"
echo "   Target platforms: ${REQ_PLATFORMS[*]}"
print_separator

TEMP_ENV=$(mktemp)
trap 'rm -f "$TEMP_ENV"' EXIT
create_temp_env "$COMPOSE_FILE" "$TEMP_ENV"

# `docker compose config --images` emits one fully-resolved image ref per line.
IMAGES=()
while IFS= read -r line; do
  [[ -n "$line" ]] && IMAGES+=("$line")
done < <(docker compose --env-file "$TEMP_ENV" -f "$COMPOSE_FILE" config --images 2>/dev/null | sort -u)

if [[ ${#IMAGES[@]} -eq 0 ]]; then
  echo "ℹ️  No images resolved from $COMPOSE_FILE — nothing to check."
  exit 0
fi

# How many times to attempt a transient-looking inspect before giving up.
INSPECT_ATTEMPTS=3

# Definitive failures cannot succeed on retry: the credential is wrong or the
# manifest genuinely is not there. Anything else (timeouts, 5xx, connection
# resets, 429 rate-limits) is treated as transient and retried.
is_definitive_failure() {
  local msg="$1"
  grep -qiE '401 unauthorized|403 forbidden|unauthorized:|denied:|manifest unknown|name unknown|not found' <<< "$msg"
}

# Human-readable cause for the failure line, so a red check says *why*.
classify_failure() {
  local msg="$1"
  if grep -qiE '401 unauthorized|unauthorized:|403 forbidden|denied:' <<< "$msg"; then
    echo "registry auth rejected — check the registry login step and its 1Password credentials"
  elif grep -qiE 'manifest unknown|name unknown|not found' <<< "$msg"; then
    echo "manifest not found — the pinned digest does not exist in this registry"
  else
    echo "registry unreachable after $INSPECT_ATTEMPTS attempts"
  fi
}

# Returns 0 if a manifest entry matches the requested platform.
# Permissive match: an entry without a variant satisfies a request that
# includes a variant (e.g. an image publishing linux/arm64 satisfies a
# linux/arm64/v8 runtime — Docker treats these as compatible at pull time).
platform_present() {
  local index_json="$1" target="$2"
  local t_os t_arch t_variant
  t_os="${target%%/*}"
  local rest="${target#*/}"
  t_arch="${rest%%/*}"
  if [[ "$rest" == *"/"* ]]; then
    t_variant="${rest#*/}"
  else
    t_variant=""
  fi

  jq -e --arg os "$t_os" --arg arch "$t_arch" --arg variant "$t_variant" '
    (.manifests // [])
    | map(select(.platform.os == $os and .platform.architecture == $arch))
    | map(select(
        ($variant == "")
        or ((.platform.variant // "") == $variant)
        or ((.platform.variant // "") == "")
      ))
    | length > 0
  ' <<< "$index_json" > /dev/null
}

OVERALL_RC=0
CHECKED=0
SKIPPED=0

for ref in "${IMAGES[@]}"; do
  if [[ "$ref" != *"@sha256:"* ]]; then
    echo "↷  Skipping (no digest pin): $ref"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  echo ""
  echo "📦 $ref"

  # Retry before failing: a transient blip or momentary rate-limit should not
  # red-flag an otherwise good PR, but a persistent failure is real (bad
  # digest, deleted image, missing registry creds) and must gate.
  #
  # buildx exits 1 for every failure mode — auth, missing manifest, DNS — so
  # the exit code carries no signal and retries are gated on the message
  # instead. Definitive errors fail immediately; retrying them cannot change
  # the outcome and just burns wall-clock.
  raw=""
  inspect_ok=false
  for attempt in $(seq 1 "$INSPECT_ATTEMPTS"); do
    if raw=$(docker buildx imagetools inspect --raw "$ref" 2>&1); then
      inspect_ok=true
      break
    fi

    if is_definitive_failure "$raw"; then
      echo "   ↷ definitive error — not retrying"
      break
    fi

    if [[ "$attempt" -lt "$INSPECT_ATTEMPTS" ]]; then
      echo "   ↻ inspect attempt $attempt/$INSPECT_ATTEMPTS failed; retrying in $((attempt * 5))s"
      sleep "$((attempt * 5))"
    fi
  done

  if [[ "$inspect_ok" != "true" ]]; then
    log_error "   ✗ Unable to inspect: $(classify_failure "$raw")"
    echo "      $(head -n1 <<< "$raw")"
    OVERALL_RC=1
    CHECKED=$((CHECKED + 1))
    continue
  fi

  media_type=$(jq -r '.mediaType // empty' <<< "$raw" 2>/dev/null || echo "")
  has_manifests=$(jq -e 'has("manifests")' <<< "$raw" > /dev/null 2>&1 && echo "yes" || echo "no")

  if [[ "$has_manifests" != "yes" ]]; then
    echo "   ↷ Single-manifest image (mediaType=$media_type) — digest is platform-specific by construction; skipping."
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  child_count=$(jq '.manifests | length' <<< "$raw")
  echo "   index has $child_count child manifest(s) (mediaType=$media_type)"

  if [[ "$child_count" -eq 0 ]]; then
    log_error "   ✗ Index manifest published but children array is EMPTY — classic Hub publish race."
    log_error "     Re-run after upstream finishes publishing, or revert the bump."
    OVERALL_RC=1
    CHECKED=$((CHECKED + 1))
    continue
  fi

  image_failed=0
  for plat in "${REQ_PLATFORMS[@]}"; do
    if platform_present "$raw" "$plat"; then
      echo "   ✓ $plat"
    else
      log_error "   ✗ $plat NOT FOUND in manifest list"
      image_failed=1
    fi
  done

  if [[ "$image_failed" -eq 1 ]]; then
    echo "   Manifest summary:"
    jq -r '.manifests[] | "     - " + (.platform.os // "?") + "/" + (.platform.architecture // "?") + (if .platform.variant then "/" + .platform.variant else "" end)' <<< "$raw" | sort -u
    OVERALL_RC=1
  fi

  CHECKED=$((CHECKED + 1))
done

echo ""
print_separator
if [[ "$OVERALL_RC" -eq 0 ]]; then
  log_success "Image platform check PASSED ($CHECKED verified, $SKIPPED skipped)"
else
  log_error "Image platform check FAILED ($CHECKED checked, $SKIPPED skipped)"
  echo ""
  echo "🛠  If an image could not be inspected at all:"
  echo "      • auth rejected — check the registry login steps in compose-lint.yml"
  echo "        and that the 1Password service account can read those items."
  echo "      • digest not found — the pin references an image that no longer"
  echo "        exists; re-pin to a digest the registry actually serves."
  echo ""
  echo "    If an image was inspected but is missing a platform, a registry is"
  echo "    likely mid-publish (index pushed, per-platform children not yet):"
  echo "      • Wait and re-run — most public registries finish within an hour."
  echo "      • Revert the offending dependency bump."
  echo "      • Add 'minimumReleaseAge' to .github/renovate.json to delay future bumps."
fi

exit "$OVERALL_RC"
