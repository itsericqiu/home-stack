#!/usr/bin/env bash
# Safely append or update one key in home-stack's local env file.
# Always creates a timestamped backup before modifying an existing file.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
# Resolve profile-owned paths without executing unrelated existing secrets.
# The updater preserves env.local as data and replaces only the requested key.
HOME_STACK_SKIP_ENV_LOCAL=1
home_stack_load_env

usage() {
  echo "Usage: $0 KEY [VALUE]" >&2
  echo "If VALUE is omitted, it is read from stdin." >&2
}

key="${1:-}"
value="${2-}"
encoded_value=""

if [[ -z "$key" ]]; then
  usage
  exit 2
fi

if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
  echo "Unsafe env key: $key" >&2
  exit 2
fi

if [[ $# -lt 2 ]]; then
  # read returns non-zero at EOF even when it filled `value` (input without a
  # trailing newline). Under set -e that aborted here silently, after usage had
  # already printed nothing -- the caller saw success and no update. Tolerate
  # the EOF, then insist we actually received something.
  IFS= read -r value || true
  if [[ -z "$value" ]]; then
    echo "No value provided on stdin for $key; nothing updated." >&2
    exit 1
  fi
fi

# env.local is sourced as shell syntax. %q keeps dollar signs in password
# hashes, whitespace, quotes, and comment characters literal on the next load.
printf -v encoded_value '%q' "$value"

home_stack_ensure_runtime_dirs
touch "$HOME_STACK_ENV_FILE"
chmod 600 "$HOME_STACK_ENV_FILE"

lock_dir="$HOME_STACK_ENV_FILE.lock"
if ! mkdir "$lock_dir" 2>/dev/null; then
  echo "Could not acquire env file lock: $lock_dir" >&2
  exit 1
fi
tmp=""
trap 'rm -rf "$lock_dir" "${tmp:-}"' EXIT

timestamp="$(date +%Y%m%d-%H%M%S)"
backup="$HOME_STACK_ENV_FILE.bak.$timestamp"
counter=0
while [[ -e "$backup" ]]; do
  counter=$((counter + 1))
  backup="$HOME_STACK_ENV_FILE.bak.$timestamp.$counter"
done
cp -p "$HOME_STACK_ENV_FILE" "$backup"

tmp="$HOME_STACK_ENV_FILE.tmp.$$"

# Resolved from a trusted location rather than PATH: this script rewrites the
# 0600 secrets file, and home_stack_load_env has already replaced PATH with
# HOME_STACK_PATH, which front-loads user-writable dirs (/opt/homebrew/bin,
# ~/.local/bin, ~/go/bin). A planted grep there would see secrets.
# Not hardcoded to /usr/bin/grep: Alpine has no such path (grep lives in /bin),
# which is what broke the Linux container suite.
if [[ -x /usr/bin/grep ]]; then
  _grep=/usr/bin/grep
elif [[ -x /bin/grep ]]; then
  _grep=/bin/grep
else
  echo "env-set.sh: no grep in a trusted location (/usr/bin, /bin)" >&2
  exit 1
fi

if "$_grep" -qE "^${key}=" "$HOME_STACK_ENV_FILE"; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      "$key"=*) printf '%s=%s\n' "$key" "$encoded_value" ;;
      *) printf '%s\n' "$line" ;;
    esac
  done <"$HOME_STACK_ENV_FILE" >"$tmp"
else
  cp "$HOME_STACK_ENV_FILE" "$tmp"
  if [[ -s "$tmp" ]]; then
    last_char="$(tail -c 1 "$tmp" || true)"
    if [[ -n "$last_char" ]]; then
      printf '\n' >>"$tmp"
    fi
  fi
  printf '%s=%s\n' "$key" "$encoded_value" >>"$tmp"
fi

chmod 600 "$tmp"
mv "$tmp" "$HOME_STACK_ENV_FILE"
rm -rf "$lock_dir"
trap - EXIT

echo "Updated $key in $HOME_STACK_ENV_FILE (backup: $backup)"
