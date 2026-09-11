#!/usr/bin/env bash
# Remove launchd plists. Pass --unload to stop loaded services first.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
home_stack_load_env
USER_AGENT_DIR="$HOME_STACK_OWNER_HOME/Library/LaunchAgents"
DAEMON_DIR="/Library/LaunchDaemons"

UNLOAD=0
if [[ "${1:-}" == "--unload" ]]; then
  UNLOAD=1
elif [[ $# -gt 0 ]]; then
  echo "Usage: $0 [--unload]" >&2
  exit 2
fi

# The <prefix>.home-stack.* namespace belongs to home-stack, so removal is
# glob-driven: every installed agent in it goes, whatever the registry said
# when it was installed. No hand-maintained service list to fall behind.
OWNER_USER="$(stat -f "%Su" "$HOME_STACK_OWNER_HOME")"
OWNER_UID="$(id -u "$OWNER_USER")"
GUI_DOMAIN="gui/$OWNER_UID"

shopt -s nullglob
for plist in "$USER_AGENT_DIR/${HOME_STACK_IDENTIFIER_PREFIX}.home-stack."*.plist; do
  label="$(basename "$plist" .plist)"
  if [[ "$UNLOAD" == "1" ]]; then
    launchctl bootout "$GUI_DOMAIN/$label" 2>/dev/null || true
  fi
  rm -f "$plist"
  echo "Removed agent $label"
done
shopt -u nullglob

if [[ "$UNLOAD" == "1" ]]; then
  sudo launchctl bootout system/${HOME_STACK_IDENTIFIER_PREFIX}.home-stack.caddy 2>/dev/null || true
fi
sudo rm -f "$DAEMON_DIR/${HOME_STACK_IDENTIFIER_PREFIX}.home-stack.caddy.plist"

echo "Removed home-stack launchd plist files."
echo "Runtime data was not removed. OpenCode/OpenChamber state and home-stack env/logs remain in user config directories."
