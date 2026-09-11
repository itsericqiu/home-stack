#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER="$ROOT_DIR/portable/home-stack/scripts/run-tinyauth.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

OWNER_HOME="$WORK/owner"
PROFILE_DIR="$WORK/profiles/test"
BUNDLE_DIR="$WORK/bundle"
mkdir -p "$OWNER_HOME/.config/home-stack" "$PROFILE_DIR" "$BUNDLE_DIR/bin"

cat >"$PROFILE_DIR/home-stack.env" <<EOF
HOME_STACK_PARENT_DOMAIN=home.test.example
HOME_STACK_TAILNET_IP=100.64.0.8
HOME_STACK_ACME_EMAIL=admin@example.test
HOME_STACK_OWNER_HOME=$OWNER_HOME
HOME_STACK_IDENTIFIER_PREFIX=test.example
HOME_STACK_ADMIN_USERNAME=admin
EOF

cat >"$OWNER_HOME/.config/home-stack/env.local" <<'EOF'
HOME_STACK_TINYAUTH_SECRET=stable-test-secret
EOF
chmod 600 "$OWNER_HOME/.config/home-stack/env.local"

# catalog.json is the private sync artifact the engine writes; stage one so
# home_stack_service_url has something to resolve pocket-id and tinyauth
# against. The `url` field is what the engine actually emits (RoutableURL);
# the shell never recomposes it from Subdomain/Host.
cat >"$BUNDLE_DIR/catalog.json" <<'EOF'
{
  "pocket-id": {"DisplayName": "Pocket ID", "Subdomain": "id", "Host": "", "url": "https://id.home.test.example"},
  "tinyauth": {"DisplayName": "tinyauth", "Subdomain": "auth", "Host": "", "url": "https://auth.home.test.example"}
}
EOF

cat >"$BUNDLE_DIR/bin/tinyauth" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'TINYAUTH_APPURL=%s\n' "$TINYAUTH_APPURL"
printf 'AUTHURL=%s\n' "${TINYAUTH_OAUTH_PROVIDERS_POCKETID_AUTHURL:-}"
EOF
chmod +x "$BUNDLE_DIR/bin/tinyauth"

run_wrapper() {
  HOME_STACK_REPO_ROOT="$WORK" \
  HOME_STACK_PROFILE=test \
  HOME_STACK_BUNDLE_DIR="$BUNDLE_DIR" \
  "$@" "$WRAPPER"
}

# 1. Engine-injected HOME_STACK_SELF_URL flows straight into TINYAUTH_APPURL.
output="$(run_wrapper env HOME_STACK_SELF_URL="https://auth.home.test.example")"
grep -q '^TINYAUTH_APPURL=https://auth.home.test.example$' <<<"$output" \
  || fail "TINYAUTH_APPURL did not equal the injected HOME_STACK_SELF_URL, got: $output"

# 2. pocket_id_base resolves from the staged catalog.json via
#    home_stack_service_url when the OIDC client vars are set.
output="$(
  run_wrapper env \
    HOME_STACK_SELF_URL="https://auth.home.test.example" \
    HOME_STACK_TINYAUTH_OIDC_CLIENTID=client-id \
    HOME_STACK_TINYAUTH_OIDC_CLIENTSECRET=client-secret
)"
grep -q '^AUTHURL=https://id.home.test.example/authorize$' <<<"$output" \
  || fail "pocket-id AUTHURL did not resolve from catalog.json, got: $output"

# 3. No HOME_STACK_SELF_URL, but a staged catalog.json carries tinyauth's own
#    `url` -- the fallback that keeps a wrapper started under a stale plist
#    (kickstart -k does not re-read the plist) from crash-looping.
output="$(run_wrapper env)"
grep -q '^TINYAUTH_APPURL=https://auth.home.test.example$' <<<"$output" \
  || fail "TINYAUTH_APPURL did not fall back to catalog.json's tinyauth url, got: $output"

# 4. Neither source available: fail closed, by name, naming both
#    HOME_STACK_SELF_URL and catalog.json -- no `:-auth` fallback to a
#    guessed profile subdomain variable.
cat >"$BUNDLE_DIR/catalog.json" <<'EOF'
{
  "pocket-id": {"DisplayName": "Pocket ID", "Subdomain": "id", "Host": "", "url": "https://id.home.test.example"}
}
EOF
set +e
error_output="$(run_wrapper env 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 78 ]] || fail "expected exit 78 for missing HOME_STACK_SELF_URL and catalog.json, got $rc"
grep -q 'HOME_STACK_SELF_URL' <<<"$error_output" \
  || fail "wrapper error should name HOME_STACK_SELF_URL, got: $error_output"
grep -q 'catalog.json' <<<"$error_output" \
  || fail "wrapper error should name catalog.json, got: $error_output"

# 5. Fail closed when the OIDC client vars are set but pocket-id cannot be
#    resolved (catalog.json missing the entry entirely). Own SELF_URL is
#    supplied explicitly so this exercises only the sibling-lookup failure.
cat >"$BUNDLE_DIR/catalog.json" <<'EOF'
{}
EOF
set +e
error_output="$(
  run_wrapper env \
    HOME_STACK_SELF_URL="https://auth.home.test.example" \
    HOME_STACK_TINYAUTH_OIDC_CLIENTID=client-id \
    HOME_STACK_TINYAUTH_OIDC_CLIENTSECRET=client-secret \
    2>&1
)"
rc=$?
set -e
[[ "$rc" -eq 78 ]] || fail "expected exit 78 when pocket-id cannot be resolved, got $rc"
grep -q 'pocket-id' <<<"$error_output" \
  || fail "wrapper error should mention pocket-id, got: $error_output"
if grep -q 'stable-test-secret\|client-secret' <<<"$error_output"; then
  fail "wrapper error leaked a secret value"
fi

echo "PASS tinyauth-wrapper.test.sh"
