#!/usr/bin/env bash
set -euo pipefail

# Guard for macOS
if [[ "$(uname)" != "Darwin" ]]; then
  echo "skipping: requires macOS (launchctl/plutil)"
  exit 77 # 77 = skipped, so a runner can tell this apart from a pass
fi

# Additional guard: only run if explicitly allowed or in a known-safe environment
# to avoid polluting a developer's machine.
# Two independent conditions, because past this point the test bootstraps
# into the system domain and writes /Library/LaunchDaemons for real:
#   1. an explicit human opt-in, and
#   2. a marker asserting this host's launchd state is disposable.
# The marker is SET by the one Makefile target that runs on such a host, never
# sniffed from the ambient environment. Sniffing CI=true was wrong: that is set
# by unrelated tooling and by self-hosted runners, which are real machines.
if [[ "${HOME_STACK_TEST_ALLOW_SYSTEM_CHANGES:-}" != "1" ]]; then
  echo "skipping: Test 10 makes system-wide changes; runs only on a disposable host."
  exit 77 # 77 = skipped, not passed
fi
if [[ "${HOME_STACK_TEST_EPHEMERAL:-}" != "1" ]]; then
  # Loud, not exit 0: an opted-in run that silently skips is the failure mode
  # this whole effort exists to eliminate.
  echo "FAIL: Test 10 was opted in, but HOME_STACK_TEST_EPHEMERAL is not set." >&2
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

echo "=== Test 10: Identifier prefix flows end-to-end ==="

# Setup a fully isolated staging area: a COPY of the repo's portable/,
# profiles/, and templates/ trees, so this test never reads or writes
# anything under $ROOT_DIR. Everything it touches -- the built admin binary,
# the stubbed reload-caddy.sh, the generated Caddyfile/plists, the profile it
# creates -- lives under $STAGE and is destroyed with it.
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
export HOME_STACK_PROFILE="test-prefix"

# Ensure we have a Library/LaunchAgents dir in our temp HOME
mkdir -p "$HOME/Library/LaunchAgents"

cleanup() {
  # Preserve the real exit status: a failing command in here would otherwise
  # turn a passing test red (or mask why it went red).
  local rc=$?
  echo "Cleaning up..."
  {
  # Try to unload if loaded (staged uninstall script; real launchctl/system
  # domain -- that part is inherent to what this test exercises and is gated
  # above by the disposable-host opt-in, same as every other Darwin test).
  if [[ -f "$HS_SCRIPT" ]]; then
    HOME_STACK_PROFILE="test-prefix" "$UNINSTALL_SCRIPT" --unload || true
  fi
  export HOME="$ORIG_HOME"
  # HOME is staged here, so Go drops a read-only module cache under it;
  # rm alone fails and would taint the exit code from inside the trap.
  chmod -R u+w "$STAGE"
  rm -rf "$STAGE"
  } || true
  exit "$rc"
}
trap cleanup EXIT

# 1. hs init test-prefix
"$HS_SCRIPT" init test-prefix

# fill profile with HOME_STACK_IDENTIFIER_PREFIX=test.flow
PROFILE_ENV="$REPO/profiles/test-prefix/home-stack.env"
perl -pi -e 's/HOME_STACK_IDENTIFIER_PREFIX=.*/HOME_STACK_IDENTIFIER_PREFIX=test.flow/' "$PROFILE_ENV"
perl -pi -e 's/HOME_STACK_PARENT_DOMAIN=.*/HOME_STACK_PARENT_DOMAIN=test.flow.test/' "$PROFILE_ENV"
perl -pi -e 's/HOME_STACK_TAILNET_IP=.*/HOME_STACK_TAILNET_IP=127.0.0.1/' "$PROFILE_ENV"
perl -pi -e 's/HOME_STACK_ACME_EMAIL=.*/HOME_STACK_ACME_EMAIL=test\@flow.test/' "$PROFILE_ENV"
perl -pi -e "s|HOME_STACK_OWNER_HOME=.*|HOME_STACK_OWNER_HOME=$STAGE|" "$PROFILE_ENV"
perl -pi -e 's/HOME_STACK_ADMIN_USERNAME=.*/HOME_STACK_ADMIN_USERNAME=admin/' "$PROFILE_ENV"

# touch env.local
mkdir -p "$HOME/.config/home-stack"
cat > "$HOME/.config/home-stack/env.local" <<EOF
HOME_STACK_ADMIN_PASSWORD=testpassword
CLOUDFLARE_API_TOKEN=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
chmod 600 "$HOME/.config/home-stack/env.local"

# Add opencode/openchamber/logrotate to profile's services.yaml so install-launchd.sh has all plists.
cat >> "$REPO/profiles/test-prefix/services.yaml" <<'YAML'

  opencode:
    display_name: "OpenCode"
    kind: "app"
    type: "proxy"
    upstream: "127.0.0.1:31497"
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

# 2. hs sync (admin was built and reload-caddy.sh stubbed by
# home_stack_stage_repo above)
if ! "$HS_SCRIPT" sync; then
  echo "FAIL: hs sync failed"
  if [[ -f "$REPO/portable/home-stack/Caddyfile" ]]; then
    echo "Generated Caddyfile:"
    cat "$REPO/portable/home-stack/Caddyfile"
  fi
  exit 1
fi

# assert portable/home-stack/launchd/test.flow.home-stack.*.plist exist, in
# the STAGED bundle.
LAUNCHD_DIR="$REPO/portable/home-stack/launchd"
if [[ ! -f "$LAUNCHD_DIR/test.flow.home-stack.admin.plist" ]]; then
  echo "FAIL: admin plist not found at $LAUNCHD_DIR/test.flow.home-stack.admin.plist"
  exit 1
fi

# 3. Inspect plist Label value
LABEL=$(plutil -extract Label raw -o - "$LAUNCHD_DIR/test.flow.home-stack.admin.plist" 2>/dev/null || echo "")
if [[ "$LABEL" != "test.flow.home-stack.admin" ]]; then
  echo "FAIL: Incorrect label in plist: $LABEL"
  exit 1
fi

# 4. install-launchd.sh (no --load) -- staged script
"$INSTALL_SCRIPT"

# assert files appear in $HOME/Library/LaunchAgents/test.flow.home-stack.<svc>.plist
if [[ ! -f "$HOME/Library/LaunchAgents/test.flow.home-stack.admin.plist" ]]; then
  echo "FAIL: Installed plist not found in Library/LaunchAgents"
  exit 1
fi

# 5. install-launchd.sh --load -- staged script
"$INSTALL_SCRIPT" --load

# Poll rather than sleep: a fixed wait is the one unbounded flake risk left
# here, and it fails with no diagnostics on a loaded runner.
LOAD_LABEL="gui/$(id -u)/test.flow.home-stack.admin"
COUNT=0
until launchctl print "$LOAD_LABEL" >/dev/null 2>&1; do
  COUNT=$((COUNT + 1))
  if [[ $COUNT -ge 20 ]]; then
    echo "FAIL: Service test.flow.home-stack.admin not found in launchctl"
    launchctl print "$LOAD_LABEL" 2>&1 | head -20 || true
    exit 1
  fi
  sleep 0.5
done

echo "Test 10 passed"
