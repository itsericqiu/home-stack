#!/usr/bin/env bash
# Home Stack bootstrap — guided first-time setup.
# Requires gum (brew install gum).
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname "$0")/../../.." && pwd)"
SCRIPT_DIR="$REPO_ROOT/portable/home-stack/scripts"

if ! command -v gum &>/dev/null; then
  echo "gum is required. Install it: brew install gum" >&2
  exit 1
fi

gum style \
  --border double --border-foreground=7 --padding "1 2" \
  --foreground 212 --bold \
  "Home Stack Bootstrap"

echo ""
gum style --foreground 240 "This will set up home-stack on this machine."
gum style --foreground 240 "You'll need: Tailscale installed, Cloudflare zone access, Go."
echo ""

# ── Prerequisites check ────────────────────────────────────────────────────
gum spin --spinner dot --title "Checking prerequisites…" -- sleep 0.5
for cmd in go tailscale git; do
  if ! command -v "$cmd" &>/dev/null; then
    gum style --foreground 1 "✗ Missing: $cmd"
    exit 1
  fi
done
gum style --foreground 2 "✓ Prerequisites: go tailscale git"

# ── Profile discovery ──────────────────────────────────────────────────────
DEFAULT_NAME="${HOME_STACK_PROFILE:-$(whoami)}"
PROFILE_NAME=$(gum input --header "Profile name" --placeholder "$DEFAULT_NAME" --value "$DEFAULT_NAME")
if [[ -z "$PROFILE_NAME" ]]; then
  gum style --foreground 1 "Profile name is required."
  exit 1
fi

gum style --foreground 2 "✓ Profile: $PROFILE_NAME"

# ── Mandatory variables ────────────────────────────────────────────────────
gum style --foreground 240 --margin "1 0" "Enter your profile values. Press Enter to accept defaults."

PARENT_DOMAIN=$(gum input --header "Parent domain" --placeholder "home.example.com" --value "${HOME_STACK_PARENT_DOMAIN:-}")
TAILNET_IP=$(gum input --header "Tailnet IPv4" --placeholder "100.64.0.8" --value "${HOME_STACK_TAILNET_IP:-}")
ACME_EMAIL=$(gum input --header "ACME email" --placeholder "admin@example.com" --value "${HOME_STACK_ACME_EMAIL:-}")
OWNER_HOME=$(gum input --header "Owner home directory" --placeholder "$HOME" --value "${HOME_STACK_OWNER_HOME:-$HOME}")
ID_PREFIX=$(gum input --header "Launchd identifier prefix (reverse DNS)" --placeholder "com.example" --value "${HOME_STACK_IDENTIFIER_PREFIX:-}")
ADMIN_USER=$(gum input --header "Admin username" --placeholder "admin" --value "${HOME_STACK_ADMIN_USERNAME:-admin}")

# ── Secrets ────────────────────────────────────────────────────────────────
gum style --foreground 240 --margin "1 0" "Now enter your secrets. These are stored in ~/.config/home-stack/env.local and never committed."

ADMIN_PW=$(gum input --password --header "Admin password")
CLOUDFLARE_TOKEN=$(gum input --password --header "Cloudflare API token" --placeholder "${HOME_STACK_CLOUDFLARE_API_TOKEN:+••••••••}")

# ── Build Caddy (one-time) ────────────────────────────────────────────────
# Two plugins, both load-bearing: cloudflare provides DNS-01 issuance, and
# tailscale provides the `tailscale_auth` directive behind `auth: tailnet`
# registry entries. A stock Caddy binary cannot serve this stack.
#
# GOARCH is pinned to the machine's real architecture because a Go toolchain
# installed for another architecture (an Intel build under Rosetta on Apple
# Silicon) otherwise emits a translated binary for the ingress.
gum spin --spinner dot --title "Building Caddy (this may take a minute)…" -- bash -c "
  if [[ ! -f '$REPO_ROOT/portable/home-stack/bin/caddy-cloudflare' ]]; then
    go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest 2>/dev/null
    CGO_ENABLED=0 \
    GOARCH=\"\$(uname -m | sed -e 's/^x86_64\$/amd64/' -e 's/^aarch64\$/arm64/')\" \
    ~/go/bin/xcaddy build \
      --with github.com/caddy-dns/cloudflare \
      --with github.com/tailscale/caddy-tailscale \
      --output '$REPO_ROOT/portable/home-stack/bin/caddy-cloudflare' 2>/dev/null
  fi
"
gum style --foreground 2 "✓ Caddy built with Cloudflare DNS + Tailscale auth modules"

# ── Build admin binary ─────────────────────────────────────────────────────
# `hs sync` (and `hs doctor`'s binary check) hard-require the admin binary at
# portable/home-stack/admin/home-stack-admin; nothing else in this script
# builds it. `make build-admin` derives GOARCH the same way the Caddy build
# above does, so this also produces a native binary rather than an emulated
# one.
gum spin --spinner dot --title "Building admin binary…" -- bash -c "
  cd '$REPO_ROOT' && make build-admin >/dev/null 2>&1
"
if [[ ! -x "$REPO_ROOT/portable/home-stack/admin/home-stack-admin" ]]; then
  gum style --foreground 1 "✗ Failed to build the admin binary — run 'make build-admin' from $REPO_ROOT and check the error"
  exit 1
