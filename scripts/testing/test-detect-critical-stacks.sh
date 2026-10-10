#!/usr/bin/env bash
# Unit tests for scripts/deployment/detect-critical-stacks.sh
# Builds throwaway stack dirs with a single compose.yaml each and asserts the
# emitted critical_stacks JSON. No git repos, no docker.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DETECT="$REPO_ROOT/scripts/deployment/detect-critical-stacks.sh"

TMPROOT=$(mktemp -d -t detect-critical-tests.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0
FAIL=0
FAILURES=()

# make_stack <name> <labels-block>
# Writes $TMPROOT/repo/<name>/compose.yaml with one service carrying the
# given (already indented) labels block.
make_stack() {
  local name="$1" labels="$2"
  mkdir -p "$TMPROOT/repo/$name"
  cat > "$TMPROOT/repo/$name/compose.yaml" <<EOF
services:
  app:
    image: busybox:latest
    restart: unless-stopped
    labels:
$labels
EOF
}

# expect_critical <name> <expected_json> <stack...>
# Runs the detector over the given stacks and asserts BOTH the GITHUB_OUTPUT
# critical_stacks value and rc=0.
expect_critical() {
  local name="$1" expected="$2"
  shift 2
  local out actual rc=0
  out=$(mktemp "$TMPROOT/out.XXXXXX")
  GITHUB_OUTPUT="$out" "$DETECT" --stacks "$*" --repo-dir "$TMPROOT/repo" >/dev/null 2>&1 || rc=$?
  actual=$(grep '^critical_stacks=' "$out" 2>/dev/null | cut -d= -f2- || echo "<none>")
  if [[ "$actual" == "$expected" && "$rc" == "0" ]]; then
    PASS=$((PASS + 1))
    echo "  ✅ $name"
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("$name: expected '$expected' rc=0, got '$actual' rc=$rc")
    echo "  ❌ $name: expected '$expected' rc=0, got '$actual' rc=$rc"
  fi
}

# --- com.compose.tier: infrastructure -------------------------------------
make_stack tier-unquoted      '      com.compose.tier: infrastructure'
make_stack tier-double        '      com.compose.tier: "infrastructure"'
make_stack tier-single        "      com.compose.tier: 'infrastructure'"
make_stack tier-trailing-ws   '      com.compose.tier:   "infrastructure"   '
make_stack tier-trailing-cmt  '      com.compose.tier: "infrastructure"  # gate this stack'
make_stack tier-crlf          $'      com.compose.tier: "infrastructure"\r'
make_stack tier-list          '      - com.compose.tier=infrastructure'
make_stack tier-list-quoted   '      - "com.compose.tier=infrastructure"'
make_stack tier-quoted-key    '      "com.compose.tier": "infrastructure"'
make_stack tier-commented     '      # com.compose.tier: "infrastructure"'
make_stack tier-commented-ws  '    #   com.compose.tier: infrastructure'
make_stack tier-list-cmt      '      # - com.compose.tier=infrastructure'
make_stack tier-other         '      com.compose.tier: "application"'
make_stack tier-prefix        '      com.compose.tier: "infrastructure-lite"'
make_stack tier-other-key     '      com.compose.tierx: "infrastructure"'
# shellcheck disable=SC2016  # literal backticks, not an expansion
make_stack tier-value-in-key  '      traefik.http.routers.infrastructure.rule: "Host(`x`)"'
make_stack plain              '      traefik.enable: "true"'

# --- com.compose.critical: true -------------------------------------------
make_stack crit-unquoted      '      com.compose.critical: true'
make_stack crit-double        '      com.compose.critical: "true"'
make_stack crit-single        "      com.compose.critical: 'true'"
make_stack crit-list          '      - com.compose.critical=true'
make_stack crit-false         '      com.compose.critical: "false"'
make_stack crit-commented     '      # com.compose.critical: "true"'

echo "== detect-critical-stacks: com.compose.tier =="
expect_critical "unquoted value"                 '["tier-unquoted"]'     tier-unquoted
expect_critical "double-quoted value (house style)" '["tier-double"]'    tier-double
expect_critical "single-quoted value"            '["tier-single"]'       tier-single
expect_critical "extra whitespace"               '["tier-trailing-ws"]'  tier-trailing-ws
expect_critical "trailing comment"               '["tier-trailing-cmt"]' tier-trailing-cmt
expect_critical "CRLF line ending"               '["tier-crlf"]'         tier-crlf
expect_critical "list form"                      '["tier-list"]'         tier-list
expect_critical "list form, quoted item"         '["tier-list-quoted"]'  tier-list-quoted
expect_critical "quoted key"                     '["tier-quoted-key"]'   tier-quoted-key
expect_critical "commented out does NOT match"   '[]'                    tier-commented
expect_critical "commented out (indented) does NOT match" '[]'           tier-commented-ws
expect_critical "commented list form does NOT match" '[]'                tier-list-cmt
expect_critical "other tier value does NOT match" '[]'                   tier-other
expect_critical "value prefix does NOT match"    '[]'                    tier-prefix
expect_critical "longer key does NOT match"      '[]'                    tier-other-key
expect_critical "value word in other key does NOT match" '[]'            tier-value-in-key
expect_critical "no tier label"                  '[]'                    plain

echo "== detect-critical-stacks: com.compose.critical =="
expect_critical "critical unquoted"              '["crit-unquoted"]'     crit-unquoted
expect_critical "critical double-quoted"         '["crit-double"]'       crit-double
expect_critical "critical single-quoted"         '["crit-single"]'       crit-single
expect_critical "critical list form"             '["crit-list"]'         crit-list
expect_critical "critical false does NOT match"  '[]'                    crit-false
expect_critical "critical commented does NOT match" '[]'                 crit-commented

echo "== detect-critical-stacks: aggregation =="
expect_critical "mixed set keeps order, drops non-critical" \
  '["tier-double","crit-single"]' plain tier-double tier-commented crit-single tier-other
expect_critical "missing compose file is skipped" \
  '["tier-double"]' does-not-exist tier-double

echo
echo "Passed: $PASS  Failed: $FAIL"
if [[ $FAIL -gt 0 ]]; then
  printf '  - %s\n' "${FAILURES[@]}"
  exit 1
fi
