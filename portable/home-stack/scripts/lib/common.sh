#!/usr/bin/env bash
# Shared path, port, and template-rendering defaults for home-stack scripts.
# Source this file instead of duplicating host-specific paths.

if [[ -z "${BASH_VERSION:-}" ]]; then
  echo "common.sh must be sourced from bash, not another shell" >&2
  return 1 2>/dev/null || exit 1
fi

if [[ -n "${HOME_STACK_COMMON_SH_LOADED:-}" ]]; then
  return 0
fi
HOME_STACK_COMMON_SH_LOADED=1

# ---------------------------------------------------------------------------
# Layer 1: structural / location defaults (derived from script path, not identity)
# ---------------------------------------------------------------------------
HOME_STACK_COMMON_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME_STACK_SCRIPTS_DIR="$(cd -- "$HOME_STACK_COMMON_DIR/.." && pwd)"
HOME_STACK_BUNDLE_DIR="${HOME_STACK_BUNDLE_DIR:-$(cd -- "$HOME_STACK_SCRIPTS_DIR/.." && pwd)}"

if [[ -z "${HOME_STACK_REPO_ROOT:-}" ]]; then
  if [[ -d "$HOME_STACK_BUNDLE_DIR/../../templates" ]]; then
    HOME_STACK_REPO_ROOT="$(cd -- "$HOME_STACK_BUNDLE_DIR/../.." && pwd)"
  else
    HOME_STACK_REPO_ROOT="$HOME_STACK_BUNDLE_DIR"
  fi
fi

HOME_STACK_TEMPLATE_DIR="${HOME_STACK_TEMPLATE_DIR:-$HOME_STACK_REPO_ROOT/templates}"

# ---------------------------------------------------------------------------
# Layer 1: non-identity port defaults (code defaults only — no identity values)
# ---------------------------------------------------------------------------
HOME_STACK_OPENCODE_PORT="${HOME_STACK_OPENCODE_PORT:-31496}"
HOME_STACK_OPENCHAMBER_PORT="${HOME_STACK_OPENCHAMBER_PORT:-31497}"
HOME_STACK_ADMIN_PORT="${HOME_STACK_ADMIN_PORT:-31510}"
HOME_STACK_HERMES_PORT="${HOME_STACK_HERMES_PORT:-31511}"

# ---------------------------------------------------------------------------
# Profile directory resolution (the one profile resolver — the Go admin's
# profilesDir/registryPath in portable/home-stack/admin/registry.go mirror
# this).
#
# HOME_STACK_PROFILES_DIR overrides the default ($HOME_STACK_REPO_ROOT/profiles)
# so staged tests and CI can point at a fixture tree without a symlink. The
# symlink at profiles/<name> remains the documented runtime mechanism for a
# real deployment — it needs no environment and works for launchd-launched
# processes — so the engine-generated plists pin only HOME_STACK_PROFILE into
# their EnvironmentVariables, never HOME_STACK_PROFILES_DIR: the override is
# for tests/CI, not for what gets deployed.
# ---------------------------------------------------------------------------
home_stack_profiles_dir() {
  echo "${HOME_STACK_PROFILES_DIR:-$HOME_STACK_REPO_ROOT/profiles}"
}

# home_stack_profile_dir <name>
home_stack_profile_dir() {
  echo "$(home_stack_profiles_dir)/$1"
}

