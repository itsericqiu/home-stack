#!/bin/bash
set -e

# Discover the root directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

# Load profile + secrets
home_stack_load_env

# Export the bundle dir for the admin binary
export HOME_STACK_BUNDLE_DIR="$HOME_STACK_BUNDLE_DIR"

ADMIN_DIR="$HOME_STACK_BUNDLE_DIR/admin"
if [[ ! -d "$ADMIN_DIR" ]]; then
  echo "Error: admin directory not found at $ADMIN_DIR" >&2
  exit 1
fi

cd "$ADMIN_DIR"

# Build the admin binary to the bundle dir if missing. It persists across reboots.
# /tmp was previously used but is cleared on restart, breaking auto-start.
ADMIN_BIN="$ADMIN_DIR/home-stack-admin"
if [[ ! -f "$ADMIN_BIN" ]]; then
  if ! command -v go >/dev/null 2>&1; then
    echo "Error: 'go' binary not found in PATH: $PATH" >&2
    exit 127
  fi
  echo "Building admin backend from $ADMIN_DIR..." >&2
  if ! go build -o "$ADMIN_BIN" .; then
    echo "Error: 'go build' failed in $ADMIN_DIR" >&2
    exit 1
  fi
fi

# Execute the binary
exec "$ADMIN_BIN"
