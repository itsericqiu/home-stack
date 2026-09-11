#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON_SH="$ROOT_DIR/portable/home-stack/scripts/lib/common.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

setup_temp_env() {
  local tmp
  tmp="$(mktemp -d)"
  echo "$tmp"
}

cleanup_temp_env() {
  local tmp="$1"
  rm -rf "$tmp"
}

# Test Cases

test_layer2_only() {
  local tmp; tmp=$(setup_temp_env)
  trap 'cleanup_temp_env "$tmp"' RETURN

  local profile_dir="$tmp/profiles/test"
  mkdir -p "$profile_dir"
  cat >"$profile_dir/home-stack.env" <<EOF
export HOME_STACK_PARENT_DOMAIN=layer2.test
export HOME_STACK_TAILNET_IP=100.64.0.8
export HOME_STACK_ACME_EMAIL=test@example.com
export HOME_STACK_OWNER_HOME="$tmp"
export HOME_STACK_IDENTIFIER_PREFIX=test
export HOME_STACK_ADMIN_USERNAME=admin
EOF

  local result
  result=$(
    env -i HOME="$tmp" HOME_STACK_PROFILE=test HOME_STACK_REPO_ROOT="$tmp" \
    bash -c '
      . "$0"
      home_stack_load_env >/dev/null
      echo "$HOME_STACK_PARENT_DOMAIN"
    ' "$COMMON_SH"
  )
  [[ "$result" == "layer2.test" ]] || fail "Layer 2 only failed: expected layer2.test, got $result"
}

test_layer2_plus_3() {
  local tmp; tmp=$(setup_temp_env)
  trap 'cleanup_temp_env "$tmp"' RETURN

  local profile_dir="$tmp/profiles/test"
  mkdir -p "$profile_dir"
  cat >"$profile_dir/home-stack.env" <<EOF
export HOME_STACK_PARENT_DOMAIN=layer2.test
export HOME_STACK_TAILNET_IP=100.64.0.8
export HOME_STACK_ACME_EMAIL=test@example.com
export HOME_STACK_OWNER_HOME="$tmp"
export HOME_STACK_IDENTIFIER_PREFIX=test
export HOME_STACK_ADMIN_USERNAME=admin
EOF

  local config_dir="$tmp/.config/home-stack"
  mkdir -p "$config_dir"
  cat >"$config_dir/config.env" <<EOF
export HOME_STACK_PARENT_DOMAIN=layer3.test
EOF

  local result
  result=$(
    env -i HOME="$tmp" HOME_STACK_PROFILE=test HOME_STACK_REPO_ROOT="$tmp" \
    bash -c '
      . "$0"
      home_stack_load_env >/dev/null
      echo "$HOME_STACK_PARENT_DOMAIN"
    ' "$COMMON_SH"
  )
  [[ "$result" == "layer3.test" ]] || fail "Layer 3 override failed: expected layer3.test, got $result"
}

test_layer2_plus_4() {
  local tmp; tmp=$(setup_temp_env)
  trap 'cleanup_temp_env "$tmp"' RETURN

  local profile_dir="$tmp/profiles/test"
  mkdir -p "$profile_dir"
  cat >"$profile_dir/home-stack.env" <<EOF
export HOME_STACK_PARENT_DOMAIN=layer2.test
export HOME_STACK_TAILNET_IP=100.64.0.8
export HOME_STACK_ACME_EMAIL=test@example.com
export HOME_STACK_OWNER_HOME="$tmp"
export HOME_STACK_IDENTIFIER_PREFIX=test
export HOME_STACK_ADMIN_USERNAME=admin
EOF

  local config_dir="$tmp/.config/home-stack"
  mkdir -p "$config_dir"
  cat >"$config_dir/env.local" <<EOF
export HOME_STACK_SECRET=secret4
EOF

  local result
  result=$(
    env -i HOME="$tmp" HOME_STACK_PROFILE=test HOME_STACK_REPO_ROOT="$tmp" \
    bash -c '
      . "$0"
      home_stack_load_env >/dev/null
      echo "$HOME_STACK_PARENT_DOMAIN|$HOME_STACK_SECRET"
    ' "$COMMON_SH"
  )
  [[ "$result" == "layer2.test|secret4" ]] || fail "Layer 4 secret failed: expected layer2.test|secret4, got $result"
}

