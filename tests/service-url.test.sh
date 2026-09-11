#!/usr/bin/env bash
# Unit tests for common.sh's home_stack_service_url: reads the engine-written
# `url` field straight out of catalog.json (no shell-side hostname
# recomposition) for a routable subdomain, an absolute host, a disabled
# service, an unroutable (wildcard or missing subdomain/host) service, and a
# missing-service case.
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON_SH="$ROOT_DIR/portable/home-stack/scripts/lib/common.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

OWNER_HOME="$WORK/owner"
PROFILE_DIR="$WORK/profiles/test"
BUNDLE_DIR="$WORK/bundle"
mkdir -p "$OWNER_HOME" "$PROFILE_DIR" "$BUNDLE_DIR"

cat >"$PROFILE_DIR/home-stack.env" <<EOF
HOME_STACK_PARENT_DOMAIN=home.test.example
HOME_STACK_TAILNET_IP=100.64.0.8
HOME_STACK_ACME_EMAIL=admin@example.test
HOME_STACK_OWNER_HOME=$OWNER_HOME
HOME_STACK_IDENTIFIER_PREFIX=test.example
HOME_STACK_ADMIN_USERNAME=admin
EOF

# Shape matches the engine's actual catalog.json output (tests/golden/*):
# `url` present and non-empty for a routable, enabled, non-wildcard service;
# absent otherwise (disabled, unrouted, or wildcard). The shell never
# recomposes Subdomain/Host itself, so these fixtures deliberately include a
# disabled service that still carries a Subdomain -- it must NOT resolve.
cat >"$BUNDLE_DIR/catalog.json" <<'EOF'
{
  "pocket-id": {"DisplayName": "Pocket ID", "Subdomain": "id", "Host": "", "url": "https://id.home.test.example"},
  "external-app": {"DisplayName": "External", "Subdomain": "", "Host": "external.example.com", "url": "https://external.example.com"},
  "dev-gateway": {"DisplayName": "Dev Gateway", "Subdomain": "*.dev", "Host": ""},
  "internal-only": {"DisplayName": "Internal", "Subdomain": "", "Host": ""},
  "disabled-app": {"DisplayName": "Disabled App", "Subdomain": "disabled-app", "Host": "", "enabled": false}
}
EOF

run() {
  env -i HOME="$OWNER_HOME" \
    HOME_STACK_REPO_ROOT="$WORK" \
    HOME_STACK_PROFILE=test \
    HOME_STACK_BUNDLE_DIR="$BUNDLE_DIR" \
    bash -c '
      . "$0"
      home_stack_load_env >/dev/null
      home_stack_service_url "$1"
    ' "$COMMON_SH" "$1"
}

# 1. A `url` key present is printed verbatim -- no shell-side composition.
result="$(run pocket-id)" || fail "pocket-id lookup should succeed"
[[ "$result" == "https://id.home.test.example" ]] \
  || fail "expected https://id.home.test.example, got: $result"

# 2. An absolute-host service's `url` is likewise printed verbatim.
result="$(run external-app)" || fail "external-app lookup should succeed"
[[ "$result" == "https://external.example.com" ]] \
  || fail "expected https://external.example.com, got: $result"

# 3. A wildcard subdomain never gets a `url` from the engine -- absent means
#    unroutable, not an error to recompute.
if run dev-gateway >/dev/null 2>&1; then
  fail "dev-gateway (wildcard subdomain) should be unroutable"
fi

# 4. No subdomain and no host is unroutable.
if run internal-only >/dev/null 2>&1; then
  fail "internal-only (no subdomain/host) should be unroutable"
fi

# 5. A service absent from the catalog is unroutable, not an error.
if run does-not-exist >/dev/null 2>&1; then
  fail "a missing service should not resolve"
fi

# 6. A disabled service with a Subdomain set still has no `url` (the engine
#    omits it for enabled: false) -- the shell must not fall back to
#    recomposing Subdomain+parent_domain itself.
if run disabled-app >/dev/null 2>&1; then
  fail "disabled-app (enabled: false, Subdomain set) should be unroutable"
fi

echo "PASS service-url.test.sh"
