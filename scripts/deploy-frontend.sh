#!/usr/bin/env bash
# Deploy (pull + recreate) frontend-dev service on the VM.
#
# Usage:
#   ./scripts/deploy-frontend.sh               # use FRONTEND_DEV_TAG from .env
#   ./scripts/deploy-frontend.sh sha-ca11d58   # one-shot override to a specific tag
set -euo pipefail

INFRA_DIR="${INFRA_DIR:-/srv/jaram/infra}"
cd "$INFRA_DIR"

# One-shot tag override (does NOT modify .env).
if [ "${1:-}" != "" ]; then
  export FRONTEND_DEV_TAG="$1"
fi

echo "[frontend-dev] pulling image (tag=${FRONTEND_DEV_TAG:-develop})..."
docker compose pull frontend-dev

echo "[frontend-dev] starting service (waits for healthy)..."
# --wait blocks until all dependent services reach healthy (or timeout).
# --wait-timeout requires docker compose v2.18+.
docker compose up -d --wait --wait-timeout 120 frontend-dev

echo "[frontend-dev] status:"
docker compose ps frontend-dev
