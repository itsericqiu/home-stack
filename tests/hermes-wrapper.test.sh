#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER="$ROOT_DIR/portable/home-stack/scripts/run-hermes.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

OWNER_HOME="$WORK/owner"
PROFILE_DIR="$WORK/profiles/test"
mkdir -p "$OWNER_HOME/.local/bin" "$OWNER_HOME/.config/home-stack" "$PROFILE_DIR"

cat >"$PROFILE_DIR/home-stack.env" <<EOF
HOME_STACK_PARENT_DOMAIN=home.test.example
HOME_STACK_TAILNET_IP=100.64.0.8
HOME_STACK_ACME_EMAIL=admin@example.test
HOME_STACK_OWNER_HOME=$OWNER_HOME
HOME_STACK_IDENTIFIER_PREFIX=test.example
HOME_STACK_ADMIN_USERNAME=admin
HOME_STACK_HERMES_PORT=31511
HOME_STACK_HERMES_DASHBOARD_USERNAME=hermes-user
EOF

cat >"$OWNER_HOME/.config/home-stack/env.local" <<'EOF'
HOME_STACK_HERMES_DASHBOARD_PASSWORD_HASH=scrypt\$16384\$8\$1\$salt\$hash
HOME_STACK_HERMES_DASHBOARD_SECRET=stable-test-secret
HOME_STACK_HERMES_OIDC_CLIENT_ID=hermes-test-client
HOME_STACK_HERMES_OIDC_CLIENT_SECRET=hermes-test-client-secret
HOME_STACK_HERMES_OIDC_ISSUER=https://id.home.test.example
HOME_STACK_ADMIN_PASSWORD=must-not-reach-hermes
HOME_STACK_CLOUDFLARE_API_TOKEN=must-not-reach-hermes-either
EOF
chmod 600 "$OWNER_HOME/.config/home-stack/env.local"

cat >"$OWNER_HOME/.local/bin/hermes" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == "dashboard --host 100.64.0.8 --port 31511 --no-open" ]]
expected_owner="$(cd -- "$(dirname "$0")/../.." && pwd)"
[[ "$HOME" == "$expected_owner" ]]
[[ "$HERMES_HOME" == "$expected_owner/.hermes" ]]
[[ "$HERMES_DASHBOARD_BASIC_AUTH_USERNAME" == "hermes-user" ]]
[[ "$HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH" == 'scrypt$16384$8$1$salt$hash' ]]
[[ "$HERMES_DASHBOARD_BASIC_AUTH_SECRET" == "stable-test-secret" ]]
[[ "$HERMES_DASHBOARD_PUBLIC_URL" == "https://hermes.home.test.example" ]]
[[ "$HERMES_DASHBOARD_OIDC_CLIENT_ID" == "hermes-test-client" ]]
[[ "$HERMES_DASHBOARD_OIDC_CLIENT_SECRET" == "hermes-test-client-secret" ]]
[[ "$HERMES_DASHBOARD_OIDC_ISSUER" == "https://id.home.test.example" ]]
[[ "$HERMES_DASHBOARD_OIDC_SCOPES" == "openid profile email" ]]
[[ -z "${HOME_STACK_ADMIN_PASSWORD+x}" ]]
[[ -z "${HOME_STACK_CLOUDFLARE_API_TOKEN+x}" ]]
[[ -z "${SHOULD_NOT_REACH_HERMES+x}" ]]
if /usr/bin/env | /usr/bin/grep -q '^HOME_STACK_'; then
  echo "home-stack variable leaked into Hermes" >&2
  exit 1
fi
printf 'fake-hermes-ok\n'
EOF
chmod +x "$OWNER_HOME/.local/bin/hermes"

# 1. Engine-injected HOME_STACK_SELF_URL flows into HERMES_DASHBOARD_PUBLIC_URL;
#    HOME_STACK_HERMES_OIDC_ISSUER wins explicitly over any catalog lookup.
output="$(
  HOME_STACK_REPO_ROOT="$WORK" \
  HOME_STACK_PROFILE=test \
  HOME_STACK_SELF_URL="https://hermes.home.test.example" \
  SHOULD_NOT_REACH_HERMES=ambient-sentinel \
  "$WRAPPER"
)"
[[ "$output" == "fake-hermes-ok" ]] || fail "wrapper did not exec Hermes with the expected environment and arguments"

