#!/usr/bin/env bash
# Unit tests for scripts/deployment/lib/compose-project.sh
# A fake `docker` on PATH answers `ps -a --filter label=K=V --format '{{.Label "X"}}'`
# from a table of containers and logs `compose -p` calls. No real docker.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$REPO_ROOT/scripts/deployment/lib/compose-project.sh"

TMPROOT=$(mktemp -d -t compose-project-tests.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

# Containers, one per line: <project>|<working_dir>
export FAKE_CONTAINERS="$TMPROOT/containers"
export FAKE_COMPOSE_LOG="$TMPROOT/compose.log"
mkdir -p "$TMPROOT/bin"
cat > "$TMPROOT/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "compose" ]]; then
  shift
  echo "$PWD $*" >> "$FAKE_COMPOSE_LOG"
  exit "${FAKE_COMPOSE_RC:-0}"
fi
[[ "$1 $2" == "ps -a" ]] || { echo "fake docker: unexpected $*" >&2; exit 2; }
filter="" format=""
shift 2
while [[ $# -gt 0 ]]; do
  case "$1" in
    --filter) filter="${2#label=}"; shift 2 ;;
    --format) format="$2"; shift 2 ;;
    *) echo "fake docker: unexpected arg $1" >&2; exit 2 ;;
  esac
done
key="${filter%%=*}" val="${filter#*=}"
while IFS='|' read -r proj wd; do
  [[ -n "$proj" ]] || continue
  case "$key" in
    com.docker.compose.project) [[ "$proj" == "$val" ]] || continue ;;
    com.docker.compose.project.working_dir) [[ "$wd" == "$val" ]] || continue ;;
  esac
  case "$format" in
    *'"com.docker.compose.project"'*) echo "$proj" ;;
    *'"com.docker.compose.project.working_dir"'*) echo "$wd" ;;
  esac
done < "$FAKE_CONTAINERS"
EOF
chmod +x "$TMPROOT/bin/docker"
export PATH="$TMPROOT/bin:$PATH"
export LIVE_REPO_PATH="/opt/compose/"   # trailing slash on purpose

# shellcheck source=SCRIPTDIR/../deployment/lib/compose-project.sh
source "$LIB"

PASS=0
FAIL=0
FAILURES=()

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1))
    echo "  ✅ $name"
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("$name")
    echo "  ❌ $name"
    echo "     expected: $(printf '%q' "$expected")"
    echo "     actual:   $(printf '%q' "$actual")"
  fi
}

containers() { printf '%s\n' "$@" > "$FAKE_CONTAINERS"; }

# expect_projects <name> <stack> <expected stdout> <expected-warning: none|stale|foreign>
expect_projects() {
  local name="$1" stack="$2" expected="$3" warn="$4" out err got_warn=none
  err="$TMPROOT/err"
  out=$(compose_projects "$stack" 2>"$err")
  grep -q '::warning::.*created from' "$err" && got_warn=stale
  grep -q '::warning::.*leaving it alone' "$err" && got_warn=foreign
  check "$name" "$expected|$warn" "$out|$got_warn"
}

echo "compose_normalize_name"
check "lowercases and drops dots" "myapp" "$(compose_normalize_name My.App)"
check "strips leading _ and -" "app_1-x" "$(compose_normalize_name _-App_1-x)"
check "all-invalid -> empty" "" "$(compose_normalize_name ...)"

echo "compose_projects"
containers "traefik|/opt/compose/traefik" "traefik|/opt/compose/traefik"
expect_projects "project from working_dir" traefik "traefik" none

containers "customname|/opt/compose/app"
expect_projects "top-level name: resolved" app "customname" none

containers "myapp|/opt/compose/My.App"
expect_projects "normalised dir name resolved" My.App "myapp" none

containers "app|/opt/compose/app" "app-old|/opt/compose/app"
expect_projects "every project in the dir" app "app"$'\n'"app-old" none

containers "other|/opt/compose/other"
expect_projects "no containers -> nothing, no warning" app "" none

containers "traefik|/home/admin/compose/traefik" "traefik|/home/admin/compose/traefik/"
expect_projects "stale working_dir of same stack -> used, warned" traefik "traefik" stale

containers "myapp|/home/admin/compose/My.App"
expect_projects "stale + normalised name -> used, warned" My.App "myapp" stale

containers "app|/srv/elsewhere"
expect_projects "same-named project elsewhere -> skipped, warned" app "" foreign

containers "app|/home/admin/compose/app" "app|/srv/elsewhere"
expect_projects "mixed stale + foreign dirs -> skipped" app "" foreign

containers "app|/opt/compose/app" "app|/srv/elsewhere"
expect_projects "dir match wins; others ignored" app "app" none

containers "x|/opt/compose/x"
expect_projects "all-invalid stack name -> nothing" ... "" none

echo "compose_p"
containers "app|/opt/compose/app" "app-old|/opt/compose/app"
: > "$FAKE_COMPOSE_LOG"
rc=0; compose_p app down --remove-orphans 2>/dev/null || rc=$?
check "runs per project from /" "/ -p app down --remove-orphans"$'\n'"/ -p app-old down --remove-orphans|0" \
  "$(cat "$FAKE_COMPOSE_LOG")|$rc"

containers "other|/opt/compose/other"
: > "$FAKE_COMPOSE_LOG"
rc=0; compose_p app down 2>/dev/null || rc=$?
check "no project -> no call, rc 0" "|0" "$(cat "$FAKE_COMPOSE_LOG")|$rc"

containers "app|/opt/compose/app"
rc=0; FAKE_COMPOSE_RC=3 compose_p app down 2>/dev/null || rc=$?
check "propagates compose failure" "3" "$rc"

echo ""
echo "Passed: $PASS  Failed: $FAIL"
if [[ $FAIL -gt 0 ]]; then
  printf '  - %s\n' "${FAILURES[@]}"
  exit 1
fi
