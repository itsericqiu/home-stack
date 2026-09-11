#!/usr/bin/env bash
# Ad-hoc process status helper for local harness debugging.
set -euo pipefail
echo "Status check (simplified):"
ps aux | grep -E 'opencode|openchamber|caddy' | grep -v grep || true
