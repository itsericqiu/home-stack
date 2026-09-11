#!/usr/bin/env bash
# Phase 1 portability test.
# Drives `home-stack-admin sync` against multiple fixture profiles,
# asserts generated Caddyfile/catalog.json/launchd plists use the fixture's
# values and contain zero maintainer-specific strings.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADMIN_DIR="$REPO_ROOT/portable/home-stack/admin"
FIXTURES=(acme beta gamma delta epsilon)

# shellcheck source=tests/lib/hygiene-patterns.sh
. "$REPO_ROOT/tests/lib/hygiene-patterns.sh"
# Owner-specific identifiers come from an optional private file (see
# docs/PUBLIC_RELEASE.md §4 A3); this scan runs fine without one since the
# fixtures below are synthetic, but load it too for defense in depth.
# home_stack_hygiene_scan_file (used throughout below) reads the regex itself.
home_stack_hygiene_load_private

# Build the admin binary into a tempdir.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

ADMIN_BIN="$WORK/home-stack-admin"
( cd "$ADMIN_DIR" && go build -o "$ADMIN_BIN" ./... )

fail() { echo "FAIL: $*" >&2; exit 1; }

for FIXTURE in "${FIXTURES[@]}"; do
  FIXTURE_DIR="$REPO_ROOT/tests/fixtures/profile-$FIXTURE"

  # Stage the fixture profile inside an isolated repo-root copy.
  STAGE="$WORK/repo-$FIXTURE"
  mkdir -p "$STAGE/portable/home-stack/launchd"
  mkdir -p "$STAGE/portable/home-stack/admin"
  mkdir -p "$STAGE/portable/home-stack/scripts"

  # The first fixture exercises HOME_STACK_PROFILES_DIR: the profile lives
  # outside the staged bundle entirely (no profiles/ under $STAGE at all),
  # proving the override -- not just the bundleDir-relative default -- reaches
  # the engine end to end (docs/PUBLIC_RELEASE.md §4 A1). Every other fixture
  # keeps exercising the default profiles/<name> resolution alongside it.
  if [[ "$FIXTURE" == "${FIXTURES[0]}" ]]; then
    PROFILES_DIR_OVERRIDE="$WORK/profiles-override-$FIXTURE"
    mkdir -p "$PROFILES_DIR_OVERRIDE/$FIXTURE"
    cp "$FIXTURE_DIR/services.yaml" "$PROFILES_DIR_OVERRIDE/$FIXTURE/services.yaml"
  else
    PROFILES_DIR_OVERRIDE=""
    mkdir -p "$STAGE/profiles/$FIXTURE"
    cp "$FIXTURE_DIR/services.yaml" "$STAGE/profiles/$FIXTURE/services.yaml"
  fi

  # Substitute __OWNER_HOME__ in the env fixture.
  OWNER_HOME="$WORK/owner-$FIXTURE"
  mkdir -p "$OWNER_HOME"
  sed "s|__OWNER_HOME__|$OWNER_HOME|g" "$FIXTURE_DIR/home-stack.env" > "$WORK/profile-$FIXTURE.env"

  # Stub out reload-caddy.sh.
  cat > "$STAGE/portable/home-stack/scripts/reload-caddy.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$STAGE/portable/home-stack/scripts/reload-caddy.sh"

  # Sync.
  set -a
  . "$WORK/profile-$FIXTURE.env"
  HOME_STACK_PROFILE=$FIXTURE
  HOME_STACK_BUNDLE_DIR="$STAGE/portable/home-stack"
  if [[ -n "$PROFILES_DIR_OVERRIDE" ]]; then
    HOME_STACK_PROFILES_DIR="$PROFILES_DIR_OVERRIDE"
  else
    unset HOME_STACK_PROFILES_DIR
  fi
  set +a

  "$ADMIN_BIN" sync > /dev/null

  CADDYFILE="$STAGE/portable/home-stack/Caddyfile"
  CATALOG="$STAGE/portable/home-stack/catalog.json"
  LAUNCHD_DIR="$STAGE/portable/home-stack/launchd"

  [[ -s "$CADDYFILE" ]] || fail "Caddyfile not generated for $FIXTURE"
  [[ -s "$CATALOG" ]] || fail "catalog.json not generated for $FIXTURE"

  # 1. Caddyfile contains fixture values.
  DOMAIN=$(grep "HOME_STACK_PARENT_DOMAIN" "$WORK/profile-$FIXTURE.env" | cut -d= -f2)
  EMAIL=$(grep "HOME_STACK_ACME_EMAIL" "$WORK/profile-$FIXTURE.env" | cut -d= -f2)
  IP=$(grep "HOME_STACK_TAILNET_IP" "$WORK/profile-$FIXTURE.env" | cut -d= -f2)
  PREFIX=$(grep "HOME_STACK_IDENTIFIER_PREFIX" "$WORK/profile-$FIXTURE.env" | cut -d= -f2)

  grep -q "$DOMAIN" "$CADDYFILE" || fail "Caddyfile missing parent_domain $DOMAIN for $FIXTURE"
  grep -q "$EMAIL" "$CADDYFILE" || fail "Caddyfile missing acme email $EMAIL for $FIXTURE"
  grep -q "$IP" "$CADDYFILE" || fail "Caddyfile missing tailnet IP $IP for $FIXTURE"

  # 2. Caddyfile must NOT contain any hygiene-pattern identifier (documented
  # placeholders like /Users/alice or admin@acme.test don't count as leaks;
  # home_stack_hygiene_scan_file strips those before matching).
  CADDYFILE_HITS="$(home_stack_hygiene_scan_file "$CADDYFILE")"
  if [[ -n "$CADDYFILE_HITS" ]]; then
    echo "Caddyfile contains hygiene-pattern strings for $FIXTURE:" >&2
    echo "$CADDYFILE_HITS" >&2
    fail "Caddyfile leaks identity values for $FIXTURE"
  fi

  # 3. Cross-fixture leakage check.
  for OTHER in "${FIXTURES[@]}"; do
    if [[ "$OTHER" == "$FIXTURE" ]]; then continue; fi
    OTHER_DOMAIN=$(grep "HOME_STACK_PARENT_DOMAIN" "$REPO_ROOT/tests/fixtures/profile-$OTHER/home-stack.env" | cut -d= -f2)
    if grep -q "$OTHER_DOMAIN" "$CADDYFILE"; then
        fail "Caddyfile for $FIXTURE leaks $OTHER domain $OTHER_DOMAIN"
    fi
  done

  # 4. Plist filenames use the identifier prefix.
  ls "$LAUNCHD_DIR" | grep -q "^$PREFIX\\.home-stack\\." || fail "no plists with $PREFIX prefix for $FIXTURE"

  # 5. Plist Label values use identifier prefix (agents and daemons).
  shopt -s nullglob
  for plist in "$LAUNCHD_DIR"/*.plist "$LAUNCHD_DIR/daemons"/*.plist; do
    grep -q "<string>$PREFIX.home-stack" "$plist" || fail "plist $plist missing $PREFIX Label for $FIXTURE"
    if [[ -n "$(home_stack_hygiene_scan_file "$plist")" ]]; then
      fail "plist $plist leaks identity values for $FIXTURE"
    fi
  done
  shopt -u nullglob

  # 6. caddy validate (best-effort).
  #
  # Prefer the stack's own binary over whatever `caddy` is on PATH. Generated
  # config uses plugin directives (`tailscale_auth` for `auth:` entries, the
  # cloudflare DNS provider for TLS), and a stock Caddy rejects them -- so
  # validating with the wrong binary reports a failure that says nothing about
  # the config. Skipping when no capable binary exists is deliberate: this step
  # has always been best-effort, and the engine-snapshot test is what actually
  # pins the generated output.
  CADDY_VALIDATOR=""
  for candidate in \
    "$REPO_ROOT/portable/home-stack/bin/caddy-cloudflare" \
    "$(command -v caddy-cloudflare 2>/dev/null || true)" \
    "$(command -v caddy 2>/dev/null || true)"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      if "$candidate" list-modules 2>/dev/null | grep -q '^http.authentication.providers.tailscale$'; then
        CADDY_VALIDATOR="$candidate"
        break
      fi
    fi
  done
  # `adapt`, not `validate`: validate provisions every module, and the
  # cloudflare DNS provider rejects any placeholder token at provision time, so
  # validate can never pass here without a real credential. adapt still resolves
  # each directive to its module -- it is what catches an `auth:` entry emitting
  # a directive the binary has no plugin for -- while stopping short of TLS
  # provisioning.
  if [[ -n "$CADDY_VALIDATOR" ]]; then
    if ! "$CADDY_VALIDATOR" adapt --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1; then
      fail "caddy adapt failed on generated Caddyfile for $FIXTURE (binary: $CADDY_VALIDATOR)"
    fi
  fi
done

# 7. The portable bundle itself must be identity-free: everything owner-
# specific belongs in profiles/ (or docs, which may use real values as
# examples). Catches hardcoded domains/labels in code, templates, and static
# assets that per-profile generation cannot fix. Skips generated artifacts
# (Caddyfile, catalog, plists, binaries, the nested runtime dir) and
# *_test.go, where the pattern legitimately appears in leak assertions like
# this one (tests/public-hygiene.test.sh is the repo-wide, tracked-file
# version of this same scan).
LEAKS=""
while IFS= read -r -d '' relpath; do
  if [[ -n "$(home_stack_hygiene_scan_file "$REPO_ROOT/$relpath")" ]]; then
    LEAKS="$LEAKS
$relpath"
  fi
done < <(cd "$REPO_ROOT" && find portable -type f \
  ! -path "portable/home-stack/home-stack/*" \
  ! -path "portable/home-stack/bin/*" \
  ! -path "*/node_modules/*" \
  ! -name "Caddyfile" ! -name "catalog.json" ! -name "*.plist" \
  ! -name "home-stack-admin" ! -name "*_test.go" ! -name "*.log" \
  -print0 2>/dev/null || true)
if [[ -n "$LEAKS" ]]; then
  fail "portable/ bundle contains hardcoded identity values in:
$LEAKS"
fi

echo "PASS profile-portability.test.sh"
