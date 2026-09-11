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
  echo "skipping: Test 14 makes system-wide changes; runs only on a disposable host."
  exit 77 # 77 = skipped, not passed
fi
if [[ "${HOME_STACK_TEST_EPHEMERAL:-}" != "1" ]]; then
  # Loud, not exit 0: an opted-in run that silently skips is the failure mode
  # this whole effort exists to eliminate.
  echo "FAIL: Test 14 was opted in, but HOME_STACK_TEST_EPHEMERAL is not set." >&2
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

echo "=== Test 14: install-launchd.sh end-to-end ==="

# Setup a fully isolated staging area: a COPY of the repo's portable/,
# profiles/, and templates/ trees, so this test never reads or writes
# anything under $ROOT_DIR. Everything it touches -- the built admin binary,
# the stubbed reload-caddy.sh and caddy-cloudflare, the generated
# Caddyfile/plists, the profile it creates -- lives under $STAGE and is
# destroyed with it. Only real launchd/launchctl operations (gated above by
# the disposable-host opt-in, same as every other Darwin test) reach outside
# the stage.
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
export HOME_STACK_PROFILE="test-e2e"

mkdir -p "$HOME/Library/LaunchAgents"

cleanup() {
  # Preserve the real exit status: a failing command in here would otherwise
  # turn a passing test red (or, worse, mask why it went red).
  local rc=$?
  echo "Cleaning up..."
  {
    # Boot the daemon out BEFORE the stage (and the binary it execs) is
    # removed, or launchd respawn-thrashes a job whose program has vanished.
    if [[ -f "$HS_SCRIPT" ]]; then
      HOME_STACK_PROFILE="test-e2e" "$UNINSTALL_SCRIPT" --unload || true
    fi
    export HOME="$ORIG_HOME"
    # HOME is staged here, so Go drops a read-only module cache under it.
    chmod -R u+w "$STAGE"
    rm -rf "$STAGE"
  } || true
  exit "$rc"
}
trap cleanup EXIT

# 1. Bootstrap a fresh profile via hs init
"$HS_SCRIPT" init test-e2e

# 2. Fill mandatory profile values; touch env.local
PROFILE_ENV="$REPO/profiles/test-e2e/home-stack.env"
perl -pi -e 's/HOME_STACK_IDENTIFIER_PREFIX=.*/HOME_STACK_IDENTIFIER_PREFIX=test.e2e/' "$PROFILE_ENV"
perl -pi -e 's/HOME_STACK_PARENT_DOMAIN=.*/HOME_STACK_PARENT_DOMAIN=test.e2e.test/' "$PROFILE_ENV"
perl -pi -e 's/HOME_STACK_TAILNET_IP=.*/HOME_STACK_TAILNET_IP=127.0.0.1/' "$PROFILE_ENV"
perl -pi -e 's/HOME_STACK_ACME_EMAIL=.*/HOME_STACK_ACME_EMAIL=test\@e2e.test/' "$PROFILE_ENV"
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
cat >> "$REPO/profiles/test-e2e/services.yaml" <<'YAML'

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

# 3. hs sync (admin was built and reload-caddy.sh stubbed by
# home_stack_stage_repo above)
"$HS_SCRIPT" sync

# The Caddy LaunchDaemon execs bundle/bin/caddy-cloudflare, which a CI runner
# has no way to provide (it is gitignored and built locally via xcaddy) and
# which this test's stage never receives (excluded above). Stub it so the
# daemon bootstraps for real and stays resident: this test is about the
# launchd install/bootstrap/unload wiring, not about Caddy serving traffic.
CADDY_BIN_PATH="$REPO/portable/home-stack/bin/caddy-cloudflare"
mkdir -p "$(dirname "$CADDY_BIN_PATH")"
cat > "$CADDY_BIN_PATH" <<'STUB'
#!/usr/bin/env bash
# home-stack TEST STUB -- not Caddy. Stays resident so launchd keeps the
# daemon loaded. If you are reading this in a real install, ingress is down.
echo "HOME-STACK TEST STUB: this is not Caddy; ingress is NOT being served" >&2
exec sleep 3600
STUB
chmod +x "$CADDY_BIN_PATH"

# 4. install-launchd.sh (no --load) -- staged script
"$INSTALL_SCRIPT"

# assert plists copied to $HOME/Library/LaunchAgents
PREFIX="test.e2e"
for svc in opencode openchamber logrotate admin; do
  if [[ ! -f "$HOME/Library/LaunchAgents/$PREFIX.home-stack.$svc.plist" ]]; then
    echo "FAIL: Plist for $svc not found in Library/LaunchAgents"
    exit 1
  fi
done

# 5. install-launchd.sh --load -- staged script
"$INSTALL_SCRIPT" --load

# 6. Wait ≤10s; assert all 5 services appear in launchctl list
echo "Waiting for services to load..."
MAX_RETRIES=20
COUNT=0
while true; do
  ALL_FOUND=1
  for svc in opencode openchamber logrotate admin; do
    if ! launchctl list | grep -q "$PREFIX.home-stack.$svc"; then
      ALL_FOUND=0
      break
    fi
  done

  # Caddy is a system daemon and is always real here (sudo is never mocked).
  if ! sudo launchctl list | grep -q "$PREFIX.home-stack.caddy"; then
    ALL_FOUND=0
  fi

  if [[ $ALL_FOUND -eq 1 ]]; then
    echo "All services found in launchctl"
    break
  fi

  sleep 0.5
  COUNT=$((COUNT + 1))
  if [[ $COUNT -ge $MAX_RETRIES ]]; then
    echo "Timeout waiting for services to appear in launchctl"
    launchctl list | grep "$PREFIX" || true
    exit 1
  fi
done

# 7. uninstall-launchd.sh --unload
"$UNINSTALL_SCRIPT" --unload

# assert all 5 disappear
for svc in opencode openchamber logrotate admin; do
  if launchctl list | grep -q "$PREFIX.home-stack.$svc"; then
    echo "FAIL: Service $svc still present in launchctl after unload"
    exit 1
  fi
done

# 8. Assert $HOME/Library/LaunchAgents has no *test.e2e.home-stack.*.plist files.
# Count via nullglob rather than `ls ... | wc -l`: with `set -o pipefail`, a
# non-matching glob makes ls fail, the pipeline fail, and the assignment fail,
# so `set -e` killed this script exactly when the uninstall had worked.
shopt -s nullglob
remaining=("$HOME/Library/LaunchAgents/$PREFIX.home-stack."*.plist)
shopt -u nullglob
if [[ ${#remaining[@]} -ne 0 ]]; then
  echo "FAIL: ${#remaining[@]} plists still present in Library/LaunchAgents after uninstall"
  printf '%s\n' "${remaining[@]}"
  exit 1
fi

echo "Test 14 passed"
