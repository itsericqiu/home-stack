#!/usr/bin/env bash
# Shared staging helper for the Darwin launchd integration tests
# (identifier-prefix-flow, service-lifecycle, install-launchd-e2e): each needs
# a fully isolated COPY of the repo's portable/, profiles/, and templates/
# trees plus a built admin binary and a stubbed reload-caddy.sh, so the test
# never reads or writes anything under the real repo and never actually
# reloads Caddy. This file is meant to be sourced, not executed.

if [[ -z "${BASH_VERSION:-}" ]]; then
  echo "tests/lib/stage.sh must be sourced from bash, not another shell" >&2
  return 1 2>/dev/null || exit 1
fi

if [[ -n "${HOME_STACK_STAGE_SH_LOADED:-}" ]]; then
  return 0
fi
HOME_STACK_STAGE_SH_LOADED=1

# home_stack_stage_repo <stage_dir> <root_dir>
#
# Creates <stage_dir>/repo: an rsync copy of <root_dir>/portable/ (excluding
# generated/built artifacts every caller regenerates fresh inside the stage --
# the production admin binary, any prior .test-build, the generated
# Caddyfile/catalog.json/launchd tree, and bin/, the gitignored ~300MB of
# locally xcaddy-built Caddy binaries) plus plain copies of profiles/ and
# templates/. Builds the admin binary into the staged bundle and stubs
# reload-caddy.sh there so `hs sync` never touches the real Caddy.
#
# Prints the staged repo path (<stage_dir>/repo) on stdout; all progress
# output goes to stderr so callers can safely capture the path with
# REPO="$(home_stack_stage_repo "$STAGE" "$ROOT_DIR")".
home_stack_stage_repo() {
  local stage_dir="$1" root_dir="$2"
  local repo="$stage_dir/repo"

  mkdir -p "$repo/portable"
  rsync -a \
    --exclude 'home-stack/admin/home-stack-admin' \
    --exclude 'home-stack/admin/.test-build' \
    --exclude 'home-stack/Caddyfile' \
    --exclude 'home-stack/catalog.json' \
    --exclude 'home-stack/launchd' \
    --exclude 'home-stack/bin' \
    "$root_dir/portable/" "$repo/portable/"
  cp -R "$root_dir/profiles" "$repo/profiles"
  cp -R "$root_dir/templates" "$repo/templates"

  echo "Building admin..." >&2
  (cd "$repo/portable/home-stack/admin" && go build -o home-stack-admin .)

  local reload_script="$repo/portable/home-stack/scripts/reload-caddy.sh"
  cat > "$reload_script" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$reload_script"

  printf '%s' "$repo"
}
