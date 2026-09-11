#!/usr/bin/env bash
set -euo pipefail

ADMIN_PID=""
ROOT_DIR="$(cd -- "$(dirname "$0")/.." && pwd)"

echo "=== Test 16: Admin Action Safety (Black-box) ==="

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
    upstream: 127.0.0.1:31512
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
export HOME_STACK_ADMIN_PORT=31512
"$ADMIN_BIN" > "$STAGE/admin.log" 2>&1 &
ADMIN_PID=$!

# Wait for admin
echo "Waiting for admin to start..."
MAX_RETRIES=20
COUNT=0
while ! curl -v "http://127.0.0.1:31512/api/health" -u "admin:testpassword" >/dev/null; do
  sleep 0.5
  COUNT=$((COUNT + 1))
  if [[ $COUNT -ge $MAX_RETRIES ]]; then
    echo "Admin failed to start."
    exit 1
  fi
done

echo "Admin ready."

# Helper for POST actions
post_status() {
  local data="$1"
  local header="${2-X-Home-Stack-Admin: 1}"
  local auth="${3-admin:testpassword}"

  local cmd=(curl -s -o /dev/null -w "%{http_code}" -u "$auth" -H "Content-Type: application/json" -X POST -d "$data")
  if [[ -n "$header" ]]; then
    cmd+=(-H "$header")
  fi
  "${cmd[@]}" "http://127.0.0.1:31512/api/actions"
}

# 1. Mutation without header -> 403
echo "Testing: Mutation without header..."
status=$(post_status '{"action": "caddy.validate", "target": "caddy"}' "")
if [[ "$status" != "403" ]]; then
  echo "FAIL: Expected 403 for missing header, got $status"
  echo "Admin logs:"
  cat "$STAGE/admin.log"
  exit 1
fi

# 2. Mutation with unknown action -> 400
echo "Testing: Unknown action..."
status=$(post_status '{"action": "invalid.action", "target": "caddy"}')
if [[ "$status" != "400" ]]; then
  echo "FAIL: Expected 400 for unknown action, got $status"
  exit 1
fi

# 3. Mutation with allowlisted action + unknown target -> 400
echo "Testing: Unknown target..."
status=$(post_status '{"action": "service.restart", "target": "unknown-service"}')
if [[ "$status" != "400" ]]; then
  echo "FAIL: Expected 400 for unknown target, got $status"
  exit 1
fi

# 4. Mutation with allowlisted action + allowed target but no confirmation (if required) -> 400
echo "Testing: Missing confirmation..."
status=$(post_status '{"action": "service.restart", "target": "admin", "confirm": false}')
if [[ "$status" != "400" ]]; then
  echo "FAIL: Expected 400 for missing confirmation, got $status"
  exit 1
fi

# 5. Mutation with allowlisted action + allowed target + confirmation -> 200 or 400 (if exec fails)
echo "Testing: Valid action (caddy.validate)..."
status=$(post_status '{"action": "caddy.validate", "target": "caddy"}')
if [[ "$status" != "200" && "$status" != "400" ]]; then
  echo "FAIL: Expected 200 or 400, got $status"
  exit 1
fi

echo "Test 16 passed"
