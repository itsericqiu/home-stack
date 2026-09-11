#!/usr/bin/env bash
# hs upgrade: scripts/lib/upgrade.sh unit + integration coverage. Linux-safe --
# no launchctl, no real network. Every network/binary call goes through a
# fake on PATH (gh, npm, curl) or an overridable HOME_STACK_UPGRADE_* variable
# so this never touches a real GitHub/npm endpoint.
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- Fake gh/npm on PATH, plus a stub service-launchd.sh and empty bin/ -----

SHIM="$WORK/shim"
mkdir -p "$SHIM"

cat >"$SHIM/gh" <<'EOF'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"repos/acme/svc-ok/releases/latest"*)          echo "v1.0.0" ;;
  *"repos/acme/svc-behind/releases/latest"*)       echo "v1.2.0" ;;
  *"repos/acme/svc-release/releases/latest"*)      echo "v1.2.0" ;;
  *"repos/acme/svc-release-fail/releases/latest"*) echo "v1.2.0" ;;
  *"checksums.txt"*|*".sha256"*) echo "" ;;
  *"repos/acme/svc-release/releases/tags/v1.2.0"*"assets"*)      echo "https://example.test/dl/svc-release-1.2.0" ;;
  *"repos/acme/svc-release-fail/releases/tags/v1.2.0"*"assets"*) echo "https://example.test/dl/svc-release-fail-1.2.0" ;;
  # Anything unmatched fails with a non-zero exit, same as the real `gh api`
  # against a repo/release/asset that does not exist -- exercised by the
  # "resolving the latest tag/version fails cleanly" regression test below.
  *) exit 1 ;;
esac
EOF
chmod +x "$SHIM/gh"

cat >"$SHIM/npm" <<'EOF'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"view acme-ahead version"*)    echo "1.5.0" ;;
  *"view acme-unknown version"*)  echo "" ;;
  # Anything unmatched fails with a non-zero exit, same as the real `npm
  # view` against an unpublished package.
  *) exit 1 ;;
esac
EOF
chmod +x "$SHIM/npm"

cat >"$SHIM/fake-version-100" <<'EOF'
#!/usr/bin/env bash
echo "widget version 1.0.0"
EOF
chmod +x "$SHIM/fake-version-100"

cat >"$SHIM/fake-version-150" <<'EOF'
#!/usr/bin/env bash
echo "widget version 1.5.0"
EOF
chmod +x "$SHIM/fake-version-150"

cat >"$SHIM/fake-version-122" <<'EOF'
#!/usr/bin/env bash
echo "widget version 1.2.0"
EOF
chmod +x "$SHIM/fake-version-122"

cat >"$SHIM/fake-version-garbage" <<'EOF'
#!/usr/bin/env bash
echo "no version information available"
EOF
chmod +x "$SHIM/fake-version-garbage"

# curl fake: writes deterministic content for a download URL, fails (as if
# 404) for any checksum-shaped URL so the github-release path takes its
# "no checksums found" branch rather than needing a real shasum fixture.
cat >"$SHIM/curl" <<'EOF'
#!/usr/bin/env bash
outfile=""
url="${*: -1}"
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  if [[ "${args[$i]}" == "-o" ]]; then
    outfile="${args[$((i + 1))]}"
  fi
done
case "$url" in
  *checksums*|*sha256*) exit 22 ;;
  *)
    if [[ -n "$outfile" ]]; then
      printf '#!/bin/sh\necho fake-binary\n' > "$outfile"
    fi
    exit 0
    ;;
esac
EOF
chmod +x "$SHIM/curl"

mkdir -p "$WORK/scripts"
cat >"$WORK/scripts/service-launchd.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$WORK/scripts/service-launchd.sh"

# --- Environment lib/upgrade.sh actually reads ------------------------------

BUNDLE="$WORK/bundle"
CONFIG_DIR="$WORK/config"
mkdir -p "$BUNDLE/bin" "$CONFIG_DIR"

