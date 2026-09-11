#!/usr/bin/env bash
# Engine output determinism (snapshot) test.
# For each fixture profile, syncs to a temp dir and diffs against tests/golden/<fixture>/.
# Use REGEN=1 to update goldens.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GOLDEN_ROOT="$REPO_ROOT/tests/golden"
FIXTURES=(acme beta gamma delta epsilon)

ADMIN_DIR="$REPO_ROOT/portable/home-stack/admin"

# Build the admin binary into a tempdir.
WORK=$(mktemp -d)
WORK=$(cd "$WORK" && pwd)
trap 'rm -rf "$WORK"' EXIT

ADMIN_BIN="$WORK/home-stack-admin"
( cd "$ADMIN_DIR" && go build -o "$ADMIN_BIN" . )

fail() { echo "FAIL: $*" >&2; exit 1; }

sanitize() {
  local file="$1"
  if [[ -f "$file" ]]; then
    # 1. Replace the CURRENT run's WORK path.
    sed "s|$WORK|__WORK__|g" "$file" > "$file.tmp" && mv "$file.tmp" "$file"
    # 2. Replace any path matching the macOS/Linux temp dir pattern with __WORK__.
    # This helps when goldens have absolute paths from a previous run.
    sed -E "s|/var/folders/[^/]+/[^/]+/T/tmp\.[A-Za-z0-9]+|__WORK__|g" "$file" > "$file.tmp" && mv "$file.tmp" "$file"
    sed -E "s|/tmp/tmp\.[A-Za-z0-9]+|__WORK__|g" "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  fi
}

for FIXTURE in "${FIXTURES[@]}"; do
  FIXTURE_DIR="$REPO_ROOT/tests/fixtures/profile-$FIXTURE"
  GOLDEN_DIR="$GOLDEN_ROOT/$FIXTURE"
  
  # Stage the fixture profile inside an isolated repo-root copy.
  STAGE="$WORK/repo-$FIXTURE"
  mkdir -p "$STAGE/profiles/$FIXTURE"
  mkdir -p "$STAGE/portable/home-stack/launchd"
  mkdir -p "$STAGE/portable/home-stack/admin"
  mkdir -p "$STAGE/portable/home-stack/scripts"

  cp "$FIXTURE_DIR/services.yaml" "$STAGE/profiles/$FIXTURE/services.yaml"

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
  set +a

  "$ADMIN_BIN" sync > /dev/null

  # Sanitize generated files to remove dynamic absolute paths.
  sanitize "$STAGE/portable/home-stack/Caddyfile"
  sanitize "$STAGE/portable/home-stack/catalog.json"
  shopt -s nullglob
  for plist in "$STAGE/portable/home-stack/launchd"/*.plist "$STAGE/portable/home-stack/launchd/daemons"/*.plist; do
    sanitize "$plist"
  done
  shopt -u nullglob

  # Source files to check.
  # Caddyfile, catalog.json, and launchd/*.plist.
  
  if [[ "${REGEN:-0}" == "1" ]]; then
    echo "Regenerating goldens for $FIXTURE..."
    rm -rf "$GOLDEN_DIR"
    mkdir -p "$GOLDEN_DIR/launchd/daemons"
    cp "$STAGE/portable/home-stack/Caddyfile" "$GOLDEN_DIR/"
    cp "$STAGE/portable/home-stack/catalog.json" "$GOLDEN_DIR/"
    cp "$STAGE/portable/home-stack/launchd"/*.plist "$GOLDEN_DIR/launchd/"
    shopt -s nullglob
    DAEMON_GOLD=("$STAGE/portable/home-stack/launchd/daemons"/*.plist)
    shopt -u nullglob
    if [[ ${#DAEMON_GOLD[@]} -gt 0 ]]; then
      cp "${DAEMON_GOLD[@]}" "$GOLDEN_DIR/launchd/daemons/"
    fi
  else
    if [[ ! -d "$GOLDEN_DIR" ]]; then
        fail "Golden directory $GOLDEN_DIR missing. Run with REGEN=1 to create it."
    fi
    
    # Compare files.
    # Sanitize goldens into a temp location for comparison.
    GOLDEN_SAN="$WORK/golden-san-$FIXTURE"
    mkdir -p "$GOLDEN_SAN/launchd"
    
    cp "$GOLDEN_DIR/Caddyfile" "$GOLDEN_SAN/Caddyfile"
    sanitize "$GOLDEN_SAN/Caddyfile"
    diff -u "$GOLDEN_SAN/Caddyfile" "$STAGE/portable/home-stack/Caddyfile" || fail "Caddyfile mismatch for $FIXTURE. Re-run with REGEN=1 to update goldens."
    
    cp "$GOLDEN_DIR/catalog.json" "$GOLDEN_SAN/catalog.json"
    sanitize "$GOLDEN_SAN/catalog.json"
    diff -u "$GOLDEN_SAN/catalog.json" "$STAGE/portable/home-stack/catalog.json" || fail "catalog.json mismatch for $FIXTURE. Re-run with REGEN=1 to update goldens."
    
    # Check plists (agents and daemons/ subtree).
    EXPECTED_PLISTS=$(cd "$GOLDEN_DIR/launchd" && find . -name "*.plist" | sort)
    ACTUAL_PLISTS=$(cd "$STAGE/portable/home-stack/launchd" && find . -name "*.plist" | sort)

    if [[ "$EXPECTED_PLISTS" != "$ACTUAL_PLISTS" ]]; then
        echo "Plist list mismatch for $FIXTURE."
        echo "Expected: $EXPECTED_PLISTS"
        echo "Actual: $ACTUAL_PLISTS"
        fail "Plist set mismatch. Re-run with REGEN=1."
    fi

    mkdir -p "$GOLDEN_SAN/launchd/daemons"
    for plist in $EXPECTED_PLISTS; do
        cp "$GOLDEN_DIR/launchd/$plist" "$GOLDEN_SAN/launchd/$plist"
        sanitize "$GOLDEN_SAN/launchd/$plist"
        diff -u "$GOLDEN_SAN/launchd/$plist" "$STAGE/portable/home-stack/launchd/$plist" || fail "Plist $plist mismatch for $FIXTURE. Re-run with REGEN=1."
    done
  fi
done

echo "PASS engine-snapshot.test.sh"
