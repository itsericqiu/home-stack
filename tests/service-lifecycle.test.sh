#!/usr/bin/env bash
set -euo pipefail

# Guard for macOS
if [[ "$(uname)" != "Darwin" ]]; then
  echo "skipping: requires macOS (launchctl/plutil)"
  exit 77 # 77 = skipped, so a runner can tell this apart from a pass
fi

# Additional guard: only run if explicitly allowed or in a known-safe environment
# Two independent conditions, because past this point the test bootstraps
# into the system domain and writes /Library/LaunchDaemons for real:
#   1. an explicit human opt-in, and
#   2. a marker asserting this host's launchd state is disposable.
# The marker is SET by the one Makefile target that runs on such a host, never
# sniffed from the ambient environment. Sniffing CI=true was wrong: that is set
# by unrelated tooling and by self-hosted runners, which are real machines.
if [[ "${HOME_STACK_TEST_ALLOW_SYSTEM_CHANGES:-}" != "1" ]]; then
  echo "skipping: Test 13 makes system-wide changes; runs only on a disposable host."
  exit 77 # 77 = skipped, not passed
fi
if [[ "${HOME_STACK_TEST_EPHEMERAL:-}" != "1" ]]; then
  # Loud, not exit 0: an opted-in run that silently skips is the failure mode
  # this whole effort exists to eliminate.
  echo "FAIL: Test 13 was opted in, but HOME_STACK_TEST_EPHEMERAL is not set." >&2
  echo "  This host's launchd state is not disposable; refusing to touch it." >&2
  exit 1
fi

