#!/usr/bin/env bash
# launchd foreground wrapper for the central OpenCode backend.
# Intentionally uses OpenCode's normal user config/data directories.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
home_stack_load_env

export PATH="$HOME_STACK_PATH"

if [[ -n "${HOME_STACK_OPENCODE_SERVER_PASSWORD:-}" ]]; then
  export OPENCODE_SERVER_PASSWORD="$HOME_STACK_OPENCODE_SERVER_PASSWORD"
fi

exec opencode serve --hostname 127.0.0.1 --port "$HOME_STACK_OPENCODE_PORT"
