#!/usr/bin/env bash
# hs upgrade: reviewed, per-method upgrade procedures for services that carry
# an `install:` block in the registry (see docs/SERVICE_INTERFACE.md §4d and
# docs/RUNBOOK.md "Upgrade Workflow"). Sourced by scripts/hs; kept separate so
# it can be sourced and unit-tested on its own (tests/hs-upgrade.test.sh)
# without going through the full `hs` CLI dispatch.
#
# Every network/binary lookup goes through an overridable variable (defaults
# to the plain command name) so tests can stub it -- either by setting the
# variable directly or by putting a same-named fake earlier on PATH.

if [[ -z "${BASH_VERSION:-}" ]]; then
  echo "lib/upgrade.sh must be sourced from bash, not another shell" >&2
  return 1 2>/dev/null || exit 1
fi

if [[ -n "${HOME_STACK_UPGRADE_SH_LOADED:-}" ]]; then
  return 0
fi
HOME_STACK_UPGRADE_SH_LOADED=1

: "${HOME_STACK_UPGRADE_GH:=gh}"
: "${HOME_STACK_UPGRADE_NPM:=npm}"
: "${HOME_STACK_UPGRADE_CURL:=curl}"
: "${HOME_STACK_UPGRADE_INSTALL:=install}"
: "${HOME_STACK_UPGRADE_BREW:=brew}"
: "${HOME_STACK_UPGRADE_GIT:=git}"
: "${HOME_STACK_UPGRADE_GO:=go}"
: "${HOME_STACK_UPGRADE_COREPACK:=corepack}"
: "${HOME_STACK_UPGRADE_XCADDY:=xcaddy}"
: "${HOME_STACK_UPGRADE_OPENCODE:=opencode}"
: "${HOME_STACK_UPGRADE_PYTHON3:=python3}"

# ---------------------------------------------------------------------------
# catalog.json reading -- the same perl+JSON::PP pattern lib/common.sh's
# home_stack_service_url already uses, so a shell helper never re-derives
# what the engine already computed.
# ---------------------------------------------------------------------------

home_stack_upgrade_catalog_path() {
  echo "$HOME_STACK_BUNDLE_DIR/catalog.json"
}

# home_stack_upgrade_install_field <service> <field>
# Prints the value of catalog.json's <service>.install.<field>, or fails
# (prints nothing, returns 1) if catalog.json is missing, the service is
# absent, has no install: block, or the field is empty/absent.
home_stack_upgrade_install_field() {
  local name="$1" field="$2"
  local catalog
  catalog="$(home_stack_upgrade_catalog_path)"
  [[ -f "$catalog" ]] || return 1
  HOME_STACK_UPGRADE_SVC="$name" HOME_STACK_UPGRADE_FIELD="$field" \
    perl -MJSON::PP -e '
      use strict;
      use warnings;
      my $name  = $ENV{HOME_STACK_UPGRADE_SVC};
      my $field = $ENV{HOME_STACK_UPGRADE_FIELD};
      local $/;
      open my $fh, "<", $ARGV[0] or exit 1;
      my $json = <$fh>;
      close $fh;
      my $data = eval { JSON::PP::decode_json($json) };
      exit 1 if $@ || ref($data) ne "HASH";
      my $svc = $data->{$name};
      exit 1 unless ref($svc) eq "HASH";
      my $install = $svc->{install};
      exit 1 unless ref($install) eq "HASH";
      my $val = $install->{$field};
      exit 1 unless defined $val && $val ne "";
      print $val;
      exit 0;
    ' "$catalog"
}

# home_stack_upgrade_health_field <service> <port|http_url>
home_stack_upgrade_health_field() {
  local name="$1" field="$2"
  local catalog
  catalog="$(home_stack_upgrade_catalog_path)"
  [[ -f "$catalog" ]] || return 1
  HOME_STACK_UPGRADE_SVC="$name" HOME_STACK_UPGRADE_FIELD="$field" \
    perl -MJSON::PP -e '
      use strict;
      use warnings;
      my $name  = $ENV{HOME_STACK_UPGRADE_SVC};
      my $field = $ENV{HOME_STACK_UPGRADE_FIELD};
      local $/;
      open my $fh, "<", $ARGV[0] or exit 1;
      my $json = <$fh>;
      close $fh;
      my $data = eval { JSON::PP::decode_json($json) };
      exit 1 if $@ || ref($data) ne "HASH";
      my $svc = $data->{$name};
      exit 1 unless ref($svc) eq "HASH";
      my $health = $svc->{Health} // $svc->{health};
      exit 1 unless ref($health) eq "HASH";
      my $key = $field eq "http_url" ? "HTTPURL" : "Port";
      my $val = $health->{$key} // $health->{$field};
      exit 1 unless defined $val && $val ne "" && $val ne "0";
      print $val;
      exit 0;
    ' "$catalog"
}