export PATH="$SHIM:$PATH"
export HOME_STACK_BUNDLE_DIR="$BUNDLE"
export HOME_STACK_SCRIPTS_DIR="$WORK/scripts"
export HOME_STACK_CONFIG_DIR="$CONFIG_DIR"
export HOME_STACK_UPGRADE_PYTHON3="${HOME_STACK_UPGRADE_PYTHON3:-python3}"

# shellcheck source=../portable/home-stack/scripts/lib/upgrade.sh
. "$ROOT_DIR/portable/home-stack/scripts/lib/upgrade.sh"

# --- Pure function unit tests ------------------------------------------------

[[ "$(home_stack_upgrade_extract_version 'pocket-id version v1.9.0')" == "1.9.0" ]] \
  || fail "extract_version should find a dotted semver"
[[ "$(home_stack_upgrade_extract_version 'commit abcdef01234567 deployed')" == "abcdef01234567" ]] \
  || fail "extract_version should fall back to a hex commit"
if home_stack_upgrade_extract_version 'no version here' >/dev/null; then
  fail "extract_version should fail when nothing matches"
fi
echo "[✓] extract_version"

[[ "$(home_stack_upgrade_resolve_asset 'widget_{arch}_{version}' 'v1.2.0' 'arm64')" == "widget_arm64_1.2.0" ]] \
  || fail "resolve_asset should substitute {version} (v-stripped) and {arch}"
echo "[✓] resolve_asset"

[[ "$(home_stack_upgrade_classify_drift '1.0.0' '1.0.0' '1.0.0')" == "ok" ]] || fail "drift: live==pin==latest should be ok"
[[ "$(home_stack_upgrade_classify_drift '1.0.0' '1.0.0' '1.2.0')" == "behind" ]] || fail "drift: pin older than latest should be behind"
[[ "$(home_stack_upgrade_classify_drift '1.5.0' '1.0.0' '1.5.0')" == "ahead-of-pin" ]] || fail "drift: live newer than pin should be ahead-of-pin"
[[ "$(home_stack_upgrade_classify_drift '' '1.0.0' '1.0.0')" == "unknown" ]] || fail "drift: missing live should be unknown"
[[ "$(home_stack_upgrade_classify_drift '1.0.0' '' '')" == "unknown" ]] || fail "drift: missing latest should be unknown"
echo "[✓] classify_drift"

# --- hs upgrade status: drift classification across a fixture catalog ------

cat >"$BUNDLE/catalog.json" <<'EOF'
{
  "svc-ok": {
    "install": {"method": "github-release", "source": "acme/svc-ok", "pin": "1.0.0", "version_cmd": "fake-version-100"}
  },
  "svc-behind": {
    "install": {"method": "github-release", "source": "acme/svc-behind", "pin": "1.0.0", "version_cmd": "fake-version-100"}
  },
  "svc-ahead": {
    "install": {"method": "npm-global", "source": "acme-ahead", "pin": "1.0.0", "version_cmd": "fake-version-150"}
  },
  "svc-unknown": {
    "install": {"method": "npm-global", "source": "acme-unknown", "pin": "1.0.0", "version_cmd": "fake-version-garbage"}
  }
}
EOF

status_out="$(home_stack_upgrade_status)"
# LATEST comes straight from `gh ... --jq .tag_name` for github-release (a
# "v"-prefixed tag) but from `npm view ... version` for npm-global (no "v");
# classify_drift strips the prefix internally, so both compare correctly
# against the unprefixed pin -- only the displayed LATEST column differs.
echo "$status_out" | grep -qE '^svc-ok +github-release +1\.0\.0 +1\.0\.0 +v?1\.0\.0 +ok$' \
  || fail "expected svc-ok to classify as ok, got:
$status_out"
echo "$status_out" | grep -qE '^svc-behind +github-release +1\.0\.0 +1\.0\.0 +v?1\.2\.0 +behind$' \
  || fail "expected svc-behind to classify as behind, got:
$status_out"
echo "$status_out" | grep -qE '^svc-ahead +npm-global +1\.5\.0 +1\.0\.0 +1\.5\.0 +ahead-of-pin$' \
  || fail "expected svc-ahead to classify as ahead-of-pin, got:
$status_out"
echo "$status_out" | grep -qE '^svc-unknown +npm-global +unknown' \
  || fail "expected svc-unknown to classify as unknown, got:
$status_out"
echo "[✓] hs upgrade status: drift classification"

set +e
home_stack_upgrade_status >/dev/null
status_rc=$?
set -e
[[ $status_rc -eq 0 ]] || fail "status without --check must exit 0 even with a 'behind' entry, got rc=$status_rc"

set +e
home_stack_upgrade_status --check >/dev/null
check_rc=$?
set -e
[[ $check_rc -eq 1 ]] || fail "status --check must exit 1 when any service is behind, got rc=$check_rc"
echo "[✓] hs upgrade status --check exit codes"

# A catalog with nothing behind must exit 0 under --check too.
cat >"$BUNDLE/catalog.json" <<'EOF'
{
  "svc-ok": {
    "install": {"method": "github-release", "source": "acme/svc-ok", "pin": "1.0.0", "version_cmd": "fake-version-100"}
  }
}
EOF
set +e
home_stack_upgrade_status --check >/dev/null
ok_check_rc=$?
set -e
[[ $ok_check_rc -eq 0 ]] || fail "status --check must exit 0 when nothing is behind, got rc=$ok_check_rc"
echo "[✓] hs upgrade status --check exits 0 with no drift"

# --- github-release: --dry-run prints the resolved asset URL ---------------

cat >"$BUNDLE/catalog.json" <<'EOF'
{
  "svc-release": {
    "install": {
      "method": "github-release", "source": "acme/svc-release", "pin": "1.0.0",
      "version_cmd": "fake-version-122", "asset": "svc-release_{arch}", "binary": "bin/svc-release"
    }
  },
  "svc-release-fail": {
    "install": {
      "method": "github-release", "source": "acme/svc-release-fail", "pin": "1.0.0",
      "version_cmd": "fake-version-122", "asset": "svc-release-fail_{arch}", "binary": "bin/svc-release-fail"
    }
  },
  "hermes": {
    "install": {"method": "hermes-pinned", "source": "NousResearch/hermes-agent"}
  }
}
EOF

dry_out="$(home_stack_upgrade_apply svc-release --dry-run 2>&1)"
echo "$dry_out" | grep -q "https://example.test/dl/svc-release-1.2.0" \
  || fail "dry-run should print the resolved asset URL, got:
$dry_out"
echo "$dry_out" | grep -q "bin/svc-release" \
  || fail "dry-run should mention the install target path, got:
$dry_out"
[[ ! -f "$BUNDLE/bin/svc-release" ]] || fail "dry-run must not touch the filesystem"
echo "[✓] github-release --dry-run prints the resolved asset URL"

# --- github-release: simulated success writes the log and backs up .prev ---

printf '#!/bin/sh\necho old-binary\n' > "$BUNDLE/bin/svc-release"
chmod +x "$BUNDLE/bin/svc-release"

home_stack_upgrade_wait_healthy() { return 0; }

apply_out="$(home_stack_upgrade_apply svc-release --to v1.2.0 2>&1)"
apply_rc=$?
[[ $apply_rc -eq 0 ]] || fail "expected github-release apply to succeed, rc=$apply_rc, output:
$apply_out"
[[ -f "$BUNDLE/bin/svc-release.prev" ]] || fail "expected the previous binary to be backed up to .prev"
grep -q "old-binary" "$BUNDLE/bin/svc-release.prev" || fail ".prev should contain the pre-upgrade binary content"
grep -q "fake-binary" "$BUNDLE/bin/svc-release" || fail "the new binary should be installed in place"

