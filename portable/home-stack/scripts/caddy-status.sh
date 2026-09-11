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

ADMIN_URL="${HOME_STACK_CADDY_ADMIN_URL:-http://127.0.0.1:2019}"

case "$ADMIN_URL" in
  http://127.0.0.1:*|http://localhost:*|http://[::1]:*) ;;
  *)
    echo "Caddy Admin API URL must stay localhost-only: $ADMIN_URL" >&2
    exit 2
    ;;
esac

if command -v curl >/dev/null 2>&1; then
  curl --fail --silent --show-error --max-time 5 "$ADMIN_URL/config/" >/dev/null
  echo "caddy admin reachable: $ADMIN_URL"
else
  python3 - "$ADMIN_URL/config/" <<'PY'
import sys, urllib.request
urllib.request.urlopen(sys.argv[1], timeout=5).read()
print('caddy admin reachable:', sys.argv[1].rsplit('/config/', 1)[0])
PY
fi