test_layer4_attempts_identity_key() {
  local tmp; tmp=$(setup_temp_env)
  trap 'cleanup_temp_env "$tmp"' RETURN

  local profile_dir="$tmp/profiles/test"
  mkdir -p "$profile_dir"
  cat >"$profile_dir/home-stack.env" <<EOF
export HOME_STACK_PARENT_DOMAIN=layer2.test
export HOME_STACK_TAILNET_IP=100.64.0.8
export HOME_STACK_ACME_EMAIL=test@example.com
export HOME_STACK_OWNER_HOME="$tmp"
export HOME_STACK_IDENTIFIER_PREFIX=test
export HOME_STACK_ADMIN_USERNAME=admin
EOF

  local config_dir="$tmp/.config/home-stack"
  mkdir -p "$config_dir"
  # PARENT_DOMAIN is an identity key and should not be allowed in env.local
  cat >"$config_dir/env.local" <<EOF
export HOME_STACK_PARENT_DOMAIN=illegal.test
EOF

  local stderr_out
  stderr_out=$(
    env -i HOME="$tmp" HOME_STACK_PROFILE=test HOME_STACK_REPO_ROOT="$tmp" \
    bash -c '
      . "$0"
      home_stack_load_env
      echo "ENV_FILE: $HOME_STACK_ENV_FILE" >&2
      ls -l "$HOME_STACK_ENV_FILE" >&2
    ' "$COMMON_SH" 2>&1
  ) && fail "Layer 4 identity key override should have failed. Output: $stderr_out" || true

  echo "$stderr_out" | grep -q "identity key" || fail "Expected 'identity key' error in stderr, got: $stderr_out"
}

test_profile_dir_missing() {
  local tmp; tmp=$(setup_temp_env)
  trap 'cleanup_temp_env "$tmp"' RETURN

  local stderr_out
  stderr_out=$(
    env -i HOME="$tmp" HOME_STACK_PROFILE=missing HOME_STACK_REPO_ROOT="$tmp" \
    bash -c '
      . "$0"
      home_stack_load_env
    ' "$COMMON_SH" 2>&1
  ) && fail "Missing profile dir should have failed" || true

  echo "$stderr_out" | grep -q "hs init" || fail "Expected 'hs init' hint in stderr, got: $stderr_out"
}

test_default_profile_missing() {
  local tmp; tmp=$(setup_temp_env)
  trap 'cleanup_temp_env "$tmp"' RETURN

  local stderr_out
  stderr_out=$(
    env -i HOME="$tmp" HOME_STACK_REPO_ROOT="$tmp" USER=$(whoami) \
    bash -c '
      . "$0"
      home_stack_load_env
    ' "$COMMON_SH" 2>&1
  ) && fail "Missing default profile dir should have failed" || true

  echo "$stderr_out" | grep -q "does not exist" || fail "Expected profile not found error in stderr, got: $stderr_out"
}

# A symlinked profiles/<name> must resolve exactly like a real directory --
# this is the shape docs/PUBLIC_RELEASE.md §4 A4 documents for the owner's
# dotfiles overlay: profiles/<name> becomes a symlink into a private
# location, and every `-d` check in common.sh must follow it.
test_profile_dir_symlink() {
  local tmp; tmp=$(setup_temp_env)
  trap 'cleanup_temp_env "$tmp"' RETURN

  local real_profile_dir="$tmp/overlay/symlinked"
  mkdir -p "$real_profile_dir"
  cat >"$real_profile_dir/home-stack.env" <<EOF
export HOME_STACK_PARENT_DOMAIN=symlink.test
export HOME_STACK_TAILNET_IP=100.64.0.8
export HOME_STACK_ACME_EMAIL=test@example.com
export HOME_STACK_OWNER_HOME="$tmp"
export HOME_STACK_IDENTIFIER_PREFIX=test
export HOME_STACK_ADMIN_USERNAME=admin
EOF

  mkdir -p "$tmp/profiles"
  ln -s "$real_profile_dir" "$tmp/profiles/symlinked"

  local result
  result=$(
    env -i HOME="$tmp" HOME_STACK_PROFILE=symlinked HOME_STACK_REPO_ROOT="$tmp" \
    bash -c '
      . "$0"
      home_stack_load_env >/dev/null
      echo "$HOME_STACK_PARENT_DOMAIN"
    ' "$COMMON_SH"
  )
  [[ "$result" == "symlink.test" ]] || fail "Symlinked profile dir should resolve: expected symlink.test, got $result"
}

test_layer2_only
test_layer2_plus_3
test_layer2_plus_4
test_layer4_attempts_identity_key
test_profile_dir_missing
test_default_profile_missing
test_profile_dir_symlink

echo "env-layering tests passed"
