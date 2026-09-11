#!/usr/bin/env bash
set -euo pipefail

if ! command -v tart >/dev/null 2>&1; then
  echo "tart not installed; run: brew install cirruslabs/cli/tart" >&2
  exit 1
fi

REPO_ROOT="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="home-stack-test-base"
RUN_NAME="home-stack-test-run-$$"

if ! tart list | grep -q "$BASE"; then
  echo "base image '$BASE' not built; run tools/build-tart-base.sh first" >&2
  exit 1
fi

cleanup() {
  tart stop "$RUN_NAME" 2>/dev/null || true
  tart delete "$RUN_NAME" 2>/dev/null || true
}
trap cleanup EXIT

tart clone "$BASE" "$RUN_NAME"
tart run "$RUN_NAME" --dir "repo:$REPO_ROOT" --no-graphics &
sleep 30

IP=$(tart ip "$RUN_NAME")
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes"
REMOTE_CMD="export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\$HOME/.local/bin:\$HOME/go/bin && cd /Volumes/My\\ Shared\\ Files/repo && make test-mac-inner"
SSHPASS="admin" sshpass -e ssh $SSH_OPTS "admin@$IP" "$REMOTE_CMD"
