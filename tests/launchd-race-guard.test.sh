#!/usr/bin/env bash
# Guards the fix for launchd's asynchronous-teardown race: bootout returns
# before the job is gone, and bootstrapping into that window fails. These are
# pure-logic checks against home_stack_wait_label_gone and the restart path;
# they touch no real launchd state, so they run everywhere.
set -euo pipefail
ROOT="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/portable/home-stack/scripts/lib/common.sh"

pass=0
check() { if eval "$2"; then echo "[ok] $1"; pass=$((pass+1)); else echo "FAIL: $1" >&2; exit 1; fi; }

# 1. wait helper returns 0 immediately when a fake launchctl reports the label
#    already gone (print always fails).
gone_launchctl() { return 1; }
export -f gone_launchctl
check "wait returns 0 when label already gone" \
  'home_stack_wait_label_gone system some.label 3 gone_launchctl'

# 2. wait helper times out (non-zero) when the label never disappears.
present_launchctl() { [[ "$1" == print ]] && return 0; return 0; }
export -f present_launchctl
check "wait times out when label persists" \
  '! home_stack_wait_label_gone system some.label 2 present_launchctl 2>/dev/null'

# 3. wait helper polls: a label present for one tick then gone succeeds.
TICK_FILE="$(mktemp)"; echo 0 > "$TICK_FILE"
flaky_launchctl() {
  [[ "$1" == print ]] || return 0
  local n; n=$(cat "$TICK_FILE"); n=$((n+1)); echo "$n" > "$TICK_FILE"
  (( n <= 1 )) && return 0 || return 1
}
export -f flaky_launchctl; export TICK_FILE
check "wait polls until teardown completes" \
  'home_stack_wait_label_gone system some.label 5 flaky_launchctl'
rm -f "$TICK_FILE"

# 4. install-launchd.sh and service-launchd.sh no longer contain the racy
#    pattern: an unconditional bootout immediately followed by bootstrap with
#    no wait between them.
check "install-launchd uses the wait helper" \
  'grep -q home_stack_wait_label_gone "$ROOT/portable/home-stack/scripts/install-launchd.sh"'
check "service-launchd restart uses kickstart -k" \
  'grep -q "kickstart -k" "$ROOT/portable/home-stack/scripts/service-launchd.sh"'

# 6. --load must keep its contract: every service ends up loaded, including one
#    whose plist is byte-identical but which is not currently running. An
#    earlier version of this fix iterated only changed plists and silently left
#    stopped services stopped.
check "install --load iterates all agents, not only changed ones" \
  'grep -q "for svc in \"\${USER_AGENT_SERVICES\[@\]}\"" "$ROOT/portable/home-stack/scripts/install-launchd.sh"'
check "ensure_loaded bootstraps when not loaded regardless of changed" \
  'grep -A6 "if ! .\+ print " "$ROOT/portable/home-stack/scripts/install-launchd.sh" | grep -q "bootstrap \"\$domain\""'

# 7. bash 3.2 ships on macOS and errors on "${arr[@]}" for an empty array under
#    set -u, so the changed-set must never be expanded unguarded.
check "empty changed-set is guarded for bash 3.2" \
  'grep -q "CHANGED_LIST" "$ROOT/portable/home-stack/scripts/install-launchd.sh"'

# 8. The Caddy daemon keeps the deterministic bootout/bootstrap sequence, but
#    the wait between them is what makes it safe. Assert the ordering by line
#    number: bootout, then the wait, then bootstrap. A bootout followed
#    directly by bootstrap is the regression this whole file exists to prevent.
INSTALL="$ROOT/portable/home-stack/scripts/install-launchd.sh"
L_BOOTOUT=$(grep -n 'bootout "system/' "$INSTALL" | head -1 | cut -d: -f1)
L_WAIT=$(grep -n 'home_stack_wait_label_gone system' "$INSTALL" | head -1 | cut -d: -f1)
L_BOOT=$(grep -n 'bootstrap system "\$INSTALLED_CADDY_PLIST"' "$INSTALL" | head -1 | cut -d: -f1)
check "caddy: bootout precedes the teardown wait" \
  '[[ -n "$L_BOOTOUT" && -n "$L_WAIT" && "$L_BOOTOUT" -lt "$L_WAIT" ]]'
check "caddy: teardown wait precedes bootstrap" \
  '[[ -n "$L_BOOT" && "$L_WAIT" -lt "$L_BOOT" ]]'

echo "launchd-race-guard: $pass checks passed"
