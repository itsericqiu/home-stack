#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HS="$ROOT_DIR/portable/home-stack/scripts/hs"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat >"$WORK/fake-curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$HOME_STACK_TEST_CURL_ARGS"
printf '%s\n' '{"ok":true,"details":"{\"has_changes\":false,\"caddyfile\":{},\"launchd\":{},\"catalog\":{}}"}'
EOF
chmod +x "$WORK/fake-curl"

cat >"$WORK/env.local" <<'EOF'
HOME_STACK_ADMIN_PASSWORD=test-admin-password
EOF
chmod 600 "$WORK/env.local"

# Pin the profile: resolution otherwise guesses from `whoami`, so this would
# only pass on a machine whose username matches a profiles/ directory.
output="$({
  HOME_STACK_ENV_FILE="$WORK/env.local" \
  HOME_STACK_CURL_BIN="$WORK/fake-curl" \
  HOME_STACK_TEST_CURL_ARGS="$WORK/curl-args" \
  HOME_STACK_PROFILE=default \
    "$HS" deploy --preview
} 2>&1)"

[[ "$output" == "Registry is in sync." ]] || {
  echo "FAIL: unexpected deploy preview output: $output" >&2
  exit 1
}
grep -qx 'admin:test-admin-password' "$WORK/curl-args" || {
  echo "FAIL: hs deploy did not use the loaded Admin username/password" >&2
  exit 1
}
grep -qx 'http://127.0.0.1:31510/api/actions' "$WORK/curl-args" || {
  echo "FAIL: hs deploy did not use the private loopback Admin URL" >&2
  exit 1
}
[[ "$output" != *test-admin-password* ]] || {
  echo "FAIL: hs deploy leaked the Admin password" >&2
  exit 1
}

echo "PASS hs-deploy.test.sh"