# 2. Neither HOME_STACK_SELF_URL nor the OIDC issuer is set explicitly: both
#    the dashboard public URL and the OIDC issuer default resolve from
#    catalog.json (the engine's generated sync artifact) via
#    home_stack_service_url -- never from a profile subdomain variable.
BUNDLE_DIR="$WORK/bundle"
mkdir -p "$BUNDLE_DIR"
cat >"$BUNDLE_DIR/catalog.json" <<'EOF'
{
  "hermes": {"DisplayName": "Hermes Agent", "Subdomain": "hermes", "Host": "", "url": "https://hermes.home.test.example"},
  "pocket-id": {"DisplayName": "Pocket ID", "Subdomain": "id", "Host": "", "url": "https://id.home.test.example"}
}
EOF

cat >"$OWNER_HOME/.config/home-stack/env.local" <<'EOF'
HOME_STACK_HERMES_DASHBOARD_PASSWORD_HASH=scrypt\$16384\$8\$1\$salt\$hash
HOME_STACK_HERMES_DASHBOARD_SECRET=stable-test-secret
HOME_STACK_HERMES_OIDC_CLIENT_ID=hermes-test-client
HOME_STACK_HERMES_OIDC_CLIENT_SECRET=hermes-test-client-secret
EOF
chmod 600 "$OWNER_HOME/.config/home-stack/env.local"

cat >"$OWNER_HOME/.local/bin/hermes" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$HERMES_DASHBOARD_PUBLIC_URL" == "https://hermes.home.test.example" ]]
[[ "$HERMES_DASHBOARD_OIDC_ISSUER" == "https://id.home.test.example" ]]
if /usr/bin/env | /usr/bin/grep -q '^HOME_STACK_'; then
  echo "home-stack variable leaked into Hermes" >&2
  exit 1
fi
printf 'fake-hermes-catalog-ok\n'
EOF
chmod +x "$OWNER_HOME/.local/bin/hermes"

output="$(
  HOME_STACK_REPO_ROOT="$WORK" \
  HOME_STACK_PROFILE=test \
  HOME_STACK_BUNDLE_DIR="$BUNDLE_DIR" \
  "$WRAPPER"
)"
[[ "$output" == "fake-hermes-catalog-ok" ]] \
  || fail "public URL / issuer defaults did not resolve from catalog.json (got: $output)"

# 3. Neither HOME_STACK_SELF_URL nor a catalog.json entry for hermes: fail
#    closed, by name, naming both sources -- no `:-hermes` fallback to a
#    guessed profile subdomain variable. No OIDC client vars here, so this
#    exercises only the wrapper's own URL resolution, not the issuer lookup.
cat >"$OWNER_HOME/.config/home-stack/env.local" <<'EOF'
HOME_STACK_HERMES_DASHBOARD_PASSWORD_HASH=scrypt\$16384\$8\$1\$salt\$hash
HOME_STACK_HERMES_DASHBOARD_SECRET=stable-test-secret
EOF
chmod 600 "$OWNER_HOME/.config/home-stack/env.local"

EMPTY_BUNDLE_DIR="$WORK/empty-bundle"
mkdir -p "$EMPTY_BUNDLE_DIR"
set +e
error_output="$(
  HOME_STACK_REPO_ROOT="$WORK" \
  HOME_STACK_PROFILE=test \
  HOME_STACK_BUNDLE_DIR="$EMPTY_BUNDLE_DIR" \
  "$WRAPPER" 2>&1
)"
rc=$?
set -e
[[ "$rc" -eq 78 ]] || fail "expected exit 78 for missing HOME_STACK_SELF_URL and catalog.json, got $rc"
grep -q 'HOME_STACK_SELF_URL' <<<"$error_output" \
  || fail "wrapper error should name HOME_STACK_SELF_URL, got: $error_output"
grep -q 'catalog.json' <<<"$error_output" \
  || fail "wrapper error should name catalog.json, got: $error_output"

# 4. Fail closed without the stable signing secret, and report only the
#    missing key -- unrelated to URL resolution, so supply SELF_URL directly.
cat >"$OWNER_HOME/.config/home-stack/env.local" <<'EOF'
HOME_STACK_HERMES_DASHBOARD_PASSWORD_HASH=scrypt\$16384\$8\$1\$salt\$hash
EOF
chmod 600 "$OWNER_HOME/.config/home-stack/env.local"

if error_output="$(
  HOME_STACK_REPO_ROOT="$WORK" \
  HOME_STACK_PROFILE=test \
  HOME_STACK_SELF_URL="https://hermes.home.test.example" \
  "$WRAPPER" 2>&1
)"; then
  fail "wrapper should reject incomplete Hermes auth"
fi
grep -q 'HOME_STACK_HERMES_DASHBOARD_SECRET' <<<"$error_output" \
  || fail "wrapper error should name the missing signing-secret variable"
if grep -q 'stable-test-secret\|scrypt\$' <<<"$error_output"; then
  fail "wrapper error leaked a secret value"
fi

echo "PASS hermes-wrapper.test.sh"
