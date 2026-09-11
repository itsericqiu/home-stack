#!/usr/bin/env bash
# CLI bootstrap lifecycle: hs init / doctor / sync end-to-end (Test 7)
# + hs init --force semantics (Test 8)
set -euo pipefail

# Sanitize HOME_STACK_* vars that may leak from the user's environment
while IFS='=' read -r key _; do
  case "$key" in HOME_STACK_*|CLOUDFLARE_API_TOKEN) unset "$key" ;; esac
done < <(env)

REAL_REPO="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HS="$REAL_REPO/portable/home-stack/scripts/hs"
ADMIN_DIR="$REAL_REPO/portable/home-stack/admin"

fail() { echo "FAIL: $*" >&2; exit 1; }

# Create an isolated staging repo so the test works on read-only mounts too.
STAGE=$(mktemp -d)
STAGE=$(cd "$STAGE" && pwd)
trap 'rm -rf "$STAGE"' EXIT

# Copy profiles/default so hs init has a template to copy.
mkdir -p "$STAGE/profiles/default"
cp "$REAL_REPO/profiles/default/home-stack.env" "$STAGE/profiles/default/"
cp "$REAL_REPO/profiles/default/services.yaml" "$STAGE/profiles/default/"
# Copy templates/env.example so hs init can seed env.local
mkdir -p "$STAGE/templates"
cp "$REAL_REPO/templates/env.example" "$STAGE/templates/env.example"

ADMIN_BIN="$STAGE/home-stack-admin"
( cd "$ADMIN_DIR" && go build -o "$ADMIN_BIN" . )

PROFILE_NAME="phase1-test"
PROFILE_DIR="$STAGE/profiles/$PROFILE_NAME"

init_env() {
  HOME_STACK_REPO_ROOT="$STAGE" \
  HOME_STACK_OWNER_HOME="$STAGE/home" \
  HOME="$STAGE/home" \
  "$HS" init "$@"
}

# --- Test 7: CLI bootstrap lifecycle ---

# Step 1: init
init_env "$PROFILE_NAME"

[[ -d "$PROFILE_DIR" ]] || fail "hs init should create profile dir $PROFILE_DIR"
[[ -f "$PROFILE_DIR/home-stack.env" ]] || fail "hs init should create home-stack.env"
[[ -f "$PROFILE_DIR/services.yaml" ]] || fail "hs init should create services.yaml"

echo "[✓] Step 1: hs init created profile"

# Step 2: Inject mandatory values into profile
OWNER_HOME="$STAGE/owner-home"
mkdir -p "$OWNER_HOME"
sed -i.bak \
  -e "s|HOME_STACK_PARENT_DOMAIN=home.example.com|HOME_STACK_PARENT_DOMAIN=init-test.example|" \
  -e "s|HOME_STACK_TAILNET_IP=100.64.0.8|HOME_STACK_TAILNET_IP=100.64.0.8|" \
  -e "s|HOME_STACK_ACME_EMAIL=admin@example.com|HOME_STACK_ACME_EMAIL=test@example.test|" \
  -e "s|HOME_STACK_OWNER_HOME=/Users/REPLACE_ME|HOME_STACK_OWNER_HOME=$OWNER_HOME|" \
  -e "s|HOME_STACK_IDENTIFIER_PREFIX=com.example|HOME_STACK_IDENTIFIER_PREFIX=init.test|" \
  -e "s|HOME_STACK_ADMIN_USERNAME=admin|HOME_STACK_ADMIN_USERNAME=admin|" \
  "$PROFILE_DIR/home-stack.env"

echo "[✓] Step 2: Injected mandatory values into profile"

# Step 3: Run hs doctor — expect non-zero (env.local missing, binaries may be absent).
doctor_out=$(
  HOME_STACK_REPO_ROOT="$STAGE" \
  HOME_STACK_OWNER_HOME="$OWNER_HOME" \
  HOME_STACK_PROFILE="$PROFILE_NAME" \
  HOME="$OWNER_HOME" \
  "$HS" doctor 2>&1
) || true

echo "$doctor_out" | grep -q "HOME STACK DOCTOR" || fail "hs doctor should print 'HOME STACK DOCTOR' header"
echo "[✓] Step 3: hs doctor ran (env.local expected missing)"

# Step 4: Create env.local with mode 600
ENV_LOCAL="$OWNER_HOME/.config/home-stack/env.local"
mkdir -p "$(dirname "$ENV_LOCAL")"
touch "$ENV_LOCAL"
chmod 600 "$ENV_LOCAL"
echo "[✓] Step 4: Created env.local with mode 600"

# Step 5: Run hs doctor again — verify env.local check passes.
doctor_out2=$(
  HOME_STACK_REPO_ROOT="$STAGE" \
  HOME_STACK_OWNER_HOME="$OWNER_HOME" \
  HOME_STACK_PROFILE="$PROFILE_NAME" \
  HOME="$OWNER_HOME" \
  "$HS" doctor 2>&1
) || true

