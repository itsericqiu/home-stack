#!/usr/bin/env bash
# One-time setup: build the home-stack-test-base Tart image.
# Subsequent test runs clone this base.
set -euo pipefail

if ! command -v tart >/dev/null 2>&1; then
  echo "tart not installed; run: brew install cirruslabs/cli/tart" >&2
  exit 1
fi

BASE_IMAGE="ghcr.io/cirruslabs/macos-sequoia-base:latest"
TARGET_NAME="home-stack-test-base"

if tart list | grep -q "^$TARGET_NAME"; then
  echo "$TARGET_NAME already exists; delete with 'tart delete $TARGET_NAME' to rebuild"
  exit 0
fi

tart pull "$BASE_IMAGE"
tart clone "$BASE_IMAGE" "$TARGET_NAME"
tart run "$TARGET_NAME" --no-graphics &
VM_PID=$!

# Wait for SSH availability, then provision.
sleep 30
IP=$(tart ip "$TARGET_NAME")
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

SSHPASS="admin" sshpass -e ssh $SSH_OPTS "admin@$IP" <<'PROVISION'
set -euo pipefail
# Install Xcode CLT (interactive on first run; image base usually has them)
xcode-select --install 2>/dev/null || true
# Install Go
brew install go
# Install Tailscale CLI (just for the binary; service not needed)
brew install --cask tailscale
# Build caddy-cloudflare
go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
mkdir -p ~/.local/bin
# Plugin set must match the production recipe in docs/RUNBOOK.md: a test image
# without the tailscale plugin cannot adapt a Caddyfile containing an
# `auth: tailnet` route, so the tests would pass against a config the real
# ingress rejects.
CGO_ENABLED=0 GOARCH="$(uname -m | sed -e 's/^x86_64$/amd64/' -e 's/^aarch64$/arm64/')" \
  ~/go/bin/xcaddy build \
    --with github.com/caddy-dns/cloudflare \
    --with github.com/tailscale/caddy-tailscale \
    --output ~/.local/bin/caddy-cloudflare
# Configure passwordless launchctl for tests (sudoers entry)
echo "admin ALL=(root) NOPASSWD: /bin/launchctl" | sudo tee /etc/sudoers.d/home-stack-test
PROVISION

tart stop "$TARGET_NAME"
echo "Base image '$TARGET_NAME' ready. Run 'make help' to use it."