# Prints one service name per line for every entry in catalog.json that
# carries a non-empty install: block, sorted.
home_stack_upgrade_services_with_install() {
  local catalog
  catalog="$(home_stack_upgrade_catalog_path)"
  [[ -f "$catalog" ]] || return 1
  perl -MJSON::PP -e '
    use strict;
    use warnings;
    local $/;
    open my $fh, "<", $ARGV[0] or exit 1;
    my $json = <$fh>;
    close $fh;
    my $data = eval { JSON::PP::decode_json($json) };
    exit 1 if $@ || ref($data) ne "HASH";
    for my $name (sort keys %$data) {
      my $svc = $data->{$name};
      next unless ref($svc) eq "HASH";
      print "$name\n" if ref($svc->{install}) eq "HASH";
    }
  ' "$catalog"
}

# ---------------------------------------------------------------------------
# Pure helpers (unit-tested directly)
# ---------------------------------------------------------------------------

# Extracts a dotted-numeric version (1.2.3 or 1.2.3.4) or, failing that, a
# 7-40 hex commit, from arbitrary command output. Prints nothing and returns
# 1 if neither pattern matches.
home_stack_upgrade_extract_version() {
  local text="$1"
  local semver
  semver="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?' <<<"$text" | head -1)"
  if [[ -n "$semver" ]]; then
    printf '%s' "$semver"
    return 0
  fi
  local commit
  commit="$(grep -oE '\b[0-9a-f]{7,40}\b' <<<"$text" | head -1)"
  if [[ -n "$commit" ]]; then
    printf '%s' "$commit"
    return 0
  fi
  return 1
}

# Runs a version_cmd with the bundle bin/ prepended to PATH (the same lookup
# order a wrapper would use) and extracts the version from its first line.
# Never passes HOME_STACK_* secrets -- version_cmd is a read-only probe.
home_stack_upgrade_live_version() {
  local version_cmd="$1"
  [[ -z "$version_cmd" ]] && return 1
  local out
  # Clean environment on purpose: a version probe must not inherit the loaded
  # stack environment (secrets, or app settings that change what a binary does
  # at startup). PATH and HOME only.
  out="$(env -i PATH="$HOME_STACK_BUNDLE_DIR/bin:$PATH" HOME="$HOME" bash -c "$version_cmd" 2>/dev/null | head -1)" || true
  [[ -z "$out" ]] && return 1
  home_stack_upgrade_extract_version "$out"
}

home_stack_upgrade_uname_arch() {
  case "$(uname -m)" in
    arm64|aarch64) echo arm64 ;;
    x86_64|amd64) echo amd64 ;;
    *) uname -m ;;
  esac
}

# Substitutes {version} (leading "v" stripped) and {arch} in a github-release
# asset name pattern. Pure string substitution -- no network.
home_stack_upgrade_resolve_asset() {
  local pattern="$1" version="$2" arch="$3"
  version="${version#v}"
  pattern="${pattern//\{version\}/$version}"
  pattern="${pattern//\{arch\}/$arch}"
  printf '%s' "$pattern"
}

# Compares two version-ish strings after stripping a leading "v". Prints:
#   0   equal
#   1   a > b
#   2   a < b
#   255 not comparable (at least one is not dotted-numeric, e.g. a commit)
home_stack_upgrade_version_cmp() {
  local a="${1#v}" b="${2#v}"
  if [[ "$a" == "$b" ]]; then
    echo 0
    return
  fi
  if [[ "$a" =~ ^[0-9]+(\.[0-9]+)*$ && "$b" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    local higher
    higher="$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -1)"
    if [[ "$higher" == "$a" ]]; then
      echo 1
    else
      echo 2
    fi
    return
  fi
  echo 255
}

# home_stack_upgrade_classify_drift <live> <pinned> <latest>
# ok            -- nothing to do: live matches (or has no) pin, and that
#                  baseline is not behind the latest upstream release.
# behind        -- the reviewed baseline (pin, or live if unpinned) is older
#                  than the latest upstream release.
# ahead-of-pin  -- the live version is newer than the profile's pin (someone
#                  upgraded by hand without updating the pin).
# unknown       -- live or latest could not be determined, or the values are
#                  not comparable (e.g. a commit hash vs. a semver tag).
home_stack_upgrade_classify_drift() {
  local live="$1" pinned="$2" latest="$3"
  if [[ -z "$live" || -z "$latest" ]]; then
    echo unknown
    return
  fi
  local baseline="$live"
  if [[ -n "$pinned" ]]; then
    local cmp_lp
    cmp_lp="$(home_stack_upgrade_version_cmp "$live" "$pinned")"
    if [[ "$cmp_lp" == "1" ]]; then
      echo ahead-of-pin
      return
    fi
    baseline="$pinned"
  fi
  local cmp_bl
  cmp_bl="$(home_stack_upgrade_version_cmp "$baseline" "$latest")"
  case "$cmp_bl" in
    0|1) echo ok ;;
    2) echo behind ;;
    *) echo unknown ;;
  esac
}

