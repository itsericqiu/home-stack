#!/usr/bin/env bash
# Install helper symlinks into a user bin directory.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
home_stack_load_env

BIN_DIR="${HOME_STACK_BIN_DIR:-$HOME_STACK_OWNER_HOME/bin}"
NO_PATH_UPDATE=0
WITH_OPS=0

for arg in "$@"; do
  case "$arg" in
    --no-path-update)
      NO_PATH_UPDATE=1
      ;;
    --with-ops)
      WITH_OPS=1
      ;;
    *)
      echo "Usage: $0 [--with-ops] [--no-path-update]" >&2
      exit 2
      ;;
  esac
done

mkdir -p "$BIN_DIR"

ln -sf "$HOME_STACK_BUNDLE_DIR/scripts/oc" "$BIN_DIR/oc"
ln -sf "$HOME_STACK_BUNDLE_DIR/scripts/occ" "$BIN_DIR/occ"

echo "Installed helper links:"
echo "  $BIN_DIR/oc"
echo "  $BIN_DIR/occ"

if [[ "$WITH_OPS" == "1" ]]; then
  ln -sf "$HOME_STACK_BUNDLE_DIR/scripts/hs" "$BIN_DIR/hs"
  ln -sf "$HOME_STACK_BUNDLE_DIR/scripts/status-launchd.sh" "$BIN_DIR/hs-status"
  echo "  $BIN_DIR/hs"
  echo "  $BIN_DIR/hs-status"
fi

if [[ "$NO_PATH_UPDATE" == "1" ]]; then
  exit 0
fi

if [[ ":$PATH:" == *":$BIN_DIR:"* ]]; then
  echo "$BIN_DIR is already on PATH"
  exit 0
fi

ZSHRC="$HOME_STACK_OWNER_HOME/.zshrc"
PATH_LINE="export PATH=\"$BIN_DIR:\$PATH\""

if [[ -f "$ZSHRC" ]] && grep -Fq "$BIN_DIR" "$ZSHRC"; then
  echo "$BIN_DIR appears in $ZSHRC; open a new shell to pick it up"
  exit 0
fi

echo "$PATH_LINE" >> "$ZSHRC"
echo "Added PATH update to $ZSHRC"
echo "Run: source $ZSHRC"
