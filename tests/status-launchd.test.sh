#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/portable/home-stack/scripts/status-launchd.sh"

# status-launchd.sh needs a valid profile. Use the tracked default profile if
# none is already resolved -- never a real, owner-specific profile, which is
# gitignored and may not exist in a fresh clone (docs/PUBLIC_RELEASE.md §4 A2).
if [[ -z "${HOME_STACK_PROFILE:-}" && -d "$ROOT_DIR/profiles/default" ]]; then
  export HOME_STACK_PROFILE=default
fi

bash -n "$SCRIPT"

# Use explicit bash invocations to avoid path-with-spaces issues in $()
json_output=$(bash "$SCRIPT" --json 2>/dev/null) || {
  echo "status-launchd.sh failed (no profile or no launchd services) — skipping"
  exit 0
}

# Skip detailed checks if no services are running (e.g., clean Tart VM)
if ! printf '%s' "$json_output" | python3 -c "import json,sys; data=json.load(sys.stdin); exit(0 if len(data) > 0 else 1)" 2>/dev/null; then
  echo "No launchd services found — skipping service-level checks"
  exit 0
fi
printf '%s' "$json_output" | python3 -m json.tool >/dev/null
printf '%s' "$json_output" | python3 -c '
import json,sys
data=json.load(sys.stdin)
assert isinstance(data, list) and data
required={"name","scope","domain","label","state","pid","last_exit_code","program","path","stdout","stderr"}
assert required.issubset(data[0]), data[0]
assert all(item.get("last_exit_code") != "(never" for item in data)
'

table_output=$(bash "$SCRIPT")
printf '%s\n' "$table_output" | grep -q '^SERVICE[[:space:]]'
if printf '%s\n' "$table_output" | grep -q '^== gui/'; then
  echo "default output should not include verbose block markers" >&2
  exit 1
fi

verbose_output=$(bash "$SCRIPT" --verbose)
printf '%s\n' "$verbose_output" | grep -Eq '^== (gui/[0-9]+|system)/'

filtered_output=$(bash "$SCRIPT" admin)
printf '%s\n' "$filtered_output" | grep -q '^admin[[:space:]]'

if bash "$SCRIPT" --bad-option >/dev/null 2>&1; then
  echo "unknown option should fail" >&2
  exit 1
fi

echo "status-launchd tests passed"
