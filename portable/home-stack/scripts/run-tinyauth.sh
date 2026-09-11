#!/usr/bin/env bash
# launchd foreground wrapper for tinyauth, the forward-auth broker.
#
# tinyauth is the endpoint Caddy calls for `auth: sso` and the fallback lane of
# `auth: tailnet-or-sso`. It federates login backends (Tailscale identity today,
# Pocket ID passkeys via OIDC, LDAP later) so downstream services never learn
# more than one identity protocol.
#
# Built from source: upstream publishes Linux-only binaries. See
# docs/RUNBOOK.md -> "Build tinyauth" for the pinned commit and recipe.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
home_stack_load_env

export PATH="$HOME_STACK_PATH"
export HOME="$HOME_STACK_OWNER_HOME"

TINYAUTH_BIN="${TINYAUTH_BIN:-$HOME_STACK_BUNDLE_DIR/bin/tinyauth}"
if [[ ! -x "$TINYAUTH_BIN" ]]; then
  echo "home-stack: tinyauth binary not found at $TINYAUTH_BIN" >&2
  echo "  see docs/RUNBOOK.md -> \"Build tinyauth\"" >&2
  exit 127
fi

if [[ -z "${HOME_STACK_TINYAUTH_SECRET:-}" ]]; then
  echo "home-stack: HOME_STACK_TINYAUTH_SECRET is not set" >&2
  echo "  generate one with: scripts/env-set.sh HOME_STACK_TINYAUTH_SECRET" >&2
  exit 1
fi

DATA_DIR="${HOME_STACK_DATA_DIR:-$HOME_STACK_CONFIG_DIR/data/tinyauth}"
mkdir -p "$DATA_DIR/resources"

# Config is loaded by paerser: TINYAUTH_ prefix, nested fields joined by _.
#
# Resolve this service's own URL. HOME_STACK_SELF_URL is engine-injected into
# the generated plist, but `hs restart` (launchctl kickstart -k) re-execs a
# loaded job under its EXISTING environment -- launchd only re-reads a plist
# on bootstrap -- so a service started under an older plist (or before the
# next `install-launchd.sh --load`) would otherwise crash-loop under KeepAlive
# the moment this variable is required with no fallback. Fall back to the
# engine's own catalog.json (still registry-authoritative, never a
# profile-variable guess) before failing closed. See docs/RUNBOOK.md
# "Upgrading services whose plists changed".
TINYAUTH_SELF_URL="${HOME_STACK_SELF_URL:-}"
if [[ -z "$TINYAUTH_SELF_URL" ]]; then
  TINYAUTH_SELF_URL="$(home_stack_service_url tinyauth)" || {
    echo "home-stack: could not resolve tinyauth's own URL from HOME_STACK_SELF_URL or catalog.json" >&2
    echo "  HOME_STACK_SELF_URL is unset (stale plist under a running job?) and catalog.json has no routable url for tinyauth" >&2
    exit 78
  }
fi
export TINYAUTH_APPURL="$TINYAUTH_SELF_URL"
export TINYAUTH_SECRET="$HOME_STACK_TINYAUTH_SECRET"

# Upstream defaults to 0.0.0.0. Caddy is the only client; keep the broker off
# every other interface per docs/SERVICE_INTERFACE.md.
export TINYAUTH_SERVER_ADDRESS="127.0.0.1"
export TINYAUTH_SERVER_PORT="${HOME_STACK_TINYAUTH_PORT:-31521}"

# Every default path is relative to the working directory, which under launchd
# is not this bundle. Pin them all under the standard data dir so state lands
# in one backup-able place.
export TINYAUTH_DATABASE_PATH="$DATA_DIR/tinyauth.db"
export TINYAUTH_RESOURCES_PATH="$DATA_DIR/resources"
export TINYAUTH_OIDC_PRIVATEKEYPATH="$DATA_DIR/tinyauth_oidc_key"
export TINYAUTH_OIDC_PUBLICKEYPATH="$DATA_DIR/tinyauth_oidc_key.pub"