home_stack_upgrade_revert_binary() {
  local binary_path="$1"
  if [[ -f "${binary_path}.prev" ]]; then
    mv -f "${binary_path}.prev" "$binary_path"
    return 0
  fi
  return 1
}

# Appends one JSON line to $HOME_STACK_CONFIG_DIR/upgrade-log.jsonl -- a
# machine-local record, never committed. Uses python3 to build the JSON (same
# convention `hs` already uses) rather than hand-quoting strings into a
# heredoc.
home_stack_upgrade_log() {
  local name="$1" method="$2" from="$3" to="$4" result="$5"
  local log_dir="${HOME_STACK_CONFIG_DIR:-$HOME/.config/home-stack}"
  mkdir -p "$log_dir"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  "$HOME_STACK_UPGRADE_PYTHON3" -c '
import json, sys
ts, service, method, frm, to, result = sys.argv[1:7]
print(json.dumps({"ts": ts, "service": service, "method": method, "from": frm, "to": to, "result": result}))
' "$ts" "$name" "$method" "$from" "$to" "$result" >> "$log_dir/upgrade-log.jsonl"
}

# home_stack_upgrade_wait_healthy <service> [timeout_seconds]
# Polls the service's registry health signal (http_url preferred, else a bare
# TCP connect to port) until it answers or the timeout elapses. A service
# with no health: signal at all is treated as healthy immediately -- there is
# nothing to check. Tests override this function directly (bash allows
# redefining a sourced function) rather than faking a real listener.
home_stack_upgrade_wait_healthy() {
  local name="$1" timeout="${2:-30}"
  local http_url port
  http_url="$(home_stack_upgrade_health_field "$name" http_url 2>/dev/null || true)"
  port="$(home_stack_upgrade_health_field "$name" port 2>/dev/null || true)"
  if [[ -z "$http_url" && -z "$port" ]]; then
    return 0
  fi
  local waited=0
  while (( waited < timeout )); do
    if [[ -n "$http_url" ]]; then
      if "$HOME_STACK_UPGRADE_CURL" -sf -o /dev/null "$http_url" 2>/dev/null; then
        return 0
      fi
    elif [[ -n "$port" ]]; then
      if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
        exec 3>&- 3<&-
        return 0
      fi
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

home_stack_upgrade_restart() {
  local name="$1"
  "$HOME_STACK_SCRIPTS_DIR/service-launchd.sh" restart "$name" || true
}

# ---------------------------------------------------------------------------
# Upstream "latest" lookups, per method. All go through the overridable
# variables above so tests can stub them with a PATH shim or an env override.
# ---------------------------------------------------------------------------

home_stack_upgrade_gh_latest_tag() {
  local repo="$1"
  "$HOME_STACK_UPGRADE_GH" api "repos/$repo/releases/latest" --jq .tag_name 2>/dev/null
}

home_stack_upgrade_gh_asset_url() {
  local repo="$1" tag="$2" asset_name="$3"
  "$HOME_STACK_UPGRADE_GH" api "repos/$repo/releases/tags/$tag" \
    --jq ".assets[] | select(.name==\"$asset_name\") | .browser_download_url" 2>/dev/null | head -1
}

home_stack_upgrade_brew_latest() {
  local formula="$1"
  "$HOME_STACK_UPGRADE_BREW" info --json=v2 "$formula" 2>/dev/null | "$HOME_STACK_UPGRADE_PYTHON3" -c '
import json, sys
try:
    data = json.load(sys.stdin)
    formulae = data.get("formulae", [])
    if formulae:
        print(formulae[0].get("versions", {}).get("stable", ""))
except Exception:
    pass
'
}

# home_stack_upgrade_latest_version <method> <source>
home_stack_upgrade_latest_version() {
  local method="$1" source="$2"
  case "$method" in
    github-release|source-go) home_stack_upgrade_gh_latest_tag "$source" ;;
    xcaddy) home_stack_upgrade_gh_latest_tag "caddyserver/caddy" ;;
    npm-global) "$HOME_STACK_UPGRADE_NPM" view "$source" version 2>/dev/null ;;
    opencode) "$HOME_STACK_UPGRADE_NPM" view opencode-ai version 2>/dev/null ;;
    hermes-pinned) home_stack_upgrade_gh_latest_tag "NousResearch/hermes-agent" ;;
    brew) home_stack_upgrade_brew_latest "$source" ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# hs upgrade status
