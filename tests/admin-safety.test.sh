#!/usr/bin/env bash
# Admin safety checks: engine-generated Caddyfile must include admin route,
# proxy to localhost, and never expose the Caddy Admin API port.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADMIN_DIR="$REPO_ROOT/portable/home-stack/admin"
FIXTURE_DIR="$REPO_ROOT/tests/fixtures/profile-acme"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Build admin binary
ADMIN_BIN="$WORK/home-stack-admin"
( cd "$ADMIN_DIR" && go build -o "$ADMIN_BIN" . )

# Stage fixture and sync
STAGE="$WORK/repo"
mkdir -p "$STAGE/profiles/acme" "$STAGE/portable/home-stack/scripts"
cp "$FIXTURE_DIR/services.yaml" "$STAGE/profiles/acme/"

OWNER_HOME="$WORK/owner"
mkdir -p "$OWNER_HOME"
sed "s|__OWNER_HOME__|$OWNER_HOME|g" "$FIXTURE_DIR/home-stack.env" > "$WORK/profile.env"

cat > "$STAGE/portable/home-stack/scripts/reload-caddy.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$STAGE/portable/home-stack/scripts/reload-caddy.sh"

set -a
. "$WORK/profile.env"
HOME_STACK_PROFILE=acme
HOME_STACK_BUNDLE_DIR="$STAGE/portable/home-stack"
set +a
"$ADMIN_BIN" sync >/dev/null

CADDYFILE="$STAGE/portable/home-stack/Caddyfile"

# 1. Admin host matcher must exist
if ! grep -q '@admin host admin.' "$CADDYFILE"; then
  echo "missing admin host matcher in generated Caddyfile" >&2
  exit 1
fi

# 2. Admin must proxy to localhost (not expose the backend externally)
if ! grep -q "reverse_proxy 127.0.0.1:" "$CADDYFILE"; then
  echo "missing admin localhost reverse proxy in generated Caddyfile" >&2
  exit 1
fi

# 3. Caddy Admin API port (2019) must never be exposed
if grep -q '2019' "$CADDYFILE"; then
  echo "Caddy Admin API port must not be exposed in generated Caddyfile" >&2
  exit 1
fi

echo "admin safety tests passed"