# Analytics phone home by default. This is a private single-user stack.
export TINYAUTH_ANALYTICS_ENABLED="false"

# Without this tinyauth logs "IP access controls will NOT work" and ignores
# forwarded client addresses -- which would also defeat its Tailscale identity
# detection, since that matches on the real client IP. Caddy is the only client
# and it runs on loopback, so trust exactly that.
export TINYAUTH_AUTH_TRUSTEDPROXIES="127.0.0.1"

# tinyauth refuses to boot with no authentication provider at all. A local
# break-glass account satisfies that and stays useful: if the Pocket ID or
# Tailscale providers are misconfigured, this is how you still get in. Only the
# bcrypt hash lives in env.local; the plaintext belongs in the login Keychain
# under "<identifier-prefix>.home-stack.tinyauth.breakglass", mirroring how the
# Hermes dashboard password is handled. See docs/RUNBOOK.md.
if [[ -n "${HOME_STACK_TINYAUTH_USERS:-}" ]]; then
  export TINYAUTH_AUTH_USERS="$HOME_STACK_TINYAUTH_USERS"
fi

# Pocket ID as the passkey provider, registered as a generic OAuth provider
# under the key `pocketid`. tinyauth does not do OIDC discovery here — it takes
# explicit endpoint URLs — and the provider key is what appears in the callback
# path, so it must match the redirect URI registered in Pocket ID:
#   https://<tinyauth host>/api/oauth/callback/pocketid
# Registering the client is an operator step (it needs an enrolled passkey
# first), so this stays inert until the credentials exist.
if [[ -n "${HOME_STACK_TINYAUTH_OIDC_CLIENTID:-}" && -n "${HOME_STACK_TINYAUTH_OIDC_CLIENTSECRET:-}" ]]; then
  pocket_id_base="$(home_stack_service_url pocket-id)" || {
    echo "home-stack: could not resolve pocket-id's URL from catalog.json" >&2
    echo "  tinyauth OIDC client vars are set but pocket-id has no routable subdomain/host" >&2
    exit 78
  }
  export TINYAUTH_OAUTH_PROVIDERS_POCKETID_CLIENTID="$HOME_STACK_TINYAUTH_OIDC_CLIENTID"
  export TINYAUTH_OAUTH_PROVIDERS_POCKETID_CLIENTSECRET="$HOME_STACK_TINYAUTH_OIDC_CLIENTSECRET"
  export TINYAUTH_OAUTH_PROVIDERS_POCKETID_AUTHURL="$pocket_id_base/authorize"
  export TINYAUTH_OAUTH_PROVIDERS_POCKETID_TOKENURL="$pocket_id_base/api/oidc/token"
  export TINYAUTH_OAUTH_PROVIDERS_POCKETID_USERINFOURL="$pocket_id_base/api/oidc/userinfo"
  export TINYAUTH_OAUTH_PROVIDERS_POCKETID_SCOPES="openid,profile,email"
  export TINYAUTH_OAUTH_PROVIDERS_POCKETID_NAME="Pocket ID"
  export TINYAUTH_OAUTH_PROVIDERS_POCKETID_REDIRECTURL="$TINYAUTH_APPURL/api/oauth/callback/pocketid"
fi

# Tailscale identity is optional and off unless an API token is provisioned.
# Note this is the Tailscale *control-plane* API, not the local WhoIs used by
# `auth: tailnet` at Caddy -- the zero-click path needs nothing from here.
if [[ -n "${HOME_STACK_TINYAUTH_TAILSCALE_APITOKEN:-}" && -n "${HOME_STACK_TINYAUTH_TAILNET:-}" ]]; then
  export TINYAUTH_TAILSCALE_ENABLED="true"
  export TINYAUTH_TAILSCALE_APITOKEN="$HOME_STACK_TINYAUTH_TAILSCALE_APITOKEN"
  export TINYAUTH_TAILSCALE_TAILNET="$HOME_STACK_TINYAUTH_TAILNET"
fi

exec "$TINYAUTH_BIN"
