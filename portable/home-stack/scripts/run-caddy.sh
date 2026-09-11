#!/usr/bin/env bash
# launchd foreground wrapper for Caddy with Cloudflare DNS-01 credentials.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
CADDY_BIN="$HOME_STACK_BUNDLE_DIR/bin/caddy-cloudflare"
CADDYFILE="$HOME_STACK_BUNDLE_DIR/Caddyfile"

home_stack_load_env
home_stack_normalize_cloudflare_env

if [[ -z "${HOME_STACK_CLOUDFLARE_API_TOKEN:-}" ]]; then
  echo "Missing HOME_STACK_CLOUDFLARE_API_TOKEN or CLOUDFLARE_API_TOKEN in $HOME_STACK_ENV_FILE" >&2
  exit 1
fi

exec "$CADDY_BIN" run --config "$CADDYFILE"
