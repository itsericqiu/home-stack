#!/usr/bin/env bash
# Cut the ingress over to the identity-layer Caddy binary, or roll it back.
#
# This is the one step the identity-layer work deliberately leaves to an
# operator. It restarts the Caddy LaunchDaemon, which briefly drops every route
# in the stack, and it needs sudo.
#
# Order is load-bearing. `hs sync` regenerates the live Caddyfile AND reloads
# Caddy, so the plugin-capable binary must be installed before any sync: the
# current binary cannot load `tailscale_auth`, and a Caddyfile it cannot parse
# leaves the daemon crash-looping on its next restart with no route to recovery.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
home_stack_load_env

BIN_DIR="$HOME_STACK_BUNDLE_DIR/bin"
LIVE="$BIN_DIR/caddy-cloudflare"
STAGED="$BIN_DIR/caddy-cloudflare.arm64-staged"
BACKUP="$BIN_DIR/caddy-cloudflare.x86_64.bak"
LABEL="${HOME_STACK_IDENTIFIER_PREFIX}.home-stack.caddy"
DAEMON_PLIST="/Library/LaunchDaemons/${LABEL}.plist"

log()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[31mFAIL:\033[0m %s\n' "$*" >&2; exit 1; }

required_modules=(dns.providers.cloudflare http.authentication.providers.tailscale)

verify_binary() {
  local bin="$1" label="$2"
  [[ -x "$bin" ]] || fail "$label not found or not executable: $bin"
  for mod in "${required_modules[@]}"; do
    "$bin" list-modules 2>/dev/null | grep -qx "$mod" \
      || fail "$label is missing required module: $mod"
  done
  log "$label carries both required modules"
}

restart_daemon() {
  log "restarting the Caddy LaunchDaemon (sudo required; brief stack outage)"

  if sudo launchctl print "system/$LABEL" >/dev/null 2>&1; then
    # Loaded, and only the binary behind the plist changed. kickstart -k kills
    # and re-execs in place -- no bootout, so the asynchronous-teardown race
    # (bootout returns before the job is gone; an immediate bootstrap then fails
    # with "Bootstrap failed: 5" after the ingress is already down) cannot
    # happen. Do not reintroduce that pair here.
    sudo launchctl kickstart -k "system/$LABEL"
  else
    # Not loaded (e.g. recovering from a failed cutover): wait for any in-flight
    # teardown before bootstrapping. Same helper install-launchd.sh uses.
    home_stack_wait_label_gone system "$LABEL" 15 sudo launchctl \
      || fail "job $LABEL never finished tearing down"
    sudo launchctl bootstrap system "$DAEMON_PLIST"
  fi
  sleep 3
}

health_check() {
  local tries=0
  until curl -sS -o /dev/null --max-time 5 http://127.0.0.1:2019/config/; do
    tries=$((tries + 1))
    (( tries >= 10 )) && fail "Caddy admin API did not come back; check $HOME_STACK_LOG_DIR/caddy.launchd.err.log"
    sleep 2
  done
  log "Caddy admin API responding"
}

if [[ "${1:-}" == "--rollback" ]]; then
  log "ROLLBACK: restoring the pre-identity-layer ingress"
  [[ -f "$BACKUP" ]] || fail "no backup at $BACKUP — nothing to roll back to"
  verify_binary "$BACKUP" "backup binary" || true

  # The registry must go back too: an `auth:` entry generates a directive the
  # restored binary cannot parse, so reverting the binary alone would still
  # produce an unloadable Caddyfile on the next sync.
  log "reverting services.yaml to HEAD (drops auth: entries)"
  git -C "$HOME_STACK_REPO_ROOT" checkout -- "profiles/$HOME_STACK_PROFILE/services.yaml"

  cp "$LIVE" "$BIN_DIR/caddy-cloudflare.identity.bak"
  cp "$BACKUP" "$LIVE"
  log "restored $BACKUP -> $LIVE"
  "$SCRIPT_DIR/hs" sync
  restart_daemon
  health_check
  log "rollback complete"
  exit 0
fi

log "PRE-FLIGHT"
verify_binary "$STAGED" "staged binary"

if [[ ! -f "$BACKUP" ]]; then
  cp "$LIVE" "$BACKUP"
  log "backed up current ingress -> $BACKUP"
else
  log "backup already exists at $BACKUP (leaving it alone)"
fi

# Prove the new binary can parse the config the registry will generate, before
# anything is swapped. `adapt` resolves every directive to a module without
# provisioning TLS, so it needs no Cloudflare credential.
log "checking the staged binary against current generated config"
if [[ -f "$HOME_STACK_BUNDLE_DIR/Caddyfile" ]]; then
  "$STAGED" adapt --config "$HOME_STACK_BUNDLE_DIR/Caddyfile" --adapter caddyfile >/dev/null \
    || fail "staged binary cannot adapt the current Caddyfile"
  log "current Caddyfile adapts cleanly"
fi

log "SWAP"
cp "$STAGED" "$LIVE"
log "installed the identity-layer ingress"

# Restart BEFORE sync, not after. `hs sync` reloads through Caddy's admin API,
# which pushes config into the process that is already running -- and replacing
# the file on disk does not change a running process's image. Reloading first
# therefore asks the OLD binary to load `tailscale_auth` and fails with
# "unknown module: http.authentication.providers.tailscale". A binary change can
# only be picked up by restarting the daemon, so that has to happen first; the
# new process starts against the existing Caddyfile, which it can always parse.
restart_daemon
health_check

log "SYNC (regenerates Caddyfile/plists/catalog from the registry)"
"$SCRIPT_DIR/hs" sync
health_check

log "POST-FLIGHT"
"$LIVE" list-modules 2>/dev/null | grep -qx http.authentication.providers.tailscale \
  && log "running ingress has tailscale_auth"
log "cutover complete. Install any new LaunchAgents with:"
log "  $SCRIPT_DIR/install-launchd.sh --load"
