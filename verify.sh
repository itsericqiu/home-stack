#!/usr/bin/env bash
set -euo pipefail

echo "Phase A local verification: checking home-stack endpoints..."
TIMEOUT=5

if command -v curl >/dev/null 2>&1; then
  curl -sS http://127.0.0.1:31497/ > /dev/null 2>&1 || { echo "OpenChamber not responding on 127.0.0.1:31497"; exit 1; }
  curl -sS http://127.0.0.1:31496/ > /dev/null 2>&1 || { echo "OpenCode not responding on 127.0.0.1:31496"; exit 1; }
  curl -sS http://127.0.0.1:31480/ > /dev/null 2>&1 || { echo "Caddy Proxy not responding on 127.0.0.1:31480"; exit 1; }
else
  echo "curl not available"; exit 1
fi

echo "Home-stack OpenChamber, OpenCode, and local proxy endpoints are responding."
exit 0
