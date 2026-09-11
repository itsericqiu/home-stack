#!/usr/bin/env bash
set -euo pipefail

# Sanitize HOME_STACK_* vars that may leak from the user's environment
while IFS='=' read -r key _; do
  case "$key" in HOME_STACK_*|CLOUDFLARE_API_TOKEN) unset "$key" ;; esac
done < <(env)

ROOT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON_SH="$ROOT_DIR/portable/home-stack/scripts/lib/common.sh"
ENV_SET="$ROOT_DIR/portable/home-stack/scripts/env-set.sh"

# Profile resolution otherwise guesses from `whoami`, so this suite would only
# pass on a machine whose username happens to match a profiles/ directory.
# Pin it; cases that need a different profile override it inline.
export HOME_STACK_PROFILE=default

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file_contains() {
  local file="$1"
  local pattern="$2"
  grep -qE -- "$pattern" "$file" || fail "expected $file to contain pattern: $pattern"
}

assert_file_not_contains() {
  local file="$1"
  local pattern="$2"
  if grep -qE -- "$pattern" "$file"; then
    fail "expected $file not to contain pattern: $pattern"
  fi
}

test_caddy_token_compatibility() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  cat >"$tmp/env.local" <<'EOF'
CLOUDFLARE_API_TOKEN=legacy-token
EOF

  mkdir -p "$tmp/profiles/test"
  cat >"$tmp/profiles/test/home-stack.env" <<EOF
HOME_STACK_PARENT_DOMAIN=test.example
HOME_STACK_TAILNET_IP=100.64.0.8
HOME_STACK_ACME_EMAIL=test@example.com
HOME_STACK_OWNER_HOME=$tmp/home
HOME_STACK_IDENTIFIER_PREFIX=test.example
HOME_STACK_ADMIN_USERNAME=admin
EOF
  touch "$tmp/profiles/test/services.yaml"

  HOME="$tmp/home" \
  HOME_STACK_OWNER_HOME="$tmp/home" \
  HOME_STACK_CONFIG_DIR="$tmp" \
  HOME_STACK_ENV_FILE="$tmp/env.local" \
  HOME_STACK_REPO_ROOT="$tmp" \
  HOME_STACK_PROFILE="test" \
  bash -c '. "$0"; home_stack_load_env; home_stack_normalize_cloudflare_env; [[ "$HOME_STACK_CLOUDFLARE_API_TOKEN" == legacy-token ]] && [[ "$CLOUDFLARE_API_TOKEN" == legacy-token ]]' "$COMMON_SH" \
    || fail "legacy CLOUDFLARE_API_TOKEN should populate HOME_STACK_CLOUDFLARE_API_TOKEN"
}

test_env_set_appends_with_backup_and_preserves_existing_values() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  cat >"$tmp/env.local" <<'EOF'
CLOUDFLARE_API_TOKEN=legacy-token
OPENCODE_SERVER_PASSWORD=keep-me
EOF

  # env-set.sh calls home_stack_ensure_runtime_dirs which requires these vars.
  # common.sh now defers their derivation to home_stack_load_env, so we must
  # supply them explicitly when invoking env-set.sh outside the normal load flow.
  HOME_STACK_OWNER_HOME="$tmp" \
  HOME_STACK_CONFIG_DIR="$tmp/config" \
  HOME_STACK_LOG_DIR="$tmp/config/logs" \
  HOME_STACK_PID_DIR="$tmp/config/pids" \
  HOME_STACK_TLS_DIR="$tmp/config/tls" \
  HOME_STACK_CADDY_CONFIG_DIR="$tmp/config/caddy/config" \
  HOME_STACK_CADDY_DATA_DIR="$tmp/config/caddy/data" \
  HOME_STACK_ENV_FILE="$tmp/env.local" \
    "$ENV_SET" HOME_STACK_CLOUDFLARE_API_TOKEN new-token >/dev/null

  assert_file_contains "$tmp/env.local" '^CLOUDFLARE_API_TOKEN=legacy-token$'
  assert_file_contains "$tmp/env.local" '^OPENCODE_SERVER_PASSWORD=keep-me$'
  assert_file_contains "$tmp/env.local" '^HOME_STACK_CLOUDFLARE_API_TOKEN=new-token$'

  local backup_count
  backup_count="$(ls "$tmp"/env.local.bak.* 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$backup_count" == "1" ]] || fail "expected exactly one backup, got $backup_count"
}

