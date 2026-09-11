#!/usr/bin/env bash
# Print launchd status for home-stack services.
# This is now a thin wrapper around the Go-native implementation.
set -euo pipefail

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
home_stack_load_env

exec "$HOME_STACK_BUNDLE_DIR/admin/home-stack-admin" launchd-status "$@"
