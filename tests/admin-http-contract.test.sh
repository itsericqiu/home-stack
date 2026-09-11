#!/usr/bin/env bash
set -euo pipefail

ADMIN_PID=""
ROOT_DIR="$(cd -- "$(dirname "$0")/.." && pwd)"

echo "=== Test 15: Admin HTTP API contract ==="

# Sanitize HOME_STACK_* vars that may leak from the user's environment
while IFS='=' read -r key _; do
  case "$key" in HOME_STACK_*|CLOUDFLARE_API_TOKEN) unset "$key" ;; esac
done < <(env)

# Setup temp staging area
STAGE="$(mktemp -d)"
trap 'kill $ADMIN_PID 2>/dev/null || true; rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/profiles/acme"
mkdir -p "$STAGE/portable/home-stack/admin"
mkdir -p "$STAGE/portable/home-stack/scripts/lib"

# Mock services.yaml
cat > "$STAGE/profiles/acme/services.yaml" <<EOF
services:
  admin:
    display_name: Admin
    kind: system
    type: proxy
    upstream: 127.0.0.1:31511
    health:
      http_url: http://127.0.0.1:31511/api/health
EOF

# Mock home-stack.env
cat > "$STAGE/profiles/acme/home-stack.env" <<EOF
HOME_STACK_PARENT_DOMAIN=home.acme.test
HOME_STACK_TAILNET_IP=100.64.0.42
HOME_STACK_ACME_EMAIL=admin@acme.test
HOME_STACK_OWNER_HOME=$STAGE/owner
HOME_STACK_IDENTIFIER_PREFIX=test.acme
HOME_STACK_ADMIN_USERNAME=admin
EOF

# Mock env.local
mkdir -p "$STAGE/owner/.config/home-stack"
cat > "$STAGE/owner/.config/home-stack/env.local" <<EOF
HOME_STACK_ADMIN_PASSWORD=testpassword
EOF

# Copy necessary scripts
cp "$ROOT_DIR/portable/home-stack/scripts/lib/common.sh" "$STAGE/portable/home-stack/scripts/lib/common.sh"

# Build admin
ADMIN_BIN="$STAGE/home-stack-admin"
echo "Building admin..."
( cd "$ROOT_DIR/portable/home-stack/admin" && go build -o "$ADMIN_BIN" . )

# Load env using the common.sh from STAGE
. "$STAGE/portable/home-stack/scripts/lib/common.sh"
export HOME_STACK_REPO_ROOT="$STAGE"
export HOME_STACK_BUNDLE_DIR="$STAGE/portable/home-stack"
export HOME_STACK_PROFILE=acme
export HOME_STACK_OWNER_HOME="$STAGE/owner"
export HOME_STACK_CONFIG_DIR="$STAGE/owner/.config/home-stack"

ADMIN_PID=""
home_stack_load_env

# Start admin
export HOME_STACK_ADMIN_PORT=31511
"$ADMIN_BIN" > "$STAGE/admin.log" 2>&1 &
ADMIN_PID=$!

# Wait for admin
echo "Waiting for admin to start..."
MAX_RETRIES=20
COUNT=0
while ! curl -s "http://127.0.0.1:31511/api/health" -u "admin:testpassword" >/dev/null; do
  sleep 0.5
  COUNT=$((COUNT + 1))
  if [[ $COUNT -ge $MAX_RETRIES ]]; then
    echo "Admin failed to start. Logs:"
    cat "$STAGE/admin.log"
    exit 1
  fi
done

echo "Admin ready."

# Helper for API calls
api_get() {
  local path="$1"
  local auth="${2:-admin:testpassword}"
  curl -s -u "$auth" "http://127.0.0.1:31511$path"
}

api_status() {
  local path="$1"
  local auth="${2:-admin:testpassword}"
  curl -s -o /dev/null -w "%{http_code}" -u "$auth" "http://127.0.0.1:31511$path"
}

# 1. Health unauth -> 401
if [[ "$(api_status /api/health "none:none")" != "401" ]]; then
  echo "FAIL: GET /api/health unauth should be 401"
  exit 1
fi

# 2. Health auth -> 200 OK
resp=$(api_get /api/health)
if [[ "$(echo "$resp" | jq -r .ok)" != "true" ]]; then
  echo "FAIL: GET /api/health auth failed: $resp"
  exit 1
fi

# 3. Status -> 200
resp=$(api_get /api/status)
if [[ "$(echo "$resp" | jq -r 'has("ok")')" != "true" ]]; then
  echo "FAIL: GET /api/status failed (missing ok field): $resp"
  exit 1
fi

# 4. Services -> 200, contains admin
resp=$(api_get /api/services)
if [[ "$(echo "$resp" | jq -r '.services[] | select(.name == "admin") | .name')" != "admin" ]]; then
  echo "FAIL: GET /api/services missing admin: $resp"
  exit 1
fi

# 5. Overview -> 200
resp=$(api_get /api/overview)
if [[ "$(echo "$resp" | jq -r .ok)" != "true" ]]; then
  echo "FAIL: GET /api/overview failed: $resp"
  exit 1
fi

# 6. Incidents -> 200
resp=$(api_get /api/incidents)
if [[ "$(echo "$resp" | jq -r .ok)" != "true" ]]; then
  echo "FAIL: GET /api/incidents failed: $resp"
  exit 1
fi

# 7. Events -> 200
resp=$(api_get /api/events)
if [[ "$(echo "$resp" | jq -r .ok)" != "true" ]]; then
  echo "FAIL: GET /api/events failed: $resp"
  exit 1
fi

# 8. Doctor -> 200
resp=$(api_get /api/doctor)
if [[ "$(echo "$resp" | jq -r '.checks | type == "array"')" != "true" ]]; then
  echo "FAIL: GET /api/doctor invalid response: $resp"
  exit 1
fi

# 9. Deploy Preview -> 200
resp=$(api_get /api/deploy/preview)
if [[ "$(echo "$resp" | jq -r .ok)" != "true" ]]; then
  echo "FAIL: GET /api/deploy/preview failed: $resp"
  exit 1
fi

# 10. Actions - missing mutation header -> 403
status=$(curl -s -o /dev/null -w "%{http_code}" -X POST -u "admin:testpassword" -d '{"action": "caddy.validate", "target": "caddy"}' "http://127.0.0.1:31511/api/actions")
if [[ "$status" != "403" ]]; then
  echo "FAIL: POST /api/actions without header should be 403, got $status"
  exit 1
fi

# 11. Actions - valid request -> 200
resp=$(curl -s -u "admin:testpassword" -H "X-Home-Stack-Admin: 1" -X POST -d '{"action": "caddy.validate", "target": "caddy"}' "http://127.0.0.1:31511/api/actions")
if [[ "$(echo "$resp" | jq -r .message)" == "null" ]]; then
  echo "FAIL: POST /api/actions invalid response: $resp"
  exit 1
fi

echo "Test 15 passed"