test_env_set_replaces_only_requested_key() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  cat >"$tmp/env.local" <<'EOF'
HOME_STACK_CLOUDFLARE_API_TOKEN=old-token
OPENCHAMBER_UI_PASSWORD=keep-me
EOF

  HOME_STACK_OWNER_HOME="$tmp" \
  HOME_STACK_CONFIG_DIR="$tmp/config" \
  HOME_STACK_LOG_DIR="$tmp/config/logs" \
  HOME_STACK_PID_DIR="$tmp/config/pids" \
  HOME_STACK_TLS_DIR="$tmp/config/tls" \
  HOME_STACK_CADDY_CONFIG_DIR="$tmp/config/caddy/config" \
  HOME_STACK_CADDY_DATA_DIR="$tmp/config/caddy/data" \
  HOME_STACK_ENV_FILE="$tmp/env.local" \
    "$ENV_SET" HOME_STACK_CLOUDFLARE_API_TOKEN new-token >/dev/null

  assert_file_not_contains "$tmp/env.local" '^HOME_STACK_CLOUDFLARE_API_TOKEN=old-token$'
  assert_file_contains "$tmp/env.local" '^HOME_STACK_CLOUDFLARE_API_TOKEN=new-token$'
  assert_file_contains "$tmp/env.local" '^OPENCHAMBER_UI_PASSWORD=keep-me$'
}

test_env_set_round_trips_shell_sensitive_values() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  : >"$tmp/env.local"
  local expected='scrypt$16384$8$1$salt with space$hash#fragment'

  HOME_STACK_OWNER_HOME="$tmp" \
  HOME_STACK_CONFIG_DIR="$tmp/config" \
  HOME_STACK_LOG_DIR="$tmp/config/logs" \
  HOME_STACK_PID_DIR="$tmp/config/pids" \
  HOME_STACK_TLS_DIR="$tmp/config/tls" \
  HOME_STACK_CADDY_CONFIG_DIR="$tmp/config/caddy/config" \
  HOME_STACK_CADDY_DATA_DIR="$tmp/config/caddy/data" \
  HOME_STACK_ENV_FILE="$tmp/env.local" \
    "$ENV_SET" HOME_STACK_HERMES_DASHBOARD_PASSWORD_HASH "$expected" >/dev/null

  local actual
  actual="$(ENV_FILE="$tmp/env.local" bash -c 'set -a; . "$ENV_FILE"; printf %s "$HOME_STACK_HERMES_DASHBOARD_PASSWORD_HASH"')"
  [[ "$actual" == "$expected" ]] || fail "env-set did not round-trip a shell-sensitive hash"
}

test_env_set_does_not_source_existing_secrets() {
  local tmp marker
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  marker="$tmp/executed"

  printf 'UNRELATED_SECRET=$(touch %q)\n' "$marker" >"$tmp/env.local"

  HOME_STACK_OWNER_HOME="$tmp" \
  HOME_STACK_CONFIG_DIR="$tmp/config" \
  HOME_STACK_LOG_DIR="$tmp/config/logs" \
  HOME_STACK_PID_DIR="$tmp/config/pids" \
  HOME_STACK_TLS_DIR="$tmp/config/tls" \
  HOME_STACK_CADDY_CONFIG_DIR="$tmp/config/caddy/config" \
  HOME_STACK_CADDY_DATA_DIR="$tmp/config/caddy/data" \
  HOME_STACK_ENV_FILE="$tmp/env.local" \
    "$ENV_SET" SAFE_SECRET replacement >/dev/null

  [[ ! -e "$marker" ]] || fail "env-set executed an unrelated existing secret assignment"
  assert_file_contains "$tmp/env.local" '^SAFE_SECRET=replacement$'
}