# A marker can be exported by anyone -- including, as it turns out, by the
# author of these guards running a Makefile target by hand on a live
# workstation. This check cannot be satisfied by setting a variable: it looks
# for the thing actually being protected. It runs before HOME is staged, so
# $HOME here is still the operator's real home.
_home_stack_foreign_install() {
  local p base
  shopt -s nullglob
  for p in "$HOME"/Library/LaunchAgents/*.home-stack.*.plist \
           /Library/LaunchDaemons/*.home-stack.*.plist; do
    base="$(basename "$p")"
    case "$base" in
      test.e2e.*|test.flow.*|test.lifecycle.*) ;;
      *) printf '%s' "$p"; shopt -u nullglob; return 0 ;;
    esac
  done
  # A generated Caddyfile means this working tree belongs to a running stack;
  # this test's staged bundle is independent, but a live-looking working tree
  # is still a sign this host is not the disposable box these tests require.
  if [[ -f "$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/portable/home-stack/Caddyfile" ]]; then
    printf '%s' "portable/home-stack/Caddyfile (live generated config)"
    shopt -u nullglob; return 0
  fi
  shopt -u nullglob
  return 1
}
if _found="$(_home_stack_foreign_install)"; then
  echo "FAIL: refusing to run -- this host carries a live home-stack install." >&2
  echo "  found: $_found" >&2
  echo "  These tests install plists, bootstrap system jobs, and rewrite the" >&2
  echo "  bundle. They must only run where losing that state costs nothing." >&2
  exit 1
fi

# Sanitize HOME_STACK_* vars that may leak from the user's environment.
# The two test-control flags are exempt: they are this harness's own input,
# not leaked operator config, and unsetting them here would undo the guard
# above after it had already admitted the run.
while IFS='=' read -r key _; do
  case "$key" in
    HOME_STACK_TEST_ALLOW_SYSTEM_CHANGES|HOME_STACK_TEST_EPHEMERAL) ;;
    HOME_STACK_*|CLOUDFLARE_API_TOKEN) unset "$key" ;;
  esac
done < <(env)

ROOT_DIR="$(cd -- "$(dirname "$0")/.." && pwd)"
. "$ROOT_DIR/tests/lib/stage.sh"

echo "=== Test 13: Service lifecycle round-trip ==="

# Setup a fully isolated staging area: a COPY of the repo's portable/,
# profiles/, and templates/ trees, so this test never reads or writes
# anything under $ROOT_DIR. Everything it touches -- the built admin binary,
# the stubbed reload-caddy.sh, the generated Caddyfile/plists, the profile it
# creates -- lives under $STAGE and is destroyed with it. Only real
# launchd/launchctl operations (gated above by the disposable-host opt-in,
# same as every other Darwin test) reach outside the stage.
STAGE="$(mktemp -d)"
ORIG_HOME="$HOME"
REPO="$(home_stack_stage_repo "$STAGE" "$ROOT_DIR")"

HS_SCRIPT="$REPO/portable/home-stack/scripts/hs"
INSTALL_SCRIPT="$REPO/portable/home-stack/scripts/install-launchd.sh"
UNINSTALL_SCRIPT="$REPO/portable/home-stack/scripts/uninstall-launchd.sh"

export HOME="$STAGE"
# Deliberately NOT setting HOME_STACK_REPO_ROOT/HOME_STACK_BUNDLE_DIR: common.sh
# (sourced by the staged $HS_SCRIPT) derives both from the invoked script's own
# location, and since portable/, profiles/, and templates/ were copied in one
# piece preserving their relative layout, that derivation lands on $REPO --
# the staged bundle, never $ROOT_DIR.
export HOME_STACK_OWNER_HOME="$STAGE"
export HOME_STACK_PROFILE="test-lifecycle"

mkdir -p "$HOME/Library/LaunchAgents"

cleanup() {
  # Preserve the real exit status: a failing command in here would otherwise
  # turn a passing test red (or mask why it went red).
  local rc=$?
  echo "Cleaning up..."
  {
    if [[ -f "$HS_SCRIPT" ]]; then
      HOME_STACK_PROFILE="test-lifecycle" "$UNINSTALL_SCRIPT" --unload || true
    fi
    export HOME="$ORIG_HOME"
    # HOME is staged here, so Go drops a read-only module cache under it.
    chmod -R u+w "$STAGE"
    rm -rf "$STAGE"
  } || true
  exit "$rc"
}
trap cleanup EXIT

# 1. hs init test-lifecycle
"$HS_SCRIPT" init test-lifecycle

# Configure profile
PROFILE_ENV="$REPO/profiles/test-lifecycle/home-stack.env"
perl -pi -e 's/HOME_STACK_IDENTIFIER_PREFIX=.*/HOME_STACK_IDENTIFIER_PREFIX=test.lifecycle/' "$PROFILE_ENV"
perl -pi -e 's/HOME_STACK_PARENT_DOMAIN=.*/HOME_STACK_PARENT_DOMAIN=test.lifecycle.test/' "$PROFILE_ENV"
perl -pi -e 's/HOME_STACK_TAILNET_IP=.*/HOME_STACK_TAILNET_IP=127.0.0.1/' "$PROFILE_ENV"
perl -pi -e 's/HOME_STACK_ACME_EMAIL=.*/HOME_STACK_ACME_EMAIL=test\@lifecycle.test/' "$PROFILE_ENV"
perl -pi -e "s|HOME_STACK_OWNER_HOME=.*|HOME_STACK_OWNER_HOME=$STAGE|" "$PROFILE_ENV"
perl -pi -e 's/HOME_STACK_ADMIN_USERNAME=.*/HOME_STACK_ADMIN_USERNAME=admin/' "$PROFILE_ENV"

# touch env.local
mkdir -p "$HOME/.config/home-stack"
cat > "$HOME/.config/home-stack/env.local" <<EOF
HOME_STACK_ADMIN_PASSWORD=testpassword
CLOUDFLARE_API_TOKEN=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
chmod 600 "$HOME/.config/home-stack/env.local"

# Add opencode/openchamber/logrotate to services.yaml so install-launchd has all plists.
cat >> "$REPO/profiles/test-lifecycle/services.yaml" <<'YAML'

  opencode:
    display_name: "OpenCode"
    kind: "app"
    type: "proxy"
    upstream: "127.0.0.1:31496"
  openchamber:
    display_name: "OpenChamber"
    kind: "app"
    type: "proxy"
    upstream: "127.0.0.1:31497"
  logrotate:
    display_name: "Log Rotate"
    kind: "scheduled"
    type: "task"
YAML

# hs sync (admin was built and reload-caddy.sh stubbed by
# home_stack_stage_repo above)

"$HS_SCRIPT" sync

# install-launchd.sh --load (precondition) -- staged script
"$INSTALL_SCRIPT" --load

# 2. Capture admin PID
echo "Waiting for admin to start..."
MAX_RETRIES=20
COUNT=0
LABEL="test.lifecycle.home-stack.admin"
OLD_PID=""
GUI_DOMAIN_DBG="gui/$(id -u)"

while [[ -z "$OLD_PID" ]]; do
  OLD_PID=$(launchctl list | awk -v l="$LABEL" '$3 == l {print $1}')
  if [[ "$OLD_PID" == "-" || -z "$OLD_PID" ]]; then
    OLD_PID=""
    sleep 0.5
    COUNT=$((COUNT + 1))
    if [[ $COUNT -ge $MAX_RETRIES ]]; then
      echo "Admin failed to start (no PID). launchctl list:"
      launchctl list | grep "$LABEL" || true
      echo "--- launchctl print $GUI_DOMAIN_DBG/$LABEL ---"
      launchctl print "$GUI_DOMAIN_DBG/$LABEL" 2>&1 | head -40 || true
      echo "--- admin logs under $HOME/.config/home-stack/logs ---"
      tail -n 40 "$HOME/.config/home-stack/logs/"*admin* 2>/dev/null || echo "(no admin log files)"
      exit 1
    fi
  fi
done
echo "Admin started with PID $OLD_PID"

# 3. hs restart admin -- staged script
"$HS_SCRIPT" restart admin

# 4. Wait for new PID
echo "Waiting for new admin PID..."
COUNT=0
NEW_PID=""
while [[ -z "$NEW_PID" || "$NEW_PID" == "$OLD_PID" ]]; do
  NEW_PID=$(launchctl list | awk -v l="$LABEL" '$3 == l {print $1}')
  if [[ "$NEW_PID" == "-" || -z "$NEW_PID" ]]; then
    NEW_PID=""
  fi
  sleep 0.5
  COUNT=$((COUNT + 1))
  if [[ $COUNT -ge $MAX_RETRIES ]]; then
    echo "Admin failed to restart (no new PID). launchctl list:"
    launchctl list | grep "$LABEL" || true
    exit 1
  fi
done
echo "Admin restarted with PID $NEW_PID"

# 5. Assert new PID differs from old
if [[ "$NEW_PID" == "$OLD_PID" ]]; then
  echo "FAIL: PID did not change after restart"
  exit 1
fi

# 6. Assert HTTP 401 from http://127.0.0.1:31510/api/health (admin is up, requires auth)
echo "Checking admin HTTP health..."
MAX_RETRIES=20
COUNT=0
while true; do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
    "http://127.0.0.1:31510/api/health" || echo "000")
  if [[ "$STATUS" == "401" ]]; then
    echo "Admin HTTP is UP (401 Unauthorized as expected)"
    break
  fi
  sleep 0.5
  COUNT=$((COUNT + 1))
  if [[ $COUNT -ge $MAX_RETRIES ]]; then
    echo "Admin HTTP failed to respond with 401. Got: $STATUS"
    exit 1
  fi
done

# 7. Assert no orphan processes via pgrep -f home-stack-admin | wc -l == 1
PROC_COUNT=$( { pgrep -f "home-stack-admin" || true; } | wc -l | tr -d ' ')
if [[ "$PROC_COUNT" != "1" ]]; then
  echo "FAIL: expected exactly 1 home-stack-admin process, found $PROC_COUNT"
  pgrep -fl "home-stack-admin" || echo "  (none running -- admin died)"
  exit 1
fi

echo "Test 13 passed"
