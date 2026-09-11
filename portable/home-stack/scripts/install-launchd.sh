#!/usr/bin/env bash
# Render and install launchd plists. Pass --load to start services.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
home_stack_load_env
ROOT_DIR="$HOME_STACK_REPO_ROOT"
PORTABLE_DIR="$HOME_STACK_BUNDLE_DIR"
GENERATED_DIR="$PORTABLE_DIR/launchd"
GENERATED_DAEMON_DIR="$GENERATED_DIR/daemons"
USER_AGENT_DIR="$HOME_STACK_OWNER_HOME/Library/LaunchAgents"
DAEMON_DIR="/Library/LaunchDaemons"
LOG_DIR="$HOME_STACK_LOG_DIR"

LOAD=0
if [[ "${1:-}" == "--load" ]]; then
  LOAD=1
elif [[ $# -gt 0 ]]; then
  echo "Usage: $0 [--load]" >&2
  exit 2
fi

# sudo wrapper — skip sudo when already root
as_root() {
  if [[ "$(id -u)" == "0" ]]; then "$@"; else sudo "$@"; fi
}

# The engine generates the Caddy LaunchDaemon plist alongside the agents
# (launchd/daemons/), so install consumes one generation pipeline for both.
GENERATED_CADDY_PLIST="$GENERATED_DAEMON_DIR/${HOME_STACK_IDENTIFIER_PREFIX}.home-stack.caddy.plist"
if [[ ! -f "$GENERATED_CADDY_PLIST" ]]; then
  echo "Missing generated daemon plist at $GENERATED_CADDY_PLIST. Run 'hs sync' first." >&2
  exit 1
fi

LINT_TARGETS=("$GENERATED_CADDY_PLIST")
OWNER_USER="$(stat -f "%Su" "$HOME_STACK_OWNER_HOME")"
# Agents live in the owner's gui domain. $UID is 0 under sudo, and gui/0 does
# not exist — bootstrapping there fails and aborts the script, leaving the
# Caddy daemon booted out but never re-bootstrapped (dead ingress). Resolve the
# owner's uid explicitly so the script behaves the same with or without sudo.
OWNER_UID="$(id -u "$OWNER_USER")"
GUI_DOMAIN="gui/$OWNER_UID"

# The agent set comes from the registry, not a hand-maintained list here.
# `hs sync` writes exactly one plist per non-system, non-static service into
# GENERATED_DIR, so enumerating that directory keeps the include/exclude rule
# in one place (the engine) and picks up services.yaml additions automatically.
shopt -s nullglob
USER_AGENT_SERVICES=()
for generated in "$GENERATED_DIR/${HOME_STACK_IDENTIFIER_PREFIX}.home-stack."*.plist; do
  svc="$(basename "$generated")"
  svc="${svc#"${HOME_STACK_IDENTIFIER_PREFIX}.home-stack."}"
  USER_AGENT_SERVICES+=("${svc%.plist}")
done
shopt -u nullglob

if [[ ${#USER_AGENT_SERVICES[@]} -eq 0 ]]; then
  echo "No generated agent plists in $GENERATED_DIR. Run 'hs sync' first." >&2
  exit 1
fi
echo "Agents from registry: ${USER_AGENT_SERVICES[*]}"

# `hs sync` materializes agent plists into GENERATED_DIR from services.yaml.
# Copy them into the LaunchAgents directory here, otherwise a registry change
# regenerates the bundle but never reaches the plist launchd actually loads.
mkdir -p "$USER_AGENT_DIR"
# Track which agents actually changed, before overwriting them. --load still
# guarantees every service ends up loaded; `changed` only decides whether a
# service that is ALREADY loaded needs cycling. A running service whose plist is
# unchanged is already in the desired state, and bouncing it was never required
# for convergence -- each unnecessary bootout was another chance to hit
# launchd's asynchronous-teardown race, and it drops live state (Hermes agent
# sessions, in-flight requests) for nothing.
#
# bash 3.2 (macOS) errors on "${arr[@]}" for an empty array under set -u and has
# no associative arrays, so membership is tested against a padded string.
CHANGED_AGENTS=()
for svc in "${USER_AGENT_SERVICES[@]}"; do
  generated="$GENERATED_DIR/${HOME_STACK_IDENTIFIER_PREFIX}.home-stack.${svc}.plist"
  installed="$USER_AGENT_DIR/${HOME_STACK_IDENTIFIER_PREFIX}.home-stack.${svc}.plist"
  if [[ ! -f "$generated" ]]; then
    echo "Missing generated plist for $svc at $generated. Run 'hs sync' first." >&2
    exit 1
  fi
  plutil -lint "$generated" >/dev/null
  if [[ ! -f "$installed" ]] || ! cmp -s "$generated" "$installed"; then
    CHANGED_AGENTS+=("$svc")
  fi
  # LaunchAgents must be owned by the loading user, not root. This script needs
  # sudo for the Caddy daemon, so set ownership explicitly rather than
  # inheriting whatever the invoking user happens to be.
  rm -f "$installed"
  install -o "$OWNER_USER" -g staff -m 644 "$generated" "$installed"
  LINT_TARGETS+=("$installed")
done
plutil -lint "${LINT_TARGETS[@]}" >/dev/null

# Prune orphans: a service removed from the registry stops being generated,
# but its previously installed agent would keep running forever. Removal must
# propagate just like addition, so anything in our namespace with no generated
# counterpart is booted out and deleted.
shopt -s nullglob
for installed in "$USER_AGENT_DIR/${HOME_STACK_IDENTIFIER_PREFIX}.home-stack."*.plist; do
  base="$(basename "$installed")"
  if [[ ! -f "$GENERATED_DIR/$base" ]]; then
    label="${base%.plist}"
    echo "Pruning orphaned agent $label (no longer in registry)"
    launchctl bootout "$GUI_DOMAIN/$label" 2>/dev/null || true
    rm -f "$installed"
  fi
done
shopt -u nullglob

CADDY_LABEL="${HOME_STACK_IDENTIFIER_PREFIX}.home-stack.caddy"
INSTALLED_CADDY_PLIST="$DAEMON_DIR/$CADDY_LABEL.plist"
# No change-detection for the daemon: --load always cycles the ingress. Agents
# are the ones worth leaving alone when unchanged (they hold live state), and
# the daemon's load path is kept deliberately boring -- see the load block.
as_root install -m 644 "$GENERATED_CADDY_PLIST" "$INSTALLED_CADDY_PLIST"
plutil -lint "$INSTALLED_CADDY_PLIST" >/dev/null

# Caddy runs as root, so launchd creates its logs root-owned and the logrotate
# agent (which runs as the owner) cannot truncate them. Hand them to the owner
# once at install; launchd preserves ownership when reopening an existing file.
for stream in out err; do
  caddy_log="$LOG_DIR/caddy.launchd.${stream}.log"
  as_root touch "$caddy_log"
  as_root chown "$OWNER_USER:staff" "$caddy_log"
done

echo "Installed LaunchAgent plist files to $USER_AGENT_DIR"
echo "Installed Caddy LaunchDaemon plist to $DAEMON_DIR"

if [[ "$LOAD" == "1" ]]; then
  # Bring one label to its installed plist, without ever leaving it stopped:
  #   - loaded, plist unchanged  -> kickstart -k re-execs in place; no bootout,
  #                                 so the teardown race cannot happen.
  #   - loaded, plist changed    -> launchd cannot swap a plist under a live
  #                                 label, so one bootout is unavoidable -- but
  #                                 we WAIT for teardown before bootstrapping.
  #                                 That wait is the step whose absence produced
  #                                 "Bootstrap failed: 5" and a dead service.
  #   - not loaded               -> bootstrap.
  # `changed` is passed in, not recomputed, so daemon and agents share one rule.
  ensure_loaded() {
    local domain="$1" label="$2" plist="$3" changed="$4"; shift 4
    local -a lc=("$@"); [[ ${#lc[@]} -eq 0 ]] && lc=(launchctl)
    if ! "${lc[@]}" print "$domain/$label" >/dev/null 2>&1; then
      # Not loaded -- start it. This runs regardless of `changed`, so --load
      # keeps its contract of leaving every service running even when a plist
      # is byte-identical (a crashed or manually stopped service).
      echo "  starting $label"
      "${lc[@]}" bootstrap "$domain" "$plist"
    elif [[ "$changed" == "1" ]]; then
      # launchd cannot swap a plist under a live label, so this bootout is
      # unavoidable -- but wait for teardown before bootstrapping.
      echo "  reloading $label (plist changed)"
      "${lc[@]}" bootout "$domain/$label" 2>/dev/null || true
      home_stack_wait_label_gone "$domain" "$label" 30 "${lc[@]}" || return 1
      "${lc[@]}" bootstrap "$domain" "$plist"
    else
      echo "  $label already current"
    fi
  }

  # Padded string so membership works on bash 3.2 (no associative arrays), and
  # so an empty CHANGED_AGENTS never reaches an unguarded "${arr[@]}".
  CHANGED_LIST=" "
  if [[ ${#CHANGED_AGENTS[@]} -gt 0 ]]; then
    CHANGED_LIST=" ${CHANGED_AGENTS[*]} "
  fi

  # Ingress first: if an agent step fails, Caddy is already up rather than left
  # stopped.
  #
  # The daemon deliberately keeps the original unconditional bootout/bootstrap
  # rather than going through ensure_loaded. Routing it through the same
  # print-then-branch logic as the agents regressed the launchd e2e suite on a
  # CI runner (the daemon stopped appearing in `sudo launchctl list`), and the
  # cause was never pinned down. The race this commit exists to fix is real and
  # is fixed here by the wait between bootout and bootstrap; replacing a
  # sequence three green CI runs had validated was an unforced extra change.
  # The cost is that --load always cycles the ingress, which is acceptable for
  # an explicit load and is what this script has always done.
  if [[ "$(id -u)" == "0" ]]; then CADDY_LC=(launchctl); else CADDY_LC=(sudo launchctl); fi
  "${CADDY_LC[@]}" bootout "system/$CADDY_LABEL" 2>/dev/null || true
  # THE fix: bootout is asynchronous, so wait for launchd to forget the label
  # before bootstrapping it again.
  home_stack_wait_label_gone system "$CADDY_LABEL" 30 "${CADDY_LC[@]}" \
    || { echo "Caddy daemon $CADDY_LABEL did not finish tearing down" >&2; exit 1; }
  # Restored guard: a stray Caddy holding the admin port means the bootstrap
  # below would start a daemon that cannot bind, so fail loudly instead.
  for _ in 1 2 3 4 5; do
    lsof -nP -iTCP:2019 -sTCP:LISTEN >/dev/null 2>&1 || break
    sleep 1
  done
  if lsof -nP -iTCP:2019 -sTCP:LISTEN >/dev/null 2>&1; then
    echo "Caddy admin port 2019 is already in use. Stop the existing Caddy process before loading the LaunchDaemon:" >&2
    lsof -nP -iTCP:2019 -sTCP:LISTEN >&2 || true
    exit 1
  fi
  "${CADDY_LC[@]}" bootstrap system "$INSTALLED_CADDY_PLIST"

  for svc in "${USER_AGENT_SERVICES[@]}"; do
    label="${HOME_STACK_IDENTIFIER_PREFIX}.home-stack.${svc}"
    changed=0
    [[ "$CHANGED_LIST" == *" $svc "* ]] && changed=1
    ensure_loaded "$GUI_DOMAIN" "$label" "$USER_AGENT_DIR/$label.plist" "$changed"
  done

  # A plist-only comparison cannot see a rebuilt binary behind an unchanged
  # plist. Restart those explicitly (hs restart <svc>); install --load will
  # report them as already current.
  echo "Loaded home-stack services. Run status-launchd.sh to inspect state."
else
  echo "Not loaded. Re-run with --load when ready to start services."
fi
