#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_TAG="home-stack-test:linux"

# Prefer Apple Container CLI on Apple Silicon; fall back to docker.
if command -v container >/dev/null 2>&1; then
  RUNNER="container"
elif command -v docker >/dev/null 2>&1; then
  RUNNER="docker"
else
  echo "no container runtime found (need 'container' or 'docker')" >&2
  exit 1
fi

$RUNNER build -f "$REPO_ROOT/Dockerfile.linux-test" -t "$IMAGE_TAG" "$REPO_ROOT"
$RUNNER run --rm -v "$REPO_ROOT":/repo:ro "$IMAGE_TAG" "make test-linux-inner"
