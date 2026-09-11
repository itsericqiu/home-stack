#!/usr/bin/env bash
# launchd foreground wrapper for the official Hermes Agent dashboard.
# Hermes keeps its normal user-owned state under ~/.hermes.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
home_stack_load_env

export PATH="$HOME_STACK_PATH"
hermes_home="${HERMES_HOME:-$HOME_STACK_OWNER_HOME/.hermes}"

missing=()
for key in \
  HOME_STACK_HERMES_DASHBOARD_USERNAME \
  HOME_STACK_HERMES_DASHBOARD_PASSWORD_HASH \
  HOME_STACK_HERMES_DASHBOARD_SECRET; do
  if [[ -z "${!key:-}" ]]; then
    missing+=("$key")
  fi
done
if (( ${#missing[@]} > 0 )); then
  echo "home-stack: Hermes dashboard authentication is incomplete; missing:" >&2
  printf '  - %s\n' "${missing[@]}" >&2
  exit 1
fi

if ! command -v hermes >/dev/null 2>&1; then
  echo "home-stack: official Hermes Agent executable not found in HOME_STACK_PATH" >&2
  exit 127
fi
hermes_bin="$(command -v hermes)"

# Resolve this service's own URL. HOME_STACK_SELF_URL is engine-injected into
# the generated plist, but `hs restart` (launchctl kickstart -k) re-execs a
# loaded job under its EXISTING environment -- launchd only re-reads a plist
# on bootstrap -- so a service started under an older plist (or before the
# next `install-launchd.sh --load`) would otherwise crash-loop under KeepAlive
# the moment this variable is required with no fallback. Fall back to the
# engine's own catalog.json (still registry-authoritative, never a
# profile-variable guess) before failing closed. See docs/RUNBOOK.md
# "Upgrading services whose plists changed". This replaces the former
# HOME_STACK_HERMES_PUBLIC_URL profile-variable copy of the registry's
# `subdomain: hermes`; common.sh still derives HOME_STACK_HERMES_PUBLIC_URL
# for other consumers, but this wrapper no longer reads it.
hermes_self_url="${HOME_STACK_SELF_URL:-}"
if [[ -z "$hermes_self_url" ]]; then
  hermes_self_url="$(home_stack_service_url hermes)" || {
    echo "home-stack: could not resolve hermes's own URL from HOME_STACK_SELF_URL or catalog.json" >&2
    echo "  HOME_STACK_SELF_URL is unset (stale plist under a running job?) and catalog.json has no routable url for hermes" >&2
    exit 78
  }
fi

# home_stack_load_env intentionally exports the complete four-layer stack
# environment for ordinary wrappers. Hermes is different: it is an agent that
# can execute tools and inspect its own process environment. Build a new,
# explicit child environment so unrelated Home Stack credentials never become
# agent authority merely because they share env.local.
hermes_env=(
  "HOME=$HOME_STACK_OWNER_HOME"
  "USER=$(/usr/bin/id -un)"
  "LOGNAME=$(/usr/bin/id -un)"
  "SHELL=/bin/zsh"
  "PATH=$HOME_STACK_PATH"
  "TMPDIR=${TMPDIR:-/tmp}"
  "LANG=en_US.UTF-8"
  "HERMES_HOME=$hermes_home"
  "HERMES_DASHBOARD_BASIC_AUTH_USERNAME=$HOME_STACK_HERMES_DASHBOARD_USERNAME"
  "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH=$HOME_STACK_HERMES_DASHBOARD_PASSWORD_HASH"
  "HERMES_DASHBOARD_BASIC_AUTH_SECRET=$HOME_STACK_HERMES_DASHBOARD_SECRET"
  "HERMES_DASHBOARD_PUBLIC_URL=$hermes_self_url"
)

# Single sign-on through the stack's own identity layer, via the `self-hosted`
# dashboard_auth plugin (generic OIDC, authorization-code + PKCE, discovery).
# Hermes integrates directly rather than sitting behind Caddy forward-auth
# because its CLI, Desktop, and mobile clients never traverse Caddy -- a proxy
# gate would cover exactly one of its four access surfaces.
#
# Deliberately additive: the password provider above stays configured, so an
# identity-layer outage cannot lock the dashboard out. Registering the OIDC
# client is an operator step (it needs an enrolled passkey), so this whole block
# stays inert until the credentials exist.
if [[ -n "${HOME_STACK_HERMES_OIDC_CLIENT_ID:-}" ]]; then
  # Issuer defaults to this stack's own Pocket ID, resolved from catalog.json
  # (the engine's generated sync artifact) rather than recomposed from a
  # profile subdomain variable -- so it can never silently drift from the
  # route the engine actually emits. HOME_STACK_HERMES_OIDC_ISSUER still wins
  # when set, for an external IdP. Hermes integrates with the IdP directly
  # rather than through the broker: it can speak OIDC itself, a direct client
  # lets Pocket ID apply per-client authorization (the broker makes every app
  # behind it look like one client), and it removes the broker from the path
  # of a service whose CLI and native clients never touch Caddy.
  hermes_oidc_issuer="${HOME_STACK_HERMES_OIDC_ISSUER:-}"
  if [[ -z "$hermes_oidc_issuer" ]]; then
    hermes_oidc_issuer="$(home_stack_service_url pocket-id)" || {
      echo "home-stack: could not resolve pocket-id's URL from catalog.json" >&2
      echo "  set HOME_STACK_HERMES_OIDC_ISSUER, or give pocket-id a routable subdomain/host" >&2
      exit 78
    }
  fi
  hermes_env+=(
    "HERMES_DASHBOARD_OIDC_ISSUER=$hermes_oidc_issuer"
    "HERMES_DASHBOARD_OIDC_CLIENT_ID=$HOME_STACK_HERMES_OIDC_CLIENT_ID"
    "HERMES_DASHBOARD_OIDC_SCOPES=${HOME_STACK_HERMES_OIDC_SCOPES:-openid profile email}"
  )
  if [[ -n "${HOME_STACK_HERMES_OIDC_CLIENT_SECRET:-}" ]]; then
    hermes_env+=("HERMES_DASHBOARD_OIDC_CLIENT_SECRET=$HOME_STACK_HERMES_OIDC_CLIENT_SECRET")
  fi
fi

exec /usr/bin/env -i "${hermes_env[@]}" "$hermes_bin" dashboard \
  --host "$HOME_STACK_TAILNET_IP" \
  --port "$HOME_STACK_HERMES_PORT" \
  --no-open
