#!/bin/bash
# Alert if any Forgejo mirror has not synced in > 2 hours
set -euo pipefail
FORGEJO_URL="https://192.168.178.84"
FORGEJO_ORG="github-mirror"
FORGEJO_TOKEN_FILE="/root/.forgejo-token"

[[ ! -f "$FORGEJO_TOKEN_FILE" ]] && { echo "FATAL: $FORGEJO_TOKEN_FILE missing"; exit 1; }
TOKEN=$(cat "$FORGEJO_TOKEN_FILE")
THRESHOLD=$(date -u -d "2 hours ago" +%FT%TZ)

STALE=$(curl -ks -H "Authorization: token $TOKEN" \
    "${FORGEJO_URL}/api/v1/orgs/${FORGEJO_ORG}/repos?limit=100" \
    | jq -r --arg t "$THRESHOLD" \
        '.[] | select(.mirror_updated < $t) | "\(.name) last=\(.mirror_updated)"')

if [[ -n "$STALE" ]]; then
    echo "[$(date)] FORGEJO MIRROR STALE (>2h):"
    echo "$STALE"
    exit 1
fi
echo "[$(date)] All mirrors fresh"