test_env_set_rejects_unsafe_key_names() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  cat >"$tmp/env.local" <<'EOF'
SAFE=value
EOF

  if HOME_STACK_OWNER_HOME="$tmp" \
     HOME_STACK_CONFIG_DIR="$tmp/config" \
     HOME_STACK_LOG_DIR="$tmp/config/logs" \
     HOME_STACK_PID_DIR="$tmp/config/pids" \
     HOME_STACK_TLS_DIR="$tmp/config/tls" \
     HOME_STACK_CADDY_CONFIG_DIR="$tmp/config/caddy/config" \
     HOME_STACK_CADDY_DATA_DIR="$tmp/config/caddy/data" \
     HOME_STACK_ENV_FILE="$tmp/env.local" \
       "$ENV_SET" 'BAD-KEY' value >/dev/null 2>&1; then
    fail "env-set should reject unsafe key names"
  fi

  assert_file_contains "$tmp/env.local" '^SAFE=value$'
}

test_caddy_token_compatibility
test_env_set_appends_with_backup_and_preserves_existing_values
test_env_set_replaces_only_requested_key
test_env_set_round_trips_shell_sensitive_values
test_env_set_does_not_source_existing_secrets
test_env_set_rejects_unsafe_key_names

# ---------------------------------------------------------------------------
# Admin binary: missing mandatory env vars
# ---------------------------------------------------------------------------

ADMIN_DIR="$ROOT_DIR/portable/home-stack/admin"

_build_admin_bin() {
  local dest="$1"
  ( cd "$ADMIN_DIR" && go build -o "$dest" ./... )
}

test_sync_with_no_mandatory_env_exits_nonzero() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  local bin="$tmp/home-stack-admin"
  _build_admin_bin "$bin"

  local stderr_out
  stderr_out=$(env -i HOME="$tmp" HOME_STACK_BUNDLE_DIR="$tmp" "$bin" sync 2>&1) && {
    fail "sync with no mandatory env should exit non-zero"
  } || true

  echo "$stderr_out" | grep -q "missing mandatory environment variables" \
    || fail "sync stderr should mention missing mandatory environment variables; got: $stderr_out"

  # Each required key must appear in the error message.
  for key in HOME_STACK_PARENT_DOMAIN HOME_STACK_TAILNET_IP HOME_STACK_ACME_EMAIL \
              HOME_STACK_OWNER_HOME HOME_STACK_IDENTIFIER_PREFIX HOME_STACK_ADMIN_USERNAME; do
    echo "$stderr_out" | grep -q "$key" \
      || fail "sync stderr missing key $key; got: $stderr_out"
  done
}

test_sync_with_partial_env_exits_nonzero_and_names_missing_key() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  local bin="$tmp/home-stack-admin"
  _build_admin_bin "$bin"

  # Provide all mandatory vars except HOME_STACK_ACME_EMAIL.
  local stderr_out
  stderr_out=$(env -i \
    HOME="$tmp" \
    HOME_STACK_BUNDLE_DIR="$tmp" \
    HOME_STACK_PARENT_DOMAIN=test.example \
    HOME_STACK_TAILNET_IP=100.64.0.8 \
    HOME_STACK_OWNER_HOME="$tmp" \
    HOME_STACK_IDENTIFIER_PREFIX=test.example \
    HOME_STACK_ADMIN_USERNAME=admin \
    "$bin" sync 2>&1) && {
    fail "sync with partial env (missing HOME_STACK_ACME_EMAIL) should exit non-zero"
  } || true

  echo "$stderr_out" | grep -q "HOME_STACK_ACME_EMAIL" \
    || fail "sync stderr should name HOME_STACK_ACME_EMAIL as missing; got: $stderr_out"
}

test_server_with_no_mandatory_env_exits_nonzero() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  local bin="$tmp/home-stack-admin"
  _build_admin_bin "$bin"

  local stderr_out exit_code
  # Run server in background; it should exit quickly due to missing env.
  stderr_out=$(HOME_STACK_BUNDLE_DIR="$tmp" HOME="$tmp" "$bin" 2>&1) && exit_code=0 || exit_code=$?

  [[ "$exit_code" -ne 0 ]] \
    || fail "server with no mandatory env should exit non-zero"

  echo "$stderr_out" | grep -q "missing mandatory environment variables" \
    || fail "server stderr should mention missing mandatory environment variables; got: $stderr_out"

  for key in HOME_STACK_PARENT_DOMAIN HOME_STACK_TAILNET_IP HOME_STACK_ACME_EMAIL \
              HOME_STACK_OWNER_HOME HOME_STACK_IDENTIFIER_PREFIX HOME_STACK_ADMIN_USERNAME; do
    echo "$stderr_out" | grep -q "$key" \
      || fail "server stderr missing key $key; got: $stderr_out"
  done
}

