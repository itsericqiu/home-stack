#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname "$0")/.." && pwd)"

echo "=== Test 12: Plist Lint ==="

# Sanitize HOME_STACK_* vars that may leak from the user's environment
while IFS='=' read -r key _; do
  case "$key" in HOME_STACK_*|CLOUDFLARE_API_TOKEN) unset "$key" ;; esac
done < <(env)

# Setup temp staging area
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# Copy necessary scripts
mkdir -p "$STAGE/portable/home-stack/scripts/lib"
cp "$ROOT_DIR/portable/home-stack/scripts/lib/common.sh" "$STAGE/portable/home-stack/scripts/lib/common.sh"

# Build admin for sync
ADMIN_BIN="$STAGE/home-stack-admin"
echo "Building admin..."
( cd "$ROOT_DIR/portable/home-stack/admin" && go build -o "$ADMIN_BIN" . )

# Choose linter
LINTER=""
if command -v plutil >/dev/null 2>&1; then
  LINTER="plutil -lint"
elif command -v xmllint >/dev/null 2>&1; then
  LINTER="xmllint --noout"
else
  echo "SKIP: neither plutil nor xmllint found"
  exit 0
fi
echo "Using linter: $LINTER"

for fixture in acme beta gamma delta; do
  echo "Checking fixture: $fixture"
  
  # Stage the fixture
  mkdir -p "$STAGE/profiles/$fixture"
  cp "$ROOT_DIR/tests/fixtures/profile-$fixture/services.yaml" "$STAGE/profiles/$fixture/services.yaml"
  
  # Substitute __OWNER_HOME__ in the env fixture.
  OWNER_HOME="$STAGE/owner-$fixture"
  mkdir -p "$OWNER_HOME/.config/home-stack"
  sed "s|__OWNER_HOME__|$OWNER_HOME|g" "$ROOT_DIR/tests/fixtures/profile-$fixture/home-stack.env" > "$STAGE/profiles/$fixture/home-stack.env"
  
  # Mock env.local
  cat > "$OWNER_HOME/.config/home-stack/env.local" <<EOF
HOME_STACK_ADMIN_PASSWORD=testpassword
EOF

  # Load env using the common.sh from STAGE
  # We need to do this carefully as it might exit if things are not right
  (
    . "$STAGE/portable/home-stack/scripts/lib/common.sh"
    export HOME_STACK_REPO_ROOT="$STAGE"
    export HOME_STACK_BUNDLE_DIR="$STAGE/portable/home-stack"
    export HOME_STACK_PROFILE="$fixture"
    export HOME_STACK_OWNER_HOME="$OWNER_HOME"
    export HOME_STACK_CONFIG_DIR="$OWNER_HOME/.config/home-stack"

    home_stack_load_env >/dev/null 2>&1

  # Sync into a dedicated bundle
  # The Go binary looks for ../../profiles relative to HOME_STACK_BUNDLE_DIR
  BUNDLE_DIR="$STAGE/portable/home-stack"
  mkdir -p "$BUNDLE_DIR"

  # Stub out reload-caddy.sh
  mkdir -p "$BUNDLE_DIR/scripts"
  cat > "$BUNDLE_DIR/scripts/reload-caddy.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$BUNDLE_DIR/scripts/reload-caddy.sh"

  HOME_STACK_BUNDLE_DIR="$BUNDLE_DIR" "$ADMIN_BIN" sync >/dev/null

    # Lint plists
    PLIST_DIR="$BUNDLE_DIR/launchd"
    if [[ ! -d "$PLIST_DIR" ]]; then
      echo "No plists generated for $fixture (skipped)"
      exit 0
    fi

    for plist in "$PLIST_DIR"/*.plist; do
      if [[ ! -f "$plist" ]]; then continue; fi
      # echo "  Linting $(basename "$plist")..."
      if ! $LINTER "$plist" >/dev/null 2>&1; then
        echo "FAIL: Lint failed for $plist"
        exit 1
      fi
    done
  )
done

echo "Test 12 passed"
