#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname "$0")/.." && pwd)"

echo "=== Test 17: Secret Redaction ==="

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

# Sentinels
SECRET_PW="SECRET_ADMIN_PW_DO_NOT_LEAK"
SECRET_TOKEN="SECRET_TOKEN_DO_NOT_LEAK"

# Mock services.yaml
cat > "$STAGE/profiles/acme/services.yaml" <<EOF
services:
  test-service:
    display_name: Test Service
    kind: app
    type: proxy
    upstream: 127.0.0.1:8080
    env:
      DB_PASSWORD: $SECRET_PW
    args: ["--token", "$SECRET_TOKEN"]
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
HOME_STACK_ADMIN_PASSWORD=$SECRET_PW
HOME_STACK_CLOUDFLARE_API_TOKEN=$SECRET_TOKEN
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

home_stack_load_env

# 1. Check sync output and artifacts — use a staged bundle dir with reload stub.
echo "Checking sync output and artifacts..."
SYNC_BUNDLE="$STAGE/sync-bundle"
mkdir -p "$SYNC_BUNDLE/scripts"
cat > "$SYNC_BUNDLE/scripts/reload-caddy.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$SYNC_BUNDLE/scripts/reload-caddy.sh"

SYNC_OUT=$(HOME_STACK_BUNDLE_DIR="$SYNC_BUNDLE" "$ADMIN_BIN" sync 2>&1 || true)
if echo "$SYNC_OUT" | grep -qE "SECRET_"; then
  echo "FAIL: Secret leaked in sync output"
  exit 1
fi

if grep -rE "SECRET_" "$SYNC_BUNDLE" 2>/dev/null; then
  echo "FAIL: Secret leaked in generated artifacts"
  grep -rE "SECRET_" "$SYNC_BUNDLE"
  exit 1
fi

# 2. Start admin in background and check API endpoints for secret leakage.
export HOME_STACK_ADMIN_PORT=31513
export HOME_STACK_BUNDLE_DIR="$STAGE/portable/home-stack"
"$ADMIN_BIN" > "$STAGE/admin.log" 2>&1 &
ADMIN_PID=$!

echo "Waiting for admin..."
MAX_RETRIES=20
COUNT=0
while ! curl -s "http://127.0.0.1:31513/api/health" -u "admin:$SECRET_PW" >/dev/null; do
  sleep 0.5
  COUNT=$((COUNT + 1))
  if [[ $COUNT -ge $MAX_RETRIES ]]; then
    echo "Admin failed to start. Logs:"
    cat "$STAGE/admin.log"
    exit 1
  fi
done

api_get() {
  curl -s -u "admin:$SECRET_PW" "http://127.0.0.1:31513$1"
}

for route in /api/doctor /api/events /api/services /api/overview /api/deploy/preview; do
  echo "Checking route $route..."
  resp=$(api_get "$route")
  if echo "$resp" | grep -qE "SECRET_"; then
    echo "FAIL: Secret leaked in $route response"
    exit 1
  fi
done

# 3. Check admin event log files
echo "Checking admin event logs..."
curl -s -u "admin:$SECRET_PW" -H "X-Home-Stack-Admin: 1" -X POST -d '{"action": "caddy.validate", "target": "caddy"}' "http://127.0.0.1:31513/api/actions" > /dev/null

LOG_DIR="$STAGE/owner/.config/home-stack/logs"
if [[ -d "$LOG_DIR" ]]; then
  if grep -rE "SECRET_" "$LOG_DIR" 2>/dev/null; then
    echo "FAIL: Secret leaked in admin event logs"
    exit 1
  fi
fi

echo "Test 17 passed"