# ---------------------------------------------------------------------------
# Profile resolution helper
# ---------------------------------------------------------------------------
home_stack_resolve_profile() {
  if [[ -n "${HOME_STACK_PROFILE:-}" ]]; then
    if [[ ! -d "$(home_stack_profile_dir "$HOME_STACK_PROFILE")" ]]; then
      echo "home-stack: HOME_STACK_PROFILE=$HOME_STACK_PROFILE but $(home_stack_profile_dir "$HOME_STACK_PROFILE")/ does not exist" >&2
      echo "  run: hs init (or set HOME_STACK_PROFILES_DIR if your profiles live elsewhere)" >&2
      exit 1
    fi
    return 0
  fi
  local guess
  guess="$(whoami)"
  # When invoked via sudo, whoami returns "root" but the calling user is SUDO_USER.
  if [[ "$guess" == "root" && -n "${SUDO_USER:-}" ]]; then
    guess="$SUDO_USER"
  fi
  if [[ -d "$(home_stack_profile_dir "$guess")" ]]; then
    HOME_STACK_PROFILE="$guess"
    return 0
  fi
  echo "home-stack: no profile resolved (HOME_STACK_PROFILE unset and $(home_stack_profile_dir "$guess")/ does not exist)" >&2
  echo "  run: hs init (or set HOME_STACK_PROFILES_DIR if your profiles live elsewhere)" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Mandatory-var validation helper
# ---------------------------------------------------------------------------
home_stack_validate_mandatory() {
  local missing=()
  local key
  for key in HOME_STACK_PARENT_DOMAIN HOME_STACK_TAILNET_IP HOME_STACK_ACME_EMAIL HOME_STACK_OWNER_HOME HOME_STACK_IDENTIFIER_PREFIX HOME_STACK_ADMIN_USERNAME; do
    if [[ -z "${!key:-}" ]]; then
      missing+=("$key")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    echo "home-stack: missing mandatory profile variables in profiles/$HOME_STACK_PROFILE/home-stack.env:" >&2
    local m
    for m in "${missing[@]}"; do
      echo "  - $m" >&2
    done
    echo "  see templates/profile.env.example for the contract" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Identity-key guard: env.local must not set identity keys
# ---------------------------------------------------------------------------
home_stack_reject_identity_in_env_local() {
  # env.local must contain only secrets. Reject identity keys.
  if [[ ! -f "$HOME_STACK_ENV_FILE" ]]; then
    return 0
  fi
  local offenders=()
  local key
  for key in HOME_STACK_PARENT_DOMAIN HOME_STACK_TAILNET_IP HOME_STACK_ACME_EMAIL HOME_STACK_OWNER_HOME HOME_STACK_IDENTIFIER_PREFIX HOME_STACK_ADMIN_USERNAME; do
    if grep -qE "^[[:space:]]*(export[[:space:]]+)?${key}=" "$HOME_STACK_ENV_FILE"; then
      offenders+=("$key")
    fi
  done
  if (( ${#offenders[@]} > 0 )); then
    echo "home-stack: env.local must not set identity keys (those belong in the profile):" >&2
    local k
    for k in "${offenders[@]}"; do
      echo "  - $k" >&2
    done
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Four-layer env loader
# ---------------------------------------------------------------------------
home_stack_load_env() {
  # Layer 1: code defaults already set above for non-identity vars.

  # Layer 2: profile env.
  home_stack_resolve_profile
  local profile_env="$(home_stack_profile_dir "$HOME_STACK_PROFILE")/home-stack.env"
  if [[ -f "$profile_env" ]]; then
    set -a
    . "$profile_env"
    set +a
  fi

  # Layer 3: machine-local non-secret override (untracked, optional).
  local config_env="${HOME_STACK_CONFIG_DIR:-$HOME_STACK_OWNER_HOME/.config/home-stack}/config.env"
  if [[ -f "$config_env" ]]; then
    set -a
    . "$config_env"
    set +a
  fi

  # Compute owner-home-derived paths now that the profile has set HOME_STACK_OWNER_HOME.
  HOME_STACK_CONFIG_DIR="${HOME_STACK_CONFIG_DIR:-$HOME_STACK_OWNER_HOME/.config/home-stack}"
  HOME_STACK_ENV_FILE="${HOME_STACK_ENV_FILE:-$HOME_STACK_CONFIG_DIR/env.local}"
  HOME_STACK_LOG_DIR="${HOME_STACK_LOG_DIR:-$HOME_STACK_CONFIG_DIR/logs}"
  HOME_STACK_PID_DIR="${HOME_STACK_PID_DIR:-$HOME_STACK_CONFIG_DIR/pids}"
  HOME_STACK_TLS_DIR="${HOME_STACK_TLS_DIR:-$HOME_STACK_CONFIG_DIR/tls}"
  HOME_STACK_CADDY_CONFIG_DIR="${HOME_STACK_CADDY_CONFIG_DIR:-$HOME_STACK_CONFIG_DIR/caddy/config}"
  HOME_STACK_CADDY_DATA_DIR="${HOME_STACK_CADDY_DATA_DIR:-$HOME_STACK_CONFIG_DIR/caddy/data}"
  HOME_STACK_PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/go/bin:$HOME_STACK_OWNER_HOME/go/bin:$HOME_STACK_OWNER_HOME/.opencode/bin:$HOME_STACK_OWNER_HOME/.bun/bin:$HOME_STACK_OWNER_HOME/.local/bin"
  if [[ -d "$HOME_STACK_OWNER_HOME/.nvm/versions/node" ]]; then
    for home_stack_node_bin in "$HOME_STACK_OWNER_HOME"/.nvm/versions/node/*/bin; do
      if [[ -d "$home_stack_node_bin" ]]; then
        HOME_STACK_PATH="$home_stack_node_bin:$HOME_STACK_PATH"
      fi
    done
  fi
  export PATH="$HOME_STACK_PATH"

  # Layer 4: secrets. Identity keys are forbidden here.
  home_stack_reject_identity_in_env_local
  if [[ "${HOME_STACK_SKIP_ENV_LOCAL:-0}" != "1" && -f "$HOME_STACK_ENV_FILE" ]]; then
    set -a
    . "$HOME_STACK_ENV_FILE"
    set +a
  fi

  # Validate the contract.
  home_stack_validate_mandatory

  # Fill identity-derived defaults that compose from mandatory vars.
  : "${HOME_STACK_PORTAL_HOST:=portal.$HOME_STACK_PARENT_DOMAIN}"
  : "${HOME_STACK_OPENCHAMBER_HOST:=opencode.$HOME_STACK_PARENT_DOMAIN}"
  : "${HOME_STACK_ADMIN_HOST:=admin.$HOME_STACK_PARENT_DOMAIN}"
  : "${HOME_STACK_HERMES_HOST:=hermes.$HOME_STACK_PARENT_DOMAIN}"
  : "${HOME_STACK_HERMES_PUBLIC_URL:=https://$HOME_STACK_HERMES_HOST}"
  : "${HOME_STACK_BIN_DIR:=$HOME_STACK_OWNER_HOME/bin}"
  : "${HOME_STACK_PORTAL_ROOT:=$HOME_STACK_OWNER_HOME/github/home-portal/dist}"
  if [[ ! -d "$HOME_STACK_PORTAL_ROOT" ]]; then
    HOME_STACK_PORTAL_ROOT="$HOME_STACK_BUNDLE_DIR/portal-www"
  fi
}

home_stack_normalize_cloudflare_env() {
  HOME_STACK_CLOUDFLARE_API_TOKEN="${HOME_STACK_CLOUDFLARE_API_TOKEN:-${CLOUDFLARE_API_TOKEN:-}}"
  CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-$HOME_STACK_CLOUDFLARE_API_TOKEN}"
  export HOME_STACK_CLOUDFLARE_API_TOKEN CLOUDFLARE_API_TOKEN
}

home_stack_require_env_file() {
  if [[ ! -f "$HOME_STACK_ENV_FILE" ]]; then
    echo "Missing host env: $HOME_STACK_ENV_FILE" >&2
    exit 1
  fi
}

home_stack_ensure_runtime_dirs() {
  mkdir -p "$HOME_STACK_CONFIG_DIR" "$HOME_STACK_LOG_DIR" "$HOME_STACK_PID_DIR" "$HOME_STACK_TLS_DIR" "$HOME_STACK_CADDY_CONFIG_DIR" "$HOME_STACK_CADDY_DATA_DIR"
}

home_stack_render_template() {
  local src="$1"
  local dest="$2"
  perl \
    -e 'use strict; use warnings; my ($src, $dest) = @ARGV; open my $in, "<", $src or die "open $src: $!"; local $/; my $s = <$in>; close $in; my %r = map { $_ => $ENV{$_} // "" } qw(HOME_STACK_OWNER_HOME HOME_STACK_CONFIG_DIR HOME_STACK_ENV_FILE HOME_STACK_LOG_DIR HOME_STACK_PID_DIR HOME_STACK_TLS_DIR HOME_STACK_CADDY_CONFIG_DIR HOME_STACK_CADDY_DATA_DIR HOME_STACK_BUNDLE_DIR HOME_STACK_REPO_ROOT HOME_STACK_TEMPLATE_DIR HOME_STACK_PATH HOME_STACK_OPENCODE_PORT HOME_STACK_OPENCHAMBER_PORT HOME_STACK_HERMES_PORT HOME_STACK_TAILNET_IP HOME_STACK_PARENT_DOMAIN HOME_STACK_ACME_EMAIL HOME_STACK_IDENTIFIER_PREFIX HOME_STACK_ADMIN_USERNAME HOME_STACK_PORTAL_HOST HOME_STACK_OPENCHAMBER_HOST HOME_STACK_HERMES_HOST HOME_STACK_HERMES_PUBLIC_URL HOME_STACK_ADMIN_PORT HOME_STACK_ADMIN_HOST HOME_STACK_PORTAL_ROOT HOME_STACK_BIN_DIR HOME_STACK_PROFILE); $s =~ s/__([A-Z0-9_]+)__/exists $r{$1} ? $r{$1} : $&/ge; open my $out, ">", $dest or die "open $dest: $!"; print {$out} $s; close $out;' \
    "$src" "$dest"
}

# ---------------------------------------------------------------------------
# Sibling-service URL lookup
# ---------------------------------------------------------------------------
# home_stack_service_url <name>
#
# Wrappers that need another managed service's public URL (tinyauth resolving
# Pocket ID's OIDC endpoints, Hermes resolving its issuer, or a wrapper
# resolving its own URL as a fallback for a stale plist) read it from
# catalog.json -- the private sync artifact the engine already writes with a
# `url` field computed from Service.RoutableURL -- instead of recomposing a
# hostname from a second copy of profile variables. The shell must never
# recompose a hostname: that second copy is exactly the "silent substitution"
# the 2026-05-02 decision banned, change one and the other silently disagrees.
# The engine already resolved subdomain/host/wildcard/enabled into that one
# `url` key; this only reads it.
#
# Prints the resolved "https://..." URL and returns 0, or prints nothing and
# returns 1 when catalog.json is missing, the service is absent from it, or
# its `url` field is empty or absent (disabled, unrouted, or a wildcard
# subdomain -- none of which is one service's own URL).
home_stack_service_url() {
  local name="$1"
  local catalog="$HOME_STACK_BUNDLE_DIR/catalog.json"
  [[ -f "$catalog" ]] || return 1
  HOME_STACK_SERVICE_URL_NAME="$name" \
    perl -MJSON::PP -e '
      use strict;
      use warnings;
      my $name = $ENV{HOME_STACK_SERVICE_URL_NAME};
      local $/;
      open my $fh, "<", $ARGV[0] or exit 1;
      my $json = <$fh>;
      close $fh;
      my $data = eval { JSON::PP::decode_json($json) };
      exit 1 if $@ || ref($data) ne "HASH";
      my $svc = $data->{$name};
      exit 1 unless ref($svc) eq "HASH";
      my $url = $svc->{url} // "";
      exit 1 if $url eq "";
      print $url;
      exit 0;
    ' "$catalog"
}

export HOME_STACK_COMMON_DIR HOME_STACK_SCRIPTS_DIR HOME_STACK_BUNDLE_DIR HOME_STACK_REPO_ROOT HOME_STACK_TEMPLATE_DIR
export HOME_STACK_OPENCODE_PORT HOME_STACK_OPENCHAMBER_PORT HOME_STACK_HERMES_PORT HOME_STACK_ADMIN_PORT
# Export only when the caller set it, so child processes (the Go admin
# binary included) agree with this shell on where profiles/ live -- but a
# generated plist never pins this (see the resolver comment above).
[[ -n "${HOME_STACK_PROFILES_DIR:-}" ]] && export HOME_STACK_PROFILES_DIR
export HOME_STACK_PROFILE
export HOME_STACK_OWNER_HOME HOME_STACK_CONFIG_DIR HOME_STACK_ENV_FILE HOME_STACK_LOG_DIR HOME_STACK_PID_DIR HOME_STACK_TLS_DIR HOME_STACK_CADDY_CONFIG_DIR HOME_STACK_CADDY_DATA_DIR
export HOME_STACK_PATH
export HOME_STACK_TAILNET_IP HOME_STACK_PARENT_DOMAIN HOME_STACK_ACME_EMAIL HOME_STACK_IDENTIFIER_PREFIX HOME_STACK_ADMIN_USERNAME
export HOME_STACK_PORTAL_HOST HOME_STACK_OPENCHAMBER_HOST HOME_STACK_HERMES_HOST HOME_STACK_HERMES_PUBLIC_URL HOME_STACK_ADMIN_HOST HOME_STACK_PORTAL_ROOT HOME_STACK_BIN_DIR

# launchctl bootout is asynchronous: it returns before the job finishes tearing
# down, and bootstrapping the same label while the old job is still dying fails
# with "Bootstrap failed: 5: Input/output error" -- after the stop has already
# landed, which is the worst available order of operations (service down,
# nothing restarted it). Poll until launchd has forgotten the label before
# bootstrapping it again. Extra arguments are the launchctl invocation to use
# (e.g. `sudo launchctl` for the system domain); defaults to plain launchctl.
home_stack_wait_label_gone() {
  local domain="$1" label="$2" timeout="${3:-30}"
  shift 3
  local -a lc=("$@")
  [[ ${#lc[@]} -eq 0 ]] && lc=(launchctl)
  local waited=0
  while "${lc[@]}" print "$domain/$label" >/dev/null 2>&1; do
    waited=$((waited + 1))
    if (( waited >= timeout )); then
      echo "launchd job $domain/$label still tearing down after ${timeout}s" >&2
      return 1
    fi
    sleep 1
  done
  return 0
}