test_common_sh_validate_mandatory_reports_each_missing_key() {
  local missing_output
  missing_output=$(
    env -i HOME=/tmp HOME_STACK_PROFILE=testprofile \
    bash -c '
      . "$0"
      # Unset all mandatory vars to force failure
      unset HOME_STACK_PARENT_DOMAIN HOME_STACK_TAILNET_IP HOME_STACK_ACME_EMAIL \
            HOME_STACK_OWNER_HOME HOME_STACK_IDENTIFIER_PREFIX HOME_STACK_ADMIN_USERNAME
      home_stack_validate_mandatory
    ' "$COMMON_SH" 2>&1
  ) || true

  for key in HOME_STACK_PARENT_DOMAIN HOME_STACK_TAILNET_IP HOME_STACK_ACME_EMAIL \
              HOME_STACK_OWNER_HOME HOME_STACK_IDENTIFIER_PREFIX HOME_STACK_ADMIN_USERNAME; do
    echo "$missing_output" | grep -q "$key" \
      || fail "home_stack_validate_mandatory should report missing key $key; got: $missing_output"
  done
}

test_common_sh_validate_mandatory_passes_when_all_set() {
  local result exit_code
  result=$(
    env -i HOME=/tmp HOME_STACK_PROFILE=testprofile \
    bash -c '
      . "$0"
      export HOME_STACK_PARENT_DOMAIN=test.example
      export HOME_STACK_TAILNET_IP=100.64.0.8
      export HOME_STACK_ACME_EMAIL=test@example.com
      export HOME_STACK_OWNER_HOME=/tmp
      export HOME_STACK_IDENTIFIER_PREFIX=test.example
      export HOME_STACK_ADMIN_USERNAME=admin
      home_stack_validate_mandatory && echo "OK"
    ' "$COMMON_SH" 2>&1
  ) && exit_code=0 || exit_code=$?

  [[ "$exit_code" -eq 0 ]] \
    || fail "home_stack_validate_mandatory should pass when all mandatory vars are set; got: $result"
  echo "$result" | grep -q "OK" \
    || fail "home_stack_validate_mandatory should not emit errors when all vars set; got: $result"
}

test_each_mandatory_key_individually() {
  local mandatory_keys=("HOME_STACK_PARENT_DOMAIN" "HOME_STACK_TAILNET_IP" "HOME_STACK_ACME_EMAIL" "HOME_STACK_OWNER_HOME" "HOME_STACK_IDENTIFIER_PREFIX" "HOME_STACK_ADMIN_USERNAME")

  for key_to_unset in "${mandatory_keys[@]}"; do
    local missing_output
    missing_output=$(
      env -i HOME=/tmp HOME_STACK_PROFILE=testprofile \
      bash -c '
        . "$0"
        export HOME_STACK_PARENT_DOMAIN=test.example
        export HOME_STACK_TAILNET_IP=100.64.0.8
        export HOME_STACK_ACME_EMAIL=test@example.com
        export HOME_STACK_OWNER_HOME=/tmp
        export HOME_STACK_IDENTIFIER_PREFIX=test.example
        export HOME_STACK_ADMIN_USERNAME=admin
        unset '"$key_to_unset"'
        home_stack_validate_mandatory
      ' "$COMMON_SH" 2>&1
    ) && fail "home_stack_validate_mandatory should fail when $key_to_unset is missing" || true

    echo "$missing_output" | grep -q "$key_to_unset" \
      || fail "home_stack_validate_mandatory should report missing key $key_to_unset; got: $missing_output"
  done
}

test_sync_with_no_mandatory_env_exits_nonzero
test_sync_with_partial_env_exits_nonzero_and_names_missing_key
test_server_with_no_mandatory_env_exits_nonzero
test_common_sh_validate_mandatory_reports_each_missing_key
test_common_sh_validate_mandatory_passes_when_all_set
test_each_mandatory_key_individually

echo "env-safety tests passed"
