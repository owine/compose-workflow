#!/usr/bin/env bash
# Build a markdown PR comment body from deploy job outputs.
# All inputs are read from environment variables (see header comment for full list).
set -euo pipefail

# Default all expected env vars to empty so set -u doesn't abort if the caller
# omits one. Numeric vars already use ${VAR:-0} at their references.
: "${REPO_NAME:=}"
: "${TARGET_REF:=}"
: "${REPOSITORY:=}"
: "${RUN_ID:=}"
: "${RUN_NUMBER:=}"
: "${COMMIT_SUBJECT:=}"
: "${DEPLOY_STATUS:=}"
: "${HEALTH_STATUS:=}"
: "${CLEANUP_STATUS:=}"
: "${ROLLBACK_STATUS:=}"
: "${ROLLBACK_HEALTH_STATUS:=}"
: "${HEALTHY_STACKS:=}"
: "${DEGRADED_STACKS:=}"
: "${FAILED_STACKS:=}"
: "${ROLLBACK_HEALTHY_STACKS:=}"
: "${ROLLBACK_DEGRADED_STACKS:=}"
: "${ROLLBACK_FAILED_STACKS:=}"

# Sanitize COMMIT_SUBJECT — it's user-controlled (PR commit message).
# Strip newlines and any leading/trailing whitespace, truncate to 120 chars.
# Rendered as inline code (backticks) downstream to neutralize markdown.
COMMIT_SUBJECT="${COMMIT_SUBJECT%%$'\n'*}"
COMMIT_SUBJECT="${COMMIT_SUBJECT%%$'\r'*}"
COMMIT_SUBJECT="${COMMIT_SUBJECT:0:120}"
COMMIT_SUBJECT="${COMMIT_SUBJECT//\`/\'}"

short_sha="${TARGET_REF:0:7}"

# Determine outcome: deployed | rolled-back | failed
if [[ "$DEPLOY_STATUS" == "success" && "$HEALTH_STATUS" == "success" ]]; then
  outcome="deployed"
  status_emoji="✅"
  status_word="Deployed"
elif [[ "$ROLLBACK_STATUS" == "success" ]]; then
  outcome="rolled-back"
  status_emoji="⚠️"
  status_word="Rolled back"
else
  outcome="failed"
  status_emoji="❌"
  status_word="Failed"
fi

# Format a stack-bucket value, falling back to em-dash if empty.
fmt_bucket() {
  local v="$1"
  if [[ -z "$v" ]]; then
    printf -- "—"
  else
    printf "%s" "$v"
  fi
}

# Render a stack-status table.
render_stack_table() {
  local title="$1" healthy="$2" degraded="$3" failed="$4"
  cat <<EOF
**$title**

| Status | Stacks |
|--------|--------|
| ✅ Healthy | $(fmt_bucket "$healthy") |
| ⚠️ Degraded | $(fmt_bucket "$degraded") |
| ❌ Failed | $(fmt_bucket "$failed") |
EOF
}

# Render the pipeline-pills line.
render_pipeline_line() {
  local deploy_pill health_pill cleanup_pill
  case "$DEPLOY_STATUS" in success) deploy_pill="✅" ;; skipped) deploy_pill="⏭️" ;; *) deploy_pill="❌" ;; esac
  case "$HEALTH_STATUS" in success) health_pill="✅" ;; skipped) health_pill="⏭️" ;; *) health_pill="❌" ;; esac
  case "$CLEANUP_STATUS" in success) cleanup_pill="✅" ;; skipped) cleanup_pill="⏭️" ;; *) cleanup_pill="❌" ;; esac

  local line="$deploy_pill Deploy → $health_pill Health → $cleanup_pill Cleanup"
  if [[ "$ROLLBACK_STATUS" != "skipped" && -n "$ROLLBACK_STATUS" ]]; then
    local rb_pill
    case "$ROLLBACK_STATUS" in success) rb_pill="✅" ;; *) rb_pill="❌" ;; esac
    line+=" → $rb_pill Rollback"
    case "$ROLLBACK_HEALTH_STATUS" in
      success) line+=" → ✅ Verify" ;;
      failure) line+=" → ❌ Verify" ;;
    esac
  fi
  printf "%s" "$line"
}

# Begin output.
printf '<!-- compose-deploy-result:%s -->\n' "$REPO_NAME"
printf '## 🚀 %s deploy: %s %s\n\n' "$REPO_NAME" "$status_emoji" "$status_word"
# shellcheck disable=SC2016 # backticks in markdown link, not shell expansion
printf '**Commit:** [`%s`](https://github.com/%s/commit/%s) `%s`\n' \
  "$short_sha" "$REPOSITORY" "$TARGET_REF" "$COMMIT_SUBJECT"
printf '**Run:** [#%s](https://github.com/%s/actions/runs/%s)\n' \
  "$RUN_NUMBER" "$REPOSITORY" "$RUN_ID"

# Health line — use rollback values if rolled back.
if [[ "$outcome" == "rolled-back" ]]; then
  printf '**Health (rollback):** 🟢 %s/%s services (%s%%)\n\n' \
    "${ROLLBACK_RUNNING_CONTAINERS:-0}" "${ROLLBACK_TOTAL_CONTAINERS:-0}" "${ROLLBACK_SUCCESS_RATE:-0}"
else
  printf '**Health:** 🟢 %s/%s services (%s%%)\n\n' \
    "${RUNNING_CONTAINERS:-0}" "${TOTAL_CONTAINERS:-0}" "${SUCCESS_RATE:-0}"
fi

# Stack table(s).
if [[ "$outcome" == "rolled-back" ]]; then
  if [[ -n "$HEALTHY_STACKS$DEGRADED_STACKS$FAILED_STACKS" ]]; then
    render_stack_table "Stack Status (failed deploy)" "$HEALTHY_STACKS" "$DEGRADED_STACKS" "$FAILED_STACKS"
    printf '\n\n'
  fi
  render_stack_table "Rollback Stack Status" \
    "$ROLLBACK_HEALTHY_STACKS" "$ROLLBACK_DEGRADED_STACKS" "$ROLLBACK_FAILED_STACKS"
  printf '\n\n'
elif [[ -n "$HEALTHY_STACKS$DEGRADED_STACKS$FAILED_STACKS" ]]; then
  render_stack_table "Stack Status" "$HEALTHY_STACKS" "$DEGRADED_STACKS" "$FAILED_STACKS"
  printf '\n\n'
fi

# Pipeline pills — collapsed on success, raw on any failure.
pipeline_line=$(render_pipeline_line)
if [[ "$outcome" == "deployed" ]]; then
  cat <<EOF
<details><summary>Pipeline</summary>

$pipeline_line

</details>
EOF
else
  printf '**Pipeline:** %s\n' "$pipeline_line"
fi
