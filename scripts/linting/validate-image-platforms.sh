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
#   - imagetools inspect failures (auth/network) warn and skip the image
#     rather than failing — preserves utility for private registries
#     without requiring the lint job to authenticate.
#   - Missing target platform in a fetched index → exit 1.
#
# Exit codes:
#   0 - All checked images publish the requested platform(s)
#   1 - At least one image is missing a requested platform manifest
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

  raw=""
  if ! raw=$(docker buildx imagetools inspect --raw "$ref" 2>&1); then
    log_warning "   ⚠ Unable to inspect (auth/network/registry issue) — skipping."
    echo "      $(head -n1 <<< "$raw")"
    SKIPPED=$((SKIPPED + 1))
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
  echo "🛠  This usually means a registry is mid-publish (manifest index pushed,"
  echo "    per-platform children not yet pushed). Options:"
  echo "      • Wait and re-run — most public registries finish within an hour."
  echo "      • Revert the offending dependency bump."
  echo "      • Add 'minimumReleaseAge' to .github/renovate.json to delay future bumps."
fi

exit "$OVERALL_RC"
