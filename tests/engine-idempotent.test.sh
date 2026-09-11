#!/usr/bin/env bash
# Engine idempotency test.
# Runs hs sync twice against the acme fixture and asserts byte-identical output.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_DIR="$REPO_ROOT/tests/fixtures/profile-acme"
ADMIN_DIR="$REPO_ROOT/portable/home-stack/admin"

WORK=$(mktemp -d)
WORK=$(cd "$WORK" && pwd)
trap 'rm -rf "$WORK"' EXIT

ADMIN_BIN="$WORK/home-stack-admin"
( cd "$ADMIN_DIR" && go build -o "$ADMIN_BIN" . )

fail() { echo "FAIL: $*" >&2; exit 1; }

STAGE="$WORK/repo-acme"
mkdir -p "$STAGE/profiles/acme"
mkdir -p "$STAGE/portable/home-stack/launchd"
mkdir -p "$STAGE/portable/home-stack/admin"
mkdir -p "$STAGE/portable/home-stack/scripts"

cp "$FIXTURE_DIR/services.yaml" "$STAGE/profiles/acme/services.yaml"

OWNER_HOME="$WORK/owner-acme"
mkdir -p "$OWNER_HOME"
sed "s|__OWNER_HOME__|$OWNER_HOME|g" "$FIXTURE_DIR/home-stack.env" > "$WORK/profile-acme.env"

cat > "$STAGE/portable/home-stack/scripts/reload-caddy.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$STAGE/portable/home-stack/scripts/reload-caddy.sh"

sanitize() {
  local file="$1"
  if [[ -f "$file" ]]; then
    sed "s|$WORK|__WORK__|g" "$file" > "$file.tmp" && mv "$file.tmp" "$file"
    sed -E "s|/var/folders/[^/]+/[^/]+/T/tmp\.[A-Za-z0-9]+|__WORK__|g" "$file" > "$file.tmp" && mv "$file.tmp" "$file"
    sed -E "s|/tmp/tmp\.[A-Za-z0-9]+|__WORK__|g" "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  fi
}

run_sync() {
  set -a
  . "$WORK/profile-acme.env"
  HOME_STACK_PROFILE=acme
  HOME_STACK_BUNDLE_DIR="$STAGE/portable/home-stack"
  set +a
  "$ADMIN_BIN" sync >/dev/null
}

# First sync: keep a copy of output for comparison.
run_sync

FIRST_RUN="$WORK/first-run"
mkdir -p "$FIRST_RUN"
cp "$STAGE/portable/home-stack/Caddyfile" "$FIRST_RUN/"
cp "$STAGE/portable/home-stack/catalog.json" "$FIRST_RUN/"
cp -R "$STAGE/portable/home-stack/launchd" "$FIRST_RUN/launchd"

sanitize "$FIRST_RUN/Caddyfile"
sanitize "$FIRST_RUN/catalog.json"
shopt -s nullglob
for plist in "$FIRST_RUN/launchd"/*.plist "$FIRST_RUN/launchd/daemons"/*.plist; do
  sanitize "$plist"
done
shopt -u nullglob

# Second sync to same dir (overwrites).
run_sync

sanitize "$STAGE/portable/home-stack/Caddyfile"
sanitize "$STAGE/portable/home-stack/catalog.json"
shopt -s nullglob
for plist in "$STAGE/portable/home-stack/launchd"/*.plist "$STAGE/portable/home-stack/launchd/daemons"/*.plist; do
  sanitize "$plist"
done
shopt -u nullglob

diff -u "$FIRST_RUN/Caddyfile" "$STAGE/portable/home-stack/Caddyfile" >&2 || fail "Caddyfile differs between runs — sync is not idempotent"
diff -u "$FIRST_RUN/catalog.json" "$STAGE/portable/home-stack/catalog.json" >&2 || fail "catalog.json differs between runs — sync is not idempotent"

EXPECTED=$(cd "$FIRST_RUN/launchd" && find . -name "*.plist" | sort)
ACTUAL=$(cd "$STAGE/portable/home-stack/launchd" && find . -name "*.plist" | sort)
if [[ "$EXPECTED" != "$ACTUAL" ]]; then
  echo "Plist set mismatch between runs."
  echo "Run 1: $EXPECTED"
  echo "Run 2: $ACTUAL"
  fail "Plist set differs between runs — sync is not idempotent"
fi

for plist in $EXPECTED; do
  diff -u "$FIRST_RUN/launchd/$plist" "$STAGE/portable/home-stack/launchd/$plist" >&2 \
    || fail "Plist $plist differs between runs — sync is not idempotent"
done

echo "PASS engine-idempotent.test.sh"