fi
gum style --foreground 2 "✓ Admin binary built"

# ── hs init ────────────────────────────────────────────────────────────────
gum spin --spinner dot --title "Initializing profile…" -- bash -c "
  HOME_STACK_REPO_ROOT='$REPO_ROOT' '$SCRIPT_DIR/hs' init '$PROFILE_NAME' 2>/dev/null
"
gum style --foreground 2 "✓ Profile created: profiles/$PROFILE_NAME/"

# ── Write profile env ──────────────────────────────────────────────────────
PROFILE_ENV="$REPO_ROOT/profiles/$PROFILE_NAME/home-stack.env"
sed -i.bak \
  -e "s|HOME_STACK_PARENT_DOMAIN=.*|HOME_STACK_PARENT_DOMAIN=$PARENT_DOMAIN|" \
  -e "s|HOME_STACK_TAILNET_IP=.*|HOME_STACK_TAILNET_IP=$TAILNET_IP|" \
  -e "s|HOME_STACK_ACME_EMAIL=.*|HOME_STACK_ACME_EMAIL=$ACME_EMAIL|" \
  -e "s|HOME_STACK_OWNER_HOME=.*|HOME_STACK_OWNER_HOME=$OWNER_HOME|" \
  -e "s|HOME_STACK_IDENTIFIER_PREFIX=.*|HOME_STACK_IDENTIFIER_PREFIX=$ID_PREFIX|" \
  -e "s|HOME_STACK_ADMIN_USERNAME=.*|HOME_STACK_ADMIN_USERNAME=$ADMIN_USER|" \
  "$PROFILE_ENV"
rm -f "${PROFILE_ENV}.bak"
gum style --foreground 2 "✓ Profile env configured"

# ── Write secrets ──────────────────────────────────────────────────────────
CONFIG_DIR="${HOME_STACK_CONFIG_DIR:-$OWNER_HOME/.config/home-stack}"
mkdir -p "$CONFIG_DIR"
ENV_FILE="$CONFIG_DIR/env.local"
if [[ ! -f "$ENV_FILE" ]]; then
  touch "$ENV_FILE"
  chmod 600 "$ENV_FILE"
fi

# Update env.local with env-set (backs up existing, never echoes values)
if [[ -n "$CLOUDFLARE_TOKEN" ]]; then
  HOME_STACK_OWNER_HOME="$OWNER_HOME" HOME_STACK_CONFIG_DIR="$CONFIG_DIR" HOME_STACK_ENV_FILE="$ENV_FILE" \
    "$SCRIPT_DIR/env-set.sh" HOME_STACK_CLOUDFLARE_API_TOKEN "$CLOUDFLARE_TOKEN" >/dev/null
fi
if [[ -n "$ADMIN_PW" ]]; then
  HOME_STACK_OWNER_HOME="$OWNER_HOME" HOME_STACK_CONFIG_DIR="$CONFIG_DIR" HOME_STACK_ENV_FILE="$ENV_FILE" \
    "$SCRIPT_DIR/env-set.sh" HOME_STACK_ADMIN_PASSWORD "$ADMIN_PW" >/dev/null
fi
gum style --foreground 2 "✓ Secrets written to $ENV_FILE"

# ── hs doctor ──────────────────────────────────────────────────────────────
gum spin --spinner dot --title "Running hs doctor…" -- bash -c "
  HOME_STACK_REPO_ROOT='$REPO_ROOT' HOME_STACK_OWNER_HOME='$OWNER_HOME' HOME_STACK_PROFILE='$PROFILE_NAME' '$SCRIPT_DIR/hs' doctor 2>/dev/null && exit 0 || exit 0
"

# ── hs sync ────────────────────────────────────────────────────────────────
gum spin --spinner dot --title "Syncing registry (generating Caddyfile + launchd plists)…" -- bash -c "
  HOME_STACK_REPO_ROOT='$REPO_ROOT' HOME_STACK_OWNER_HOME='$OWNER_HOME' HOME_STACK_PROFILE='$PROFILE_NAME' '$SCRIPT_DIR/hs' sync 2>/dev/null
"
gum style --foreground 2 "✓ Registry synced"

# ── Install launchd ────────────────────────────────────────────────────────
gum spin --spinner dot --title "Installing launchd services…" -- bash -c "
  HOME_STACK_REPO_ROOT='$REPO_ROOT' HOME_STACK_OWNER_HOME='$OWNER_HOME' HOME_STACK_PROFILE='$PROFILE_NAME' '$SCRIPT_DIR/install-launchd.sh' --load 2>/dev/null
"
gum style --foreground 2 "✓ Services installed and loaded"

# ── Done ────────────────────────────────────────────────────────────────────
echo ""
gum style \
  --border double --border-foreground=2 --padding "1 2" \
  --foreground 2 --bold \
  "Home Stack is ready!"

echo ""
gum style --foreground 240 "Admin:  https://admin.$PARENT_DOMAIN/"
gum style --foreground 240 "Status: $SCRIPT_DIR/hs status"
gum style --foreground 240 "Doctor: $SCRIPT_DIR/hs doctor"
gum style --foreground 240 "Logs:   $CONFIG_DIR/logs/"
echo ""