#!/usr/bin/env bash
# Manage individual home-stack launchd services.
set -euo pipefail

########################################
# Robust script path resolution for symlinks
########################################
SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"
while [ -h "$SCRIPT_SOURCE" ]; do
  LINK="$(readlink "$SCRIPT_SOURCE")"
  if [[ "$LINK" == /* ]]; then
    SCRIPT_SOURCE="$LINK"
  else
    SCRIPT_SOURCE="$(dirname "$SCRIPT_SOURCE")/$LINK"
  fi
done
SCRIPT_DIR="$(cd -- "$(dirname "$SCRIPT_SOURCE")" && pwd)"
LIB_PATH="$SCRIPT_DIR/lib/common.sh"
if [[ -f "$LIB_PATH" ]]; then
  . "$LIB_PATH"
else
  echo "Error: could not locate common.sh at $LIB_PATH" >&2
  exit 1
fi

ACTION="${1:-}"
TARGET="${2:-}"

if [[ -z "$ACTION" || -z "$TARGET" ]]; then
  echo "Usage: $0 <start|stop|restart|status|reload> <service_name|all>" >&2
  exit 2
fi

# Load the profile environment. The hs wrapper already does this before
# dispatching here, but running the script directly must work the same way --
# every path below reads HOME_STACK_* and previously failed under `set -u` when
# invoked standalone.
home_stack_load_env

USER_DOMAIN="gui/$UID"
USER_AGENT_DIR="$HOME_STACK_OWNER_HOME/Library/LaunchAgents"
DAEMON_DIR="/Library/LaunchDaemons"

label_for() {
  local name="$1"
  echo "${HOME_STACK_IDENTIFIER_PREFIX}.home-stack.$name"
}

plist_for() {
  local name="$1"
  local user_plist="$USER_AGENT_DIR/${HOME_STACK_IDENTIFIER_PREFIX}.home-stack.$name.plist"
  local bundle_plist="$HOME_STACK_BUNDLE_DIR/launchd/${HOME_STACK_IDENTIFIER_PREFIX}.home-stack.$name.plist"
  local daemon_plist="$DAEMON_DIR/${HOME_STACK_IDENTIFIER_PREFIX}.home-stack.$name.plist"

  if [[ "$name" == "caddy" ]]; then
    echo "$daemon_plist"
  elif [[ -f "$user_plist" ]]; then
    echo "$user_plist"
  elif [[ -f "$bundle_plist" ]]; then
    echo "$bundle_plist"
  else
    # Fallback to user path if none exist
    echo "$user_plist"
  fi
}

is_system_service() {
  [[ "$1" == "caddy" ]]
}

get_domain() {
  if is_system_service "$1"; then
    echo "system"
  else
    echo "$USER_DOMAIN"
  fi
}

do_start() {
  local svc="$1"
  local label plist domain
  label="$(label_for "$svc")"
  plist="$(plist_for "$svc")"
  domain="$(get_domain "$svc")"

  if [[ ! -f "$plist" ]]; then
    echo "Error: plist not found for $svc at $plist" >&2
    return 1
  fi

  # Check if already running/bootstrapped
  if launchctl print "$domain/$label" >/dev/null 2>&1; then
    echo "Service $label is already loaded. Kickstarting..."
    if is_system_service "$svc"; then
      sudo launchctl kickstart -p "system/$label"
    else
      launchctl kickstart -p "$USER_DOMAIN/$label"
    fi
    return 0
  fi

  echo "Bootstrapping $label..."
  if is_system_service "$svc"; then
    sudo launchctl bootstrap system "$plist"
  else
    launchctl bootstrap "$USER_DOMAIN" "$plist"
  fi
}

do_stop() {
  local svc="$1"
  local label domain
  label="$(label_for "$svc")"
  domain="$(get_domain "$svc")"

  echo "Stopping $label..."
  if is_system_service "$svc"; then
    sudo launchctl bootout "system/$label" 2>/dev/null || true
  else
    launchctl bootout "$USER_DOMAIN/$label" 2>/dev/null || true
  fi
}

do_status() {
  local svc="$1"
  local label domain
  label="$(label_for "$svc")"
  domain="$(get_domain "$svc")"

  if is_system_service "$svc"; then
    sudo launchctl print "system/$label" 2>/dev/null || echo "$label not found"
  else
    launchctl print "$USER_DOMAIN/$label" 2>/dev/null || echo "$label not found"
  fi
}

do_reload() {
  local svc="$1"
  if [[ "$svc" != "caddy" ]]; then
    echo "reload is only supported for caddy (got: $svc)" >&2
    exit 2
  fi

  home_stack_load_env
  home_stack_normalize_cloudflare_env
  "$HOME_STACK_BUNDLE_DIR/bin/caddy-cloudflare" reload --config "$HOME_STACK_BUNDLE_DIR/Caddyfile"
}

# Determine services to act upon
SERVICES=()
if [[ "$TARGET" == "all" ]]; then
  # Registry-driven: the generated bundle holds one plist per agent service,
  # plus caddy (the system daemon, which the engine also knows about).
  shopt -s nullglob
  for plist in "$HOME_STACK_BUNDLE_DIR/launchd/${HOME_STACK_IDENTIFIER_PREFIX}.home-stack."*.plist; do
    svc="$(basename "$plist" .plist)"
    SERVICES+=("${svc#"${HOME_STACK_IDENTIFIER_PREFIX}.home-stack."}")
  done
  shopt -u nullglob
  SERVICES+=(caddy)
  if [[ ${#SERVICES[@]} -eq 1 ]]; then
    echo "No generated plists found in $HOME_STACK_BUNDLE_DIR/launchd. Run 'hs sync' first." >&2
    exit 1
  fi
else
  SERVICES=("$TARGET")
fi

# restart re-execs in place when the service is loaded (kickstart -k), which
# avoids the bootout/bootstrap teardown race entirely: launchctl kickstart -k
# kills and restarts the job without ever unloading the label. Only fall back to
# a full stop+wait+start when the service is not currently loaded.
do_restart() {
  local svc="$1"
  local label domain
  label="$(label_for "$svc")"
  domain="$(get_domain "$svc")"
  if is_system_service "$svc"; then
    if sudo launchctl print "$domain/$label" >/dev/null 2>&1; then
      sudo launchctl kickstart -k "$domain/$label"
      return 0
    fi
  else
    if launchctl print "$domain/$label" >/dev/null 2>&1; then
      launchctl kickstart -k "$domain/$label"
      return 0
    fi
  fi
  # Not loaded: stop is a no-op, then start bootstraps.
  do_stop "$svc"
  if is_system_service "$svc"; then
    home_stack_wait_label_gone "$domain" "$label" 30 sudo launchctl || return 1
  else
    home_stack_wait_label_gone "$domain" "$label" 30 launchctl || return 1
  fi
  do_start "$svc"
}

for svc in "${SERVICES[@]}"; do
  case "$ACTION" in
    start)   do_start "$svc" ;;
    stop)    do_stop "$svc" ;;
    restart) do_restart "$svc" ;;
    status)  do_status "$svc" ;;
    reload)  do_reload "$svc" ;;
    *) echo "Unknown action: $ACTION" >&2; exit 2 ;;
  esac
done
