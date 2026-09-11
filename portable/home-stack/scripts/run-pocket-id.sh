#!/usr/bin/env bash
# launchd foreground wrapper for Pocket ID, the passkey-only OIDC provider.
#
# Pocket ID is the identity source behind `auth: sso` routes: tinyauth brokers
# the login and defers the passkey ceremony here. It holds credential material,
# so it binds loopback only and is reachable exclusively through Caddy.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
home_stack_load_env

export PATH="$HOME_STACK_PATH"
export HOME="$HOME_STACK_OWNER_HOME"

POCKET_ID_BIN="${POCKET_ID_BIN:-$HOME_STACK_BUNDLE_DIR/bin/pocket-id}"
if [[ ! -x "$POCKET_ID_BIN" ]]; then
  echo "home-stack: pocket-id binary not found at $POCKET_ID_BIN" >&2
  echo "  see docs/RUNBOOK.md -> \"Install Pocket ID\" for the download and checksum step" >&2
  exit 127
fi

if [[ -z "${HOME_STACK_POCKET_ID_ENCRYPTION_KEY:-}" ]]; then
  echo "home-stack: HOME_STACK_POCKET_ID_ENCRYPTION_KEY is not set" >&2
  echo "  generate one with: scripts/env-set.sh HOME_STACK_POCKET_ID_ENCRYPTION_KEY" >&2
  exit 1
fi

PORT="${HOME_STACK_POCKET_ID_PORT:-31520}"
DATA_DIR="${HOME_STACK_DATA_DIR:-$HOME_STACK_CONFIG_DIR/data/pocket-id}"
mkdir -p "$DATA_DIR/uploads"

# HOST defaults to 0.0.0.0 upstream, which would put an identity provider on
# every interface. Pin it to loopback per docs/SERVICE_INTERFACE.md; Caddy is
# the only path in.
export HOST="127.0.0.1"
export PORT

# Resolve this service's own URL. HOME_STACK_SELF_URL is engine-injected into
# the generated plist, but `hs restart` (launchctl kickstart -k) re-execs a
# loaded job under its EXISTING environment -- launchd only re-reads a plist
# on bootstrap -- so a service started under an older plist (or before the
# next `install-launchd.sh --load`) would otherwise crash-loop under KeepAlive
# the moment this variable is required with no fallback. Fall back to the
# engine's own catalog.json (still registry-authoritative, never a
# profile-variable guess) before failing closed. See docs/RUNBOOK.md
# "Upgrading services whose plists changed".
APP_SELF_URL="${HOME_STACK_SELF_URL:-}"
if [[ -z "$APP_SELF_URL" ]]; then
  APP_SELF_URL="$(home_stack_service_url pocket-id)" || {
    echo "home-stack: could not resolve pocket-id's own URL from HOME_STACK_SELF_URL or catalog.json" >&2
    echo "  HOME_STACK_SELF_URL is unset (stale plist under a running job?) and catalog.json has no routable url for pocket-id" >&2
    exit 78
  }
fi
export APP_URL="$APP_SELF_URL"
export ENCRYPTION_KEY="$HOME_STACK_POCKET_ID_ENCRYPTION_KEY"

# There is no single data-dir variable; each path is set individually, and the
# defaults are relative to the working directory rather than absolute.
export DB_CONNECTION_STRING="$DATA_DIR/pocket-id.db"
export UPLOAD_PATH="$DATA_DIR/uploads"
export GEOLITE_DB_PATH="$DATA_DIR/GeoLite2-City.mmdb"

# Caddy terminates TLS and is the only client, so the forwarded client IP is
# trustworthy exactly to the extent Caddy is. Trust loopback only.
export TRUST_PROXY="127.0.0.1"

# HOST only governs the HTTP listener. Pocket ID also runs an actor-host peer
# WebTransport server, which defaults to UDP 0.0.0.0:1414 -- reachable from
# every interface, including the tailnet. ACTORS_HOST pins it to loopback.
# This is a single-node deployment, so nothing needs to reach that port.
#
# Worth stating plainly because it is easy to miss: `lsof -iTCP` does not show
# it. Verify listeners with `lsof -nP -a -p <pid> -i`, which covers UDP too.
export ACTORS_HOST="127.0.0.1"
export ACTORS_PORT="${HOME_STACK_POCKET_ID_ACTORS_PORT:-31522}"

# Application settings -- SMTP, app name, session duration, signup policy --
# are Pocket ID's own configuration and are deliberately left to its admin UI.
# home-stack owns routing, supervision, ports, binds and secrets; it does not
# own an app's internal preferences (docs/ARCHITECTURE.md).
#
# Driving them from here is possible but costs more than it returns: Pocket ID
# only reads them from the environment when UI_CONFIG_DISABLED is set, and that
# switch is all-or-nothing. Declaring SMTP would therefore make every other
# setting env-only too, leaving the admin UI read-only for settings that have
# nothing to do with this stack. Configure email in the UI instead; it stores
# the password encrypted in its own database.
exec "$POCKET_ID_BIN"
