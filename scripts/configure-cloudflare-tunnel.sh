#!/usr/bin/env bash
# Push ingress rules to the Cloudflare tunnel bound to TUNNEL_TOKEN.
#
# Token-based tunnels are remotely-managed: ingress rules live in Cloudflare's
# API, not in a local config.yml (cloudflared ignores local ingress when run
# with --token). This script pushes the dev routing config:
#
#   dev.jaram.net    -> http://home-jaram-frontend-dev:80     (FE web)
#   devapi.jaram.net -> http://home-jaram-backend-dev:8080    (BE API)
#   catch-all        -> 404
#
# Prerequisites:
#   - TUNNEL_TOKEN in .env (tunnel connector token from Zero Trust dashboard)
#   - CF_API_TOKEN in env or .env (API token with "Cloudflare Tunnel: Edit" scope)
#     Create at: https://dash.cloudflare.com/profile/api-tokens
#   - jq + curl installed
#
# Usage:
#   ./scripts/configure-cloudflare-tunnel.sh           # apply dev routing
#   ./scripts/configure-cloudflare-tunnel.sh --show    # print current config only
set -euo pipefail

INFRA_DIR="${INFRA_DIR:-/srv/jaram/infra}"
cd "$INFRA_DIR"

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

: "${TUNNEL_TOKEN:?TUNNEL_TOKEN is required in .env}"
: "${CF_API_TOKEN:?CF_API_TOKEN is required (create at https://dash.cloudflare.com/profile/api-tokens with 'Cloudflare Tunnel: Edit' scope)}"

command -v jq   >/dev/null || { echo "ERROR: jq not installed";   exit 1; }
command -v curl >/dev/null || { echo "ERROR: curl not installed"; exit 1; }

# Token is base64-encoded JSON: {"a":"<account_id>","t":"<tunnel_id>","s":"<secret>"}
TOKEN_JSON=$(echo "$TUNNEL_TOKEN" | base64 -d 2>/dev/null || echo "")
[ -z "$TOKEN_JSON" ] && { echo "ERROR: TUNNEL_TOKEN is not valid base64"; exit 1; }

ACCOUNT_ID=$(echo "$TOKEN_JSON" | jq -r '.a // empty')
TUNNEL_ID=$(echo "$TOKEN_JSON"  | jq -r '.t // empty')
[ -z "$ACCOUNT_ID" ] && { echo "ERROR: could not extract account_id from token"; exit 1; }
[ -z "$TUNNEL_ID" ]  && { echo "ERROR: could not extract tunnel_id from token";  exit 1; }

echo "[cloudflared] account=$ACCOUNT_ID tunnel=$TUNNEL_ID"
echo

API_BASE="https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations"

if [ "${1:-}" = "--show" ]; then
  echo "[cloudflared] current tunnel configuration:"
  curl -sS -X GET "$API_BASE" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" | jq .
  exit 0
fi

# Ingress rules — keep in sync with compose.yml cloudflared service comment.
# Last rule MUST be a catch-all (no hostname) per cloudflared requirement.
INGRESS_CONFIG='{
  "config": {
    "ingress": [
      {"hostname": "dev.jaram.net",    "service": "http://home-jaram-frontend-dev:80"},
      {"hostname": "devapi.jaram.net", "service": "http://home-jaram-backend-dev:8080"},
      {"service": "http_status:404"}
    ]
  }
}'

echo "[cloudflared] applying ingress configuration:"
echo "$INGRESS_CONFIG" | jq .
echo

RESPONSE=$(curl -sS -X PUT "$API_BASE" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json" \
  --data "$INGRESS_CONFIG")

echo "[cloudflared] API response:"
echo "$RESPONSE" | jq .

SUCCESS=$(echo "$RESPONSE" | jq -r '.success // false')
if [ "$SUCCESS" = "true" ]; then
  echo
  echo "[cloudflared] OK — ingress rules applied. Tunnel picks up config within ~30s."
  echo "  Verify: curl -sI https://dev.jaram.net/  (expect CF headers)"
else
  echo
  echo "[cloudflared] FAIL — API call failed. Check CF_API_TOKEN scope (needs 'Cloudflare Tunnel: Edit')."
  exit 1
fi