[[ -f "$CONFIG_DIR/upgrade-log.jsonl" ]] || fail "expected upgrade-log.jsonl to be written"
log_line="$(tail -1 "$CONFIG_DIR/upgrade-log.jsonl")"
echo "$log_line" | grep -q '"service": "svc-release"' || fail "log line missing service, got: $log_line"
echo "$log_line" | grep -q '"method": "github-release"' || fail "log line missing method, got: $log_line"
echo "$log_line" | grep -q '"to": "v1.2.0"' || fail "log line missing to, got: $log_line"
echo "$log_line" | grep -q '"result": "success"' || fail "log line missing success result, got: $log_line"
echo "[✓] github-release apply: success installs, backs up .prev, and logs"

# --- github-release: a failed health check auto-reverts --------------------

printf '#!/bin/sh\necho old-binary-fail\n' > "$BUNDLE/bin/svc-release-fail"
chmod +x "$BUNDLE/bin/svc-release-fail"

home_stack_upgrade_wait_healthy() { return 1; }

set +e
fail_out="$(home_stack_upgrade_apply svc-release-fail --to v1.2.0 2>&1)"
fail_rc=$?
set -e
[[ $fail_rc -ne 0 ]] || fail "expected a failing health check to make hs upgrade exit non-zero"
echo "$fail_out" | grep -qi "reverting" || fail "expected a revert message, got:
$fail_out"
grep -q "old-binary-fail" "$BUNDLE/bin/svc-release-fail" \
  || fail "expected the binary to be reverted to its pre-upgrade content"
[[ ! -f "$BUNDLE/bin/svc-release-fail.prev" ]] || fail "expected .prev to be consumed by the revert"

fail_log_line="$(tail -1 "$CONFIG_DIR/upgrade-log.jsonl")"
echo "$fail_log_line" | grep -q '"service": "svc-release-fail"' || fail "log line missing service, got: $fail_log_line"
echo "$fail_log_line" | grep -q '"result": "reverted"' || fail "log line missing reverted result, got: $fail_log_line"
echo "[✓] github-release apply: failed health check auto-reverts .prev"

# Restore the real wait_healthy for anything below that might use it.
unset -f home_stack_upgrade_wait_healthy

# --- hermes-pinned: refuses a tag / moving ref for --to ---------------------

set +e
hermes_tag_out="$(home_stack_upgrade_apply hermes --to v2.14.0 2>&1)"
hermes_tag_rc=$?
set -e
[[ $hermes_tag_rc -ne 0 ]] || fail "hermes-pinned must refuse a tag for --to"
echo "$hermes_tag_out" | grep -qi "sha" || fail "expected the refusal to mention a commit SHA, got:
$hermes_tag_out"

set +e
hermes_missing_out="$(home_stack_upgrade_apply hermes 2>&1)"
hermes_missing_rc=$?
set -e
[[ $hermes_missing_rc -ne 0 ]] || fail "hermes-pinned must refuse when --to is absent"
echo "$hermes_missing_out" | grep -qi -- "--to" || fail "expected the refusal to mention --to, got:
$hermes_missing_out"

# A full 40-hex commit SHA is accepted at the refusal stage; --dry-run must
# not touch ~/.hermes.
valid_sha="0123456789abcdef0123456789abcdef01234567"
hermes_dry_out="$(home_stack_upgrade_apply hermes --to "$valid_sha" --dry-run 2>&1)"
hermes_dry_rc=$?
[[ $hermes_dry_rc -eq 0 ]] || fail "hermes-pinned --dry-run with a valid sha should succeed, got:
$hermes_dry_out"
echo "$hermes_dry_out" | grep -q "$valid_sha" || fail "dry-run should echo the target commit, got:
$hermes_dry_out"
echo "[✓] hermes-pinned refuses a tag / requires --to, accepts a full SHA in --dry-run"

