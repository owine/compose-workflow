#!/usr/bin/env bash
# Build a markdown PR comment body from the deploy workflow's notify-job outputs.
# All inputs are read from environment variables (see header comment for full list).
set -euo pipefail

# Default all expected env vars to empty so set -u doesn't abort if the caller
# omits one.
: "${REPO_NAME:=}"
: "${TARGET_REF:=}"
: "${REPOSITORY:=}"
: "${RUN_ID:=}"
: "${RUN_NUMBER:=}"
: "${COMMIT_SUBJECT:=}"
: "${OVERALL:=}"
: "${TITLE_SUFFIX:=}"
: "${DESCRIPTION:=}"
: "${PIPELINE:=}"
: "${REMOVED_LINE:=}"

# Sanitize COMMIT_SUBJECT — it's user-controlled (PR commit message).
# Strip newlines/CR, truncate to 120 chars, replace backticks (which would break
# the inline-code wrapping downstream) with single quotes.
COMMIT_SUBJECT="${COMMIT_SUBJECT%%$'\n'*}"
COMMIT_SUBJECT="${COMMIT_SUBJECT%%$'\r'*}"
COMMIT_SUBJECT="${COMMIT_SUBJECT:0:120}"
COMMIT_SUBJECT="${COMMIT_SUBJECT//\`/\'}"

short_sha="${TARGET_REF:0:7}"

# Status emoji from OVERALL (which mirrors the Discord title states).
case "$OVERALL" in
  success)     status_emoji="✅" ;;
  rolled-back) status_emoji="⚠️" ;;
  *)           status_emoji="❌" ;;
esac

# Header.
printf '<!-- compose-deploy-result:%s -->\n' "$REPO_NAME"
printf '## 🚀 %s deploy: %s %s\n\n' "$REPO_NAME" "$status_emoji" "$TITLE_SUFFIX"

# Commit + Run lines. Subject wrapped in inline code to neutralize markdown.
# shellcheck disable=SC2016
printf '**Commit:** [`%s`](https://github.com/%s/commit/%s) `%s`\n' \
  "$short_sha" "$REPOSITORY" "$TARGET_REF" "$COMMIT_SUBJECT"
printf '**Run:** [#%s](https://github.com/%s/actions/runs/%s)\n\n' \
  "$RUN_NUMBER" "$REPOSITORY" "$RUN_ID"

# Description (rich status sentence).
if [[ -n "$DESCRIPTION" ]]; then
  printf '%s\n\n' "$DESCRIPTION"
fi

# Removed-stacks line (only when present).
if [[ -n "$REMOVED_LINE" ]]; then
  printf '%s\n\n' "$REMOVED_LINE"
fi

# Pipeline pills — collapsed on success, raw on any failure.
if [[ -n "$PIPELINE" ]]; then
  if [[ "$OVERALL" == "success" ]]; then
    cat <<EOF
<details><summary>Pipeline</summary>

$PIPELINE

</details>
EOF
  else
    printf '**Pipeline:** %s\n' "$PIPELINE"
  fi
fi
