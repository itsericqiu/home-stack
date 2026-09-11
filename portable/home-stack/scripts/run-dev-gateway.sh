#!/bin/bash
set -e

# Discover the root directory
SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"
while [ -h "$SCRIPT_SOURCE" ]; do
  LINK="$(readlink "$SCRIPT_SOURCE")"
  if [[ "$LINK" == /* ]]; then
    SCRIPT_SOURCE="$LINK"
  else
    SCRIPT_SOURCE="$(dirname "$SCRIPT_SOURCE")/$LINK"
  fi
done
SCRIPT_DIR="$(cd -- "$(dirname "$SCRIPT_SOURCE")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

# Load profile + secrets
home_stack_load_env

# Export the bundle dir
export HOME_STACK_BUNDLE_DIR="$HOME_STACK_BUNDLE_DIR"

APP_DIR="$HOME_STACK_BUNDLE_DIR/dev-gateway"
if [[ ! -d "$APP_DIR" ]]; then
  echo "Error: dev-gateway directory not found at $APP_DIR" >&2
  exit 1
fi

cd "$APP_DIR"

# Build the binary to a temporary location
TMP_BIN="/tmp/home-stack-dev-gateway"
echo "Building dev-gateway from $APP_DIR..." >&2
if ! go build -o "$TMP_BIN" main.go; then
  echo "Error: 'go build' failed in $APP_DIR" >&2
  exit 1
fi

# Execute the binary
echo "Starting dev-gateway..." >&2
exec "$TMP_BIN"