# ---------------------------------------------------------------------------

home_stack_upgrade_status() {
  local check=0
  [[ "${1:-}" == "--check" ]] && check=1

  local catalog
  catalog="$(home_stack_upgrade_catalog_path)"
  if [[ ! -f "$catalog" ]]; then
    echo "No catalog.json at $catalog -- run 'hs sync' first." >&2
    return 0
  fi

  local services
  services="$(home_stack_upgrade_services_with_install || true)"
  if [[ -z "$services" ]]; then
    echo "No services carry an install: block."
    return 0
  fi

  printf '%-16s %-15s %-18s %-18s %-18s %s\n' SERVICE METHOD LIVE PINNED LATEST DRIFT
  local any_behind=0
  local name
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    local method source pin version_cmd live latest drift
    method="$(home_stack_upgrade_install_field "$name" method 2>/dev/null || echo "")"
    source="$(home_stack_upgrade_install_field "$name" source 2>/dev/null || echo "")"
    pin="$(home_stack_upgrade_install_field "$name" pin 2>/dev/null || echo "")"
    version_cmd="$(home_stack_upgrade_install_field "$name" version_cmd 2>/dev/null || echo "")"

    live="$(home_stack_upgrade_live_version "$version_cmd" 2>/dev/null || echo "")"
    latest="$(home_stack_upgrade_latest_version "$method" "$source" 2>/dev/null || echo "")"
    drift="$(home_stack_upgrade_classify_drift "$live" "$pin" "$latest")"
    [[ "$drift" == "behind" ]] && any_behind=1

    printf '%-16s %-15s %-18s %-18s %-18s %s\n' \
      "$name" "$method" "${live:-unknown}" "${pin:-—}" "${latest:-unknown}" "$drift"
  done <<< "$services"

  if [[ $check -eq 1 && $any_behind -eq 1 ]]; then
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Per-method apply procedures
# ---------------------------------------------------------------------------

# github-release: resolve target -> resolve asset -> download -> verify
# checksum (best-effort) -> back up current binary -> install -> verify
# version_cmd reports the target -> restart -> health check -> auto-revert.
home_stack_upgrade_github_release() {
  local name="$1" to="$2" dry_run="$3"
  local source asset_pattern binary_rel version_cmd pin
  source="$(home_stack_upgrade_install_field "$name" source)" \
    || { echo "service '$name' has no install.source" >&2; return 1; }
  asset_pattern="$(home_stack_upgrade_install_field "$name" asset)" \
    || { echo "service '$name' has no install.asset (required for github-release)" >&2; return 1; }
  binary_rel="$(home_stack_upgrade_install_field "$name" binary)" \
    || { echo "service '$name' has no install.binary (required for github-release)" >&2; return 1; }
  version_cmd="$(home_stack_upgrade_install_field "$name" version_cmd 2>/dev/null || echo "")"
  pin="$(home_stack_upgrade_install_field "$name" pin 2>/dev/null || echo "")"

  local target="$to"
  if [[ -z "$target" ]]; then
    target="$(home_stack_upgrade_gh_latest_tag "$source" || true)"
    [[ -z "$target" ]] && { echo "failed to resolve the latest release for $source" >&2; return 1; }
  fi

  local arch version_num asset_name
  arch="$(home_stack_upgrade_uname_arch)"
  version_num="${target#v}"
  asset_name="$(home_stack_upgrade_resolve_asset "$asset_pattern" "$version_num" "$arch")"

  local binary_path="$HOME_STACK_BUNDLE_DIR/$binary_rel"

  local asset_url
  asset_url="$(home_stack_upgrade_gh_asset_url "$source" "$target" "$asset_name" || true)"

  if [[ "$dry_run" == "1" ]]; then
    echo "[dry-run] $name: github-release $source"
    echo "[dry-run]   target tag:  $target"
    echo "[dry-run]   asset name:  $asset_name"
    echo "[dry-run]   asset url:   ${asset_url:-<not found>}"
    echo "[dry-run]   install to:  $binary_path (backing up to ${binary_path}.prev)"
    echo "[dry-run]   then:        verify version_cmd reports $target, restart $name, health check, auto-revert on failure"
    return 0
  fi

  if [[ -z "$asset_url" ]]; then
    echo "no asset named '$asset_name' found in $source's $target release" >&2
    return 1
  fi

  local live_before
  live_before="$(home_stack_upgrade_live_version "$version_cmd" 2>/dev/null || echo "")"

  local tmp
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064 (intentional early expansion of $tmp)
  trap "rm -rf '$tmp'" RETURN

  local downloaded="$tmp/$asset_name"
  if ! "$HOME_STACK_UPGRADE_CURL" -fsSL -o "$downloaded" "$asset_url"; then
    echo "download failed: $asset_url" >&2
    return 1
  fi

  local checksum_url=""
  checksum_url="$(home_stack_upgrade_gh_asset_url "$source" "$target" "checksums.txt" 2>/dev/null || true)"
  if [[ -z "$checksum_url" ]]; then
    checksum_url="$(home_stack_upgrade_gh_asset_url "$source" "$target" "$asset_name.sha256" 2>/dev/null || true)"
  fi
  if [[ -n "$checksum_url" ]]; then
    local sums="$tmp/checksums.txt"
    if "$HOME_STACK_UPGRADE_CURL" -fsSL -o "$sums" "$checksum_url" 2>/dev/null \
      && ! (cd "$tmp" && grep "$asset_name" "$sums" | shasum -a 256 -c - >/dev/null 2>&1); then
      echo "WARNING: checksum verification failed for $asset_name -- not installing" >&2
      return 1
    fi
  else
    echo "WARNING: no checksums asset found for $source $target; installing $asset_name unverified" >&2
  fi

  chmod +x "$downloaded"

  if [[ -f "$binary_path" ]]; then
    cp -p "$binary_path" "${binary_path}.prev"
  fi
  "$HOME_STACK_UPGRADE_INSTALL" -m 0755 "$downloaded" "$binary_path"

  if [[ -n "$version_cmd" ]]; then
    local new_live
    new_live="$(home_stack_upgrade_live_version "$version_cmd" 2>/dev/null || echo "")"
    if [[ -n "$new_live" && "$new_live" != "$version_num" && "$new_live" != "$target" ]]; then
      echo "installed binary reports version '$new_live', expected '$target' -- reverting" >&2
      home_stack_upgrade_revert_binary "$binary_path"
      home_stack_upgrade_log "$name" "github-release" "$live_before" "$target" "failed-version-mismatch"
      return 1
    fi
  fi

  home_stack_upgrade_restart "$name"

  if ! home_stack_upgrade_wait_healthy "$name" 30; then
    echo "health check failed after upgrading $name -- reverting" >&2
    home_stack_upgrade_revert_binary "$binary_path"
    home_stack_upgrade_restart "$name"
    home_stack_upgrade_log "$name" "github-release" "$live_before" "$target" "reverted"
    return 1
  fi

  home_stack_upgrade_log "$name" "github-release" "$live_before" "$target" "success"
  echo "upgraded $name: $live_before -> $target"
  if [[ -n "$pin" && "$pin" != "$target" ]]; then
    echo "note: profile pin ($pin) does not match the installed version ($target) -- update the profile's install.pin if this was reviewed."
  fi
}

# xcaddy (Caddy): Caddy is the system LaunchDaemon, so restarting it needs
# sudo. Building and staging never needs sudo; the procedure stops before
# touching the running binary if it cannot restart afterward, so it never
# leaves the daemon on a binary nothing has verified serves the config.
home_stack_upgrade_xcaddy() {
  local name="$1" to="$2" dry_run="$3"
  local binary_rel
  binary_rel="$(home_stack_upgrade_install_field "$name" binary 2>/dev/null || echo "bin/caddy-cloudflare")"
  local binary_path="$HOME_STACK_BUNDLE_DIR/$binary_rel"
  local identifier_prefix="${HOME_STACK_IDENTIFIER_PREFIX:-<identifier-prefix>}"
  local sudo_cmd="sudo launchctl kickstart -k system/${identifier_prefix}.home-stack.caddy"

  local target="$to"
  if [[ -z "$target" ]]; then
    target="$(home_stack_upgrade_gh_latest_tag "caddyserver/caddy" || true)"
    [[ -z "$target" ]] && { echo "failed to resolve the latest Caddy release" >&2; return 1; }
  fi

  if [[ "$dry_run" == "1" ]]; then
    echo "[dry-run] $name: xcaddy build $target with cloudflare + tailscale plugins"
    echo "[dry-run]   staging path: ${binary_path}.staging"
    echo "[dry-run]   caddy adapt --config $HOME_STACK_BUNDLE_DIR/Caddyfile (dummy token)"
    echo "[dry-run]   swap with ${binary_path}.prev, then restart requires: $sudo_cmd"
    return 0
  fi

  if ! sudo -n true 2>/dev/null; then
    echo "hs upgrade caddy restarts the system LaunchDaemon, which needs sudo." >&2
    echo "Not building: re-run this command with sudo, or run it as an operator who can:" >&2
    echo "  $sudo_cmd" >&2
    return 1
  fi

  local staging="${binary_path}.staging"
  local arch
  arch="$(uname -m | sed -e 's/^x86_64$/amd64/' -e 's/^aarch64$/arm64/')"
  if ! CGO_ENABLED=0 GOARCH="$arch" "$HOME_STACK_UPGRADE_XCADDY" build "$target" \
      --with github.com/caddy-dns/cloudflare \
      --with github.com/tailscale/caddy-tailscale \
      --output "$staging"; then
    echo "xcaddy build failed" >&2
    return 1
  fi

  if ! CLOUDFLARE_API_TOKEN=dummy "$staging" adapt --config "$HOME_STACK_BUNDLE_DIR/Caddyfile" >/dev/null; then
    echo "caddy adapt failed against the generated Caddyfile -- not swapping binaries" >&2
    rm -f "$staging"
    return 1
  fi

  [[ -f "$binary_path" ]] && cp -p "$binary_path" "${binary_path}.prev"
  mv -f "$staging" "$binary_path"
  chmod +x "$binary_path"

  sudo launchctl kickstart -k "system/${identifier_prefix}.home-stack.caddy"

  if ! home_stack_upgrade_wait_healthy "$name" 30; then
    echo "health check failed after upgrading caddy -- reverting" >&2
    home_stack_upgrade_revert_binary "$binary_path"
    sudo launchctl kickstart -k "system/${identifier_prefix}.home-stack.caddy"
    home_stack_upgrade_log "$name" xcaddy "" "$target" reverted
    return 1
  fi

  home_stack_upgrade_log "$name" xcaddy "" "$target" success
  echo "upgraded $name to $target"
}

# source-go (tinyauth): clone at tag, build the frontend with corepack pnpm,
# go build to a staging path, swap with a .prev backup, restart, health
# check, auto-revert.
home_stack_upgrade_source_go() {
  local name="$1" to="$2" dry_run="$3"
  local source binary_rel
  source="$(home_stack_upgrade_install_field "$name" source)" \
    || { echo "service '$name' has no install.source" >&2; return 1; }
  binary_rel="$(home_stack_upgrade_install_field "$name" binary)" \
    || { echo "service '$name' has no install.binary" >&2; return 1; }
  local binary_path="$HOME_STACK_BUNDLE_DIR/$binary_rel"

  local target="$to"
  if [[ -z "$target" ]]; then
    target="$(home_stack_upgrade_gh_latest_tag "$source" || true)"
    [[ -z "$target" ]] && { echo "failed to resolve the latest tag for $source" >&2; return 1; }
  fi

  if [[ "$dry_run" == "1" ]]; then
    echo "[dry-run] $name: clone $source at $target"
    echo "[dry-run]   frontend/: corepack pnpm install --frozen-lockfile && pnpm run build"
    echo "[dry-run]   cp -r frontend/dist internal/assets/"
    echo "[dry-run]   go build -tags nomsgpack -ldflags \"-s -w\" -o ${binary_path}.staging ./cmd/$name"
    echo "[dry-run]   swap with ${binary_path}.prev, restart $name, health check, auto-revert on failure"
    return 0
  fi

  local src_dir
  src_dir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$src_dir'" RETURN

  if ! "$HOME_STACK_UPGRADE_GIT" clone --depth 1 --branch "$target" "https://github.com/$source" "$src_dir/src" 2>&1; then
    echo "clone of $source at $target failed" >&2
    return 1
  fi

  if ! ( cd "$src_dir/src/frontend" \
      && "$HOME_STACK_UPGRADE_COREPACK" pnpm install --frozen-lockfile \
      && "$HOME_STACK_UPGRADE_COREPACK" pnpm run build ); then
    echo "frontend build failed" >&2
    return 1
  fi
  if ! ( cd "$src_dir/src" && cp -r frontend/dist internal/assets/ ); then
    echo "copying frontend/dist into internal/assets failed" >&2
    return 1
  fi

  local staging="${binary_path}.staging"
  if ! ( cd "$src_dir/src" && CGO_ENABLED=0 GOOS=darwin GOARCH="$(home_stack_upgrade_uname_arch)" \
      "$HOME_STACK_UPGRADE_GO" build -tags nomsgpack -ldflags "-s -w" -o "$staging" "./cmd/$name" ); then
    echo "go build failed" >&2
    return 1
  fi

  [[ -f "$binary_path" ]] && cp -p "$binary_path" "${binary_path}.prev"
  "$HOME_STACK_UPGRADE_INSTALL" -m 0755 "$staging" "$binary_path"

  home_stack_upgrade_restart "$name"

  if ! home_stack_upgrade_wait_healthy "$name" 30; then
    echo "health check failed after upgrading $name -- reverting" >&2
    home_stack_upgrade_revert_binary "$binary_path"
    home_stack_upgrade_restart "$name"
    home_stack_upgrade_log "$name" source-go "" "$target" reverted
    return 1
  fi

  home_stack_upgrade_log "$name" source-go "" "$target" success
  echo "upgraded $name to $target"
}

# npm-global: `npm install -g <source>@<version>`, restart, health check.
# There is no vendored binary to back up (npm owns the install location), so
# this method has no auto-revert -- npm install -g <source>@<old-version> by
# hand is the rollback.
home_stack_upgrade_npm_global() {
  local name="$1" to="$2" dry_run="$3"
  local source
  source="$(home_stack_upgrade_install_field "$name" source)" \
    || { echo "service '$name' has no install.source" >&2; return 1; }

  local target="$to"
  if [[ -z "$target" ]]; then
    target="$("$HOME_STACK_UPGRADE_NPM" view "$source" version 2>/dev/null || true)"
    [[ -z "$target" ]] && { echo "failed to resolve the latest npm version for $source" >&2; return 1; }
  fi

  if [[ "$dry_run" == "1" ]]; then
    echo "[dry-run] $name: npm install -g $source@$target, restart, health check"
    return 0
  fi

  if ! "$HOME_STACK_UPGRADE_NPM" install -g "$source@$target"; then
    echo "npm install -g $source@$target failed" >&2
    return 1
  fi

  home_stack_upgrade_restart "$name"

  if ! home_stack_upgrade_wait_healthy "$name" 30; then
    echo "health check failed after upgrading $name to $target (npm-global has no auto-revert; roll back with 'npm install -g $source@<previous>')" >&2
    home_stack_upgrade_log "$name" npm-global "" "$target" failed
    return 1
  fi

  home_stack_upgrade_log "$name" npm-global "" "$target" success
  echo "upgraded $name to $target"
}

# opencode: `opencode upgrade [<version>]`, restart, health check. Detects
# whether the installed opencode's `upgrade --help` documents a version
# argument; falls back to a plain `opencode upgrade` otherwise.
home_stack_upgrade_opencode_supports_version_arg() {
  "$HOME_STACK_UPGRADE_OPENCODE" upgrade --help 2>&1 | grep -qiE '\[version\]|<version>'
}

home_stack_upgrade_opencode_apply() {
  local name="$1" to="$2" dry_run="$3"
  local cmd=("$HOME_STACK_UPGRADE_OPENCODE" upgrade)
  if [[ -n "$to" ]] && home_stack_upgrade_opencode_supports_version_arg; then
    cmd+=("$to")
  elif [[ -n "$to" ]]; then
    echo "installed opencode does not appear to support 'upgrade <version>'; running a plain upgrade instead (ignoring --to $to)" >&2
  fi

  if [[ "$dry_run" == "1" ]]; then
    echo "[dry-run] $name: ${cmd[*]}, restart, health check"
    return 0
  fi

  if ! "${cmd[@]}"; then
    echo "opencode upgrade failed" >&2
    return 1
  fi

  home_stack_upgrade_restart "$name"

  if ! home_stack_upgrade_wait_healthy "$name" 30; then
    echo "health check failed after opencode upgrade" >&2
    home_stack_upgrade_log "$name" opencode "" "${to:-latest}" failed
    return 1
  fi

  home_stack_upgrade_log "$name" opencode "" "${to:-latest}" success
  echo "upgraded $name (opencode upgrade)"
}

# hermes-pinned: exactly docs/RUNBOOK.md's pinned-installer procedure. Refuses
# anything but a full 40-hex-character commit SHA for --to (no tags, no
# moving refs), requires --yes (it mutates ~/.hermes), backs up config.yaml,
# runs the reviewed installer pinned to that commit, reinstalls the web/pty
# extras, checks config, restarts, and verifies /api/status still reports
# auth_required: true.
home_stack_upgrade_hermes_pinned() {
  local name="$1" to="$2" dry_run="$3" yes="$4"

  if [[ -z "$to" ]]; then
    echo "hermes-pinned requires --to <full-commit-sha> (never a tag or branch)" >&2
    return 1
  fi
  if ! [[ "$to" =~ ^[0-9a-f]{40}$ ]]; then
    echo "hermes-pinned refuses '$to': --to must be a full 40-character commit SHA, not a tag or moving ref" >&2
    return 1
  fi

  local hermes_home="${HOME_STACK_HERMES_HOME:-$HOME/.hermes}"

  if [[ "$dry_run" == "1" ]]; then
    echo "[dry-run] $name: back up $hermes_home/config.yaml with a timestamp"
    echo "[dry-run]   curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/$to/scripts/install.sh | bash -s -- --skip-setup --commit $to"
    echo "[dry-run]   $hermes_home/bin/uv pip install --python venv/bin/python -e '.[web,pty]'"
    echo "[dry-run]   hermes config check, restart $name, verify /api/status reports auth_required: true"
    return 0
  fi

  if [[ "$yes" != "1" ]]; then
    echo "hermes-pinned mutates $hermes_home; re-run with --yes to proceed." >&2
    return 1
  fi

  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  if [[ -f "$hermes_home/config.yaml" ]]; then
    cp -p "$hermes_home/config.yaml" "$hermes_home/config.yaml.pre-upgrade.$stamp"
  fi

  if ! "$HOME_STACK_UPGRADE_CURL" -fsSL "https://raw.githubusercontent.com/NousResearch/hermes-agent/$to/scripts/install.sh" \
      | bash -s -- --skip-setup --commit "$to"; then
    echo "hermes installer failed" >&2
    return 1
  fi

  if ! ( cd "$hermes_home/hermes-agent" && "$hermes_home/bin/uv" pip install --python venv/bin/python -e '.[web,pty]' ); then
    echo "hermes web/pty extras install failed" >&2
    return 1
  fi

  if ! "$hermes_home/bin/hermes" config check; then
    echo "hermes config check failed -- review the config migration before restarting" >&2
    return 1
  fi

  home_stack_upgrade_restart "$name"

  local status_url
  status_url="$(home_stack_upgrade_health_field "$name" http_url 2>/dev/null || true)"
  if [[ -n "$status_url" ]]; then
    local body
    body="$("$HOME_STACK_UPGRADE_CURL" -sf "$status_url" 2>/dev/null || true)"
    if ! grep -q '"auth_required"[[:space:]]*:[[:space:]]*true' <<<"$body"; then
      echo "hermes /api/status did not report auth_required: true after upgrading -- investigate before trusting the listener" >&2
      home_stack_upgrade_log "$name" hermes-pinned "" "$to" verify-failed
      return 1
    fi
  fi

  home_stack_upgrade_log "$name" hermes-pinned "" "$to" success
  echo "upgraded $name to commit $to"
}

# ---------------------------------------------------------------------------
# hs upgrade <service> [--to <version>] [--dry-run] [--yes]
# ---------------------------------------------------------------------------

home_stack_upgrade_apply() {
  local name="$1"
  shift || true
  local to="" dry_run=0 yes=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --to) to="$2"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      --yes) yes=1; shift ;;
      *) echo "unknown flag: $1" >&2; return 2 ;;
    esac
  done

  local method
  method="$(home_stack_upgrade_install_field "$name" method)" \
    || { echo "service '$name' has no install: block -- nothing to upgrade" >&2; return 1; }

  case "$method" in
    github-release) home_stack_upgrade_github_release "$name" "$to" "$dry_run" ;;
    xcaddy)         home_stack_upgrade_xcaddy "$name" "$to" "$dry_run" ;;
    source-go)      home_stack_upgrade_source_go "$name" "$to" "$dry_run" ;;
    npm-global)     home_stack_upgrade_npm_global "$name" "$to" "$dry_run" ;;
    opencode)       home_stack_upgrade_opencode_apply "$name" "$to" "$dry_run" ;;
    hermes-pinned)  home_stack_upgrade_hermes_pinned "$name" "$to" "$dry_run" "$yes" ;;
    brew)
      echo "service '$name' is brew-managed; hs upgrade does not automate this method -- run: brew upgrade <formula>" >&2
      return 1
      ;;
    *)
      echo "service '$name' has unknown install.method '$method'" >&2
      return 1
      ;;
  esac
}
