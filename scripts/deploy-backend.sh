#!/usr/bin/env bash
# Deploy (pull + recreate) backend-dev service on the VM.
#
# Usage:
#   ./scripts/deploy-backend.sh               # use BACKEND_DEV_TAG from .env
#   ./scripts/deploy-backend.sh sha-ca11d58   # one-shot override to a specific tag
set -euo pipefail

INFRA_DIR="${INFRA_DIR:-/srv/jaram/infra}"
cd "$INFRA_DIR"

# One-shot tag override (does NOT modify .env).
if [ "${1:-}" != "" ]; then
  export BACKEND_DEV_TAG="$1"
fi

echo "[backend-dev] pulling image (tag=${BACKEND_DEV_TAG:-develop})..."
docker compose pull backend-dev

echo "[backend-dev] starting service (waits for healthy)..."
# --wait blocks until the service (and dependencies) reach healthy (or timeout).
# --wait-timeout requires docker compose v2.18+.
docker compose up -d --wait --wait-timeout 120 backend-dev

echo "[backend-dev] status:"
docker compose ps backend-dev
