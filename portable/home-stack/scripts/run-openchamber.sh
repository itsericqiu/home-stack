#!/usr/bin/env bash
# launchd foreground wrapper for OpenChamber, using external OpenCode.
# Intentionally uses OpenChamber's normal user state directory.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
home_stack_load_env

export PATH="$HOME_STACK_PATH"

if [[ -n "${HOME_STACK_OPENCHAMBER_UI_PASSWORD:-}" ]]; then
  export OPENCHAMBER_UI_PASSWORD="$HOME_STACK_OPENCHAMBER_UI_PASSWORD"
fi

if [[ -n "${HOME_STACK_OPENCODE_SERVER_PASSWORD:-}" ]]; then
  export OPENCODE_SERVER_PASSWORD="$HOME_STACK_OPENCODE_SERVER_PASSWORD"
fi

export OPENCODE_HOST="http://127.0.0.1:$HOME_STACK_OPENCODE_PORT"
export OPENCODE_SKIP_START=true

exec openchamber serve --host 127.0.0.1 --port "$HOME_STACK_OPENCHAMBER_PORT" --foreground
