#!/usr/bin/env bash
# Rotate home-stack logs by size and retain a fixed history.
set -euo pipefail

# Resolve the real path of this script even if invoked through a symlink
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
. "$SCRIPT_DIR/lib/common.sh"
home_stack_load_env

home_stack_ensure_runtime_dirs

MAX_BYTES="${HOME_STACK_LOG_MAX_BYTES:-26214400}"
KEEP="${HOME_STACK_LOG_KEEP:-7}"

if ! [[ "$MAX_BYTES" =~ ^[0-9]+$ ]] || ! [[ "$KEEP" =~ ^[0-9]+$ ]]; then
  echo "HOME_STACK_LOG_MAX_BYTES and HOME_STACK_LOG_KEEP must be integers" >&2
  exit 2
fi

rotate_one() {
  local logfile="$1"
  local size

  if [[ ! -f "$logfile" ]]; then
    return 0
  fi

  # Logs written by the Caddy LaunchDaemon are root-owned. Truncating one we
  # cannot write aborts the whole run under `set -e`, which silently starves
  # every log sorting after it. Skip and keep going instead.
  if [[ ! -w "$logfile" ]]; then
    echo "skipping (not writable by $(id -un)): $logfile" >&2
    return 0
  fi

  size=$(stat -f "%z" "$logfile" 2>/dev/null || printf '0')
  if [[ "$size" -lt "$MAX_BYTES" ]]; then
    return 0
  fi

  if [[ "$KEEP" -gt 0 ]]; then
    local i
    for ((i=KEEP; i>=1; i--)); do
      if [[ -f "${logfile}.${i}" ]]; then
        if [[ "$i" -eq "$KEEP" ]]; then
          rm -f "${logfile}.${i}"
        else
          mv "${logfile}.${i}" "${logfile}.$((i+1))"
        fi
      fi
    done
    cp "$logfile" "${logfile}.1"
    gzip -f "${logfile}.1"
  fi

  : > "$logfile"
  echo "rotated and compressed: $logfile (${size} bytes)"
}

shopt -s nullglob
for f in "$HOME_STACK_LOG_DIR"/*.log; do
  rotate_one "$f"
done