# --- a service with no install: block is a clean error, not a crash --------

cat >"$BUNDLE/catalog.json" <<'EOF'
{"plain-svc": {"DisplayName": "Plain"}}
EOF
set +e
no_install_out="$(home_stack_upgrade_apply plain-svc 2>&1)"
no_install_rc=$?
set -e
[[ $no_install_rc -ne 0 ]] || fail "a service with no install: block should fail cleanly"
echo "$no_install_out" | grep -qi "install" || fail "error should mention install:, got: $no_install_out"
echo "[✓] hs upgrade on a service with no install: block fails cleanly"

# --- resolving the latest tag/version fails cleanly (not a crash) when the
# lookup tool has nothing to report and --to is absent -----------------------
#
# `hs` itself runs under `set -euo pipefail` and calls into this library as a
# bare top-level statement (`cmd_upgrade "$@"`, no enclosing `if`/`||`), so an
# unguarded `x="$(external_cmd)"` deep inside a method's target-resolution
# step would silently kill the entire `hs` process the instant the lookup
# legitimately came back empty (network down, no `gh` auth, unknown package)
# -- long before reaching the function's own "failed to resolve" error
# handling. Wrapping the call under test in `||`/`if`/`set +e` here would
# mask exactly that bug (bash suspends errexit for the whole left-hand side
# of such a construct, nested calls included), so this runs the call in a
# **child bash process that keeps set -e on with no such guard**, matching
# how `hs` actually invokes it, and inspects the child's own exit code and
# output from the outside. Last in the file since it replaces catalog.json
# wholesale.
cat >"$BUNDLE/catalog.json" <<'EOF'
{
  "svc-no-target": {
    "install": {"method": "github-release", "source": "acme/svc-nothing-to-find", "asset": "widget_{arch}", "binary": "bin/widget"}
  },
  "svc-no-target-npm": {
    "install": {"method": "npm-global", "source": "acme-nothing-to-find"}
  }
}
EOF

run_under_bare_errexit() {
  # Runs "home_stack_upgrade_apply $*" as a bare statement inside a fresh
  # bash -euo pipefail process (inheriting this test's exported env and
  # PATH shim), printing "<exit-code>:<combined output>".
  local rc out
  out="$(bash -euo pipefail -c '
    . "$1"
    shift
    home_stack_upgrade_apply "$@"
  ' _ "$ROOT_DIR/portable/home-stack/scripts/lib/upgrade.sh" "$@" 2>&1)" || rc=$?
  printf '%s:%s' "${rc:-0}" "$out"
}

result="$(run_under_bare_errexit svc-no-target --dry-run)"
no_target_rc="${result%%:*}"
no_target_out="${result#*:}"
[[ "$no_target_rc" -ne 0 ]] || fail "github-release with no resolvable target and no --to should fail, not silently succeed"
echo "$no_target_out" | grep -qi "failed to resolve" \
  || fail "expected a clear resolution-failure message under bare set -e (got exit $no_target_rc), meaning an unguarded lookup silently killed the process instead of returning its own error. Output:
$no_target_out"

result="$(run_under_bare_errexit svc-no-target-npm --dry-run)"
no_target_npm_rc="${result%%:*}"
no_target_npm_out="${result#*:}"
[[ "$no_target_npm_rc" -ne 0 ]] || fail "npm-global with no resolvable target and no --to should fail, not silently succeed"
echo "$no_target_npm_out" | grep -qi "failed to resolve" \
  || fail "expected a clear resolution-failure message under bare set -e (got exit $no_target_npm_rc), meaning an unguarded lookup silently killed the process instead of returning its own error. Output:
$no_target_npm_out"
echo "[✓] an unresolvable latest-version lookup fails cleanly under bare set -e instead of silently killing the process"

echo "PASS hs-upgrade.test.sh"
