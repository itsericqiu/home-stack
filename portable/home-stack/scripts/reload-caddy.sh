#!/usr/bin/env bash
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
home_stack_normalize_cloudflare_env

"$HOME_STACK_BUNDLE_DIR/bin/caddy-cloudflare" validate --config "$HOME_STACK_BUNDLE_DIR/Caddyfile" >/dev/null
"$HOME_STACK_BUNDLE_DIR/bin/caddy-cloudflare" reload --config "$HOME_STACK_BUNDLE_DIR/Caddyfile"