echo "$doctor_out2" | grep -q "env.local present" || fail "hs doctor should report env.local present"
# Either footer is an acceptable summary; hs prints "SYSTEM HEALTHY" or
# "<n> issues detected" (lowercase), so match both forms case-insensitively.
echo "$doctor_out2" | grep -qiE "issues detected|SYSTEM HEALTHY" || fail "hs doctor should print result summary"
echo "[✓] Step 5: hs doctor ran and found env.local"

# Step 6: Run hs sync — stage bundle dir, copy profile in, sync.
BUNDLE_STAGE="$STAGE/bundle"
mkdir -p "$BUNDLE_STAGE/profiles/$PROFILE_NAME"
mkdir -p "$BUNDLE_STAGE/portable/home-stack/launchd"
mkdir -p "$BUNDLE_STAGE/portable/home-stack/admin"
mkdir -p "$BUNDLE_STAGE/portable/home-stack/scripts"

cp "$PROFILE_DIR/home-stack.env" "$BUNDLE_STAGE/profiles/$PROFILE_NAME/"
cp "$PROFILE_DIR/services.yaml" "$BUNDLE_STAGE/profiles/$PROFILE_NAME/"

cat > "$BUNDLE_STAGE/portable/home-stack/scripts/reload-caddy.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$BUNDLE_STAGE/portable/home-stack/scripts/reload-caddy.sh"

HOME_STACK_BUNDLE_DIR="$BUNDLE_STAGE/portable/home-stack" \
HOME_STACK_PROFILE="$PROFILE_NAME" \
HOME_STACK_PARENT_DOMAIN="init-test.example" \
HOME_STACK_TAILNET_IP="100.64.0.8" \
HOME_STACK_ACME_EMAIL="test@example.test" \
HOME_STACK_OWNER_HOME="$OWNER_HOME" \
HOME_STACK_IDENTIFIER_PREFIX="init.test" \
HOME_STACK_ADMIN_USERNAME="admin" \
HOME="$OWNER_HOME" \
"$ADMIN_BIN" sync >/dev/null || fail "hs sync failed"

[[ -f "$BUNDLE_STAGE/portable/home-stack/Caddyfile" ]] || fail "sync should generate Caddyfile"
[[ -f "$BUNDLE_STAGE/portable/home-stack/catalog.json" ]] || fail "sync should generate catalog.json"
echo "[✓] Step 6: hs sync generated artifacts"

# --- Test 8: hs init --force semantics ---

# Step 8.1: Re-run init without --force — expect non-zero
if init_env "$PROFILE_NAME" 2>/dev/null; then
  fail "hs init without --force on existing profile should fail"
fi
echo "[✓] Test 8: hs init refuses overwrite without --force"

# Step 8.2: Verify env.local marker survives --force
MARKER="force-test-marker-$(date +%s)"
echo "MARKER_CONTENT=$MARKER" > "$ENV_LOCAL"
chmod 600 "$ENV_LOCAL"

init_env "$PROFILE_NAME" --force
[[ -d "$PROFILE_DIR" ]] || fail "hs init --force should succeed"

grep -q "MARKER_CONTENT=$MARKER" "$ENV_LOCAL" \
  || fail "hs init --force should preserve env.local content"
echo "[✓] Test 8: hs init --force preserves env.local"

# --- Test 9: an unknown first-level command must not fall through to the
# `<service> <command>` dispatch (which forwards blindly to
# service-launchd.sh) ---

hs_env() {
  HOME_STACK_REPO_ROOT="$STAGE" \
  HOME_STACK_OWNER_HOME="$OWNER_HOME" \
  HOME_STACK_PROFILE="$PROFILE_NAME" \
  HOME="$OWNER_HOME" \
  "$HS" "$@"
}

for bad_invocation in "app add" "bogus x"; do
  set +e
  bad_out=$(hs_env $bad_invocation 2>&1)
  bad_rc=$?
  set -e
  [[ "$bad_rc" -eq 2 ]] || fail "hs $bad_invocation should exit 2, got $bad_rc"
  echo "$bad_out" | grep -q "^Usage: hs" \
    || fail "hs $bad_invocation should print usage, got: $bad_out"
  if echo "$bad_out" | grep -qi "unknown action"; then
    fail "hs $bad_invocation reached service-launchd.sh (leaked its 'Unknown action' error): $bad_out"
  fi
done
echo "[✓] Test 9: hs app add / hs bogus x print usage and exit 2, never reaching service-launchd.sh"

# The reversed `hs <service_name> <command>` form must still work for a real
# lifecycle verb. Target a service name with no generated plist so do_start
# fails on the harmless "plist not found" check instead of touching launchd --
# this only needs to prove the call reached service-launchd.sh's do_start.
set +e
good_out=$(hs_env nonexistent-service start 2>&1)
good_rc=$?
set -e
echo "$good_out" | grep -q "plist not found" \
  || fail "hs <service> start should still reach service-launchd.sh's do_start, got: $good_out"
echo "[✓] Test 9: hs <service> start still dispatches to service-launchd.sh"

echo "PASS cli-bootstrap.test.sh"
