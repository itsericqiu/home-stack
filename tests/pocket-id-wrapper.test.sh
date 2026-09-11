#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER="$ROOT_DIR/portable/home-stack/scripts/run-pocket-id.sh"

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
HOME_STACK_POCKET_ID_ENCRYPTION_KEY=deadbeefdeadbeefdeadbeefdeadbeef
EOF
chmod 600 "$OWNER_HOME/.config/home-stack/env.local"

cat >"$BUNDLE_DIR/bin/pocket-id" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$HOST" == "127.0.0.1" ]]
printf '%s\n' "$APP_URL"
EOF
chmod +x "$BUNDLE_DIR/bin/pocket-id"

run_wrapper() {
  HOME_STACK_REPO_ROOT="$WORK" \
  HOME_STACK_PROFILE=test \
  HOME_STACK_BUNDLE_DIR="$BUNDLE_DIR" \
  "$@" "$WRAPPER"
}

# 1. Engine-injected HOME_STACK_SELF_URL flows straight into APP_URL.
output="$(run_wrapper env HOME_STACK_SELF_URL="https://id.home.test.example")"
[[ "$output" == "https://id.home.test.example" ]] \
  || fail "APP_URL did not equal the injected HOME_STACK_SELF_URL (got: $output)"

# 2. No HOME_STACK_SELF_URL, but a staged catalog.json carries pocket-id's
#    `url` -- the fallback that keeps a wrapper started under a stale plist
#    (kickstart -k does not re-read the plist) from crash-looping.
cat >"$BUNDLE_DIR/catalog.json" <<'EOF'
{
  "pocket-id": {"DisplayName": "Pocket ID", "Subdomain": "id", "Host": "", "url": "https://id.home.test.example"}
}
EOF
output="$(run_wrapper env)"
[[ "$output" == "https://id.home.test.example" ]] \
  || fail "APP_URL did not fall back to catalog.json's pocket-id url (got: $output)"
rm -f "$BUNDLE_DIR/catalog.json"

# 3. Neither source available: fail closed, by name, naming both
#    HOME_STACK_SELF_URL and catalog.json -- no `:-id` fallback to a guessed
#    profile subdomain variable.
set +e
error_output="$(run_wrapper env 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 78 ]] || fail "expected exit 78 for missing HOME_STACK_SELF_URL and catalog.json, got $rc"
grep -q 'HOME_STACK_SELF_URL' <<<"$error_output" \
  || fail "wrapper error should name HOME_STACK_SELF_URL, got: $error_output"
grep -q 'catalog.json' <<<"$error_output" \
  || fail "wrapper error should name catalog.json, got: $error_output"

echo "PASS pocket-id-wrapper.test.sh"
