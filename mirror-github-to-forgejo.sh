#!/bin/bash
###############################################################################
# mirror-github-to-forgejo.sh — Bulk-mirror GitHub repos to Forgejo
#
# Idempotent: skips repos that already exist in Forgejo.
# Mirrors only PRIVATE repos by default (--include-public to mirror all).
# Archived repos get a 168h poll interval; active repos get 10m.
#
# Usage:
#   GITHUB_PAT=$(cat /tmp/github-pat.txt) \
#   FORGEJO_TOKEN=$(cat /tmp/forgejo-token.txt) \
#       ./mirror-github-to-forgejo.sh
#
# Optional:
#   --include-public    Also mirror public repos (default: private only)
#   --org NAME          GitHub org (default: SREbuilt)
#   --forgejo-org NAME  Forgejo org (default: github-mirror)
#   --forgejo-url URL   Forgejo URL (default: https://192.168.178.84)
###############################################################################

set -euo pipefail

GITHUB_ORG="SREbuilt"
FORGEJO_URL="https://192.168.178.84"
FORGEJO_ORG="github-mirror"
INCLUDE_PUBLIC=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --include-public) INCLUDE_PUBLIC=1; shift ;;
        --org) GITHUB_ORG="$2"; shift 2 ;;
        --forgejo-org) FORGEJO_ORG="$2"; shift 2 ;;
        --forgejo-url) FORGEJO_URL="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

[[ -z "${GITHUB_PAT:-}" ]]   && { echo "FATAL: GITHUB_PAT not set"; exit 1; }
[[ -z "${FORGEJO_TOKEN:-}" ]] && { echo "FATAL: FORGEJO_TOKEN not set"; exit 1; }
command -v jq &>/dev/null || { echo "FATAL: 'jq' not installed"; exit 1; }
command -v curl &>/dev/null || { echo "FATAL: 'curl' not installed"; exit 1; }

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

# Stats
CREATED=0; SKIPPED=0; FAILED=0

echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  GitHub → Forgejo Bulk Mirror${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
echo "  GitHub org:    ${GITHUB_ORG}"
echo "  Forgejo URL:   ${FORGEJO_URL}"
echo "  Forgejo org:   ${FORGEJO_ORG}"
echo "  Scope:         $([ $INCLUDE_PUBLIC -eq 1 ] && echo 'private + public' || echo 'PRIVATE only')"
echo ""

# Fetch repo list from GitHub REST API (paginated)
# SREbuilt is a USER account (not an org), use /user/repos?affiliation=owner
REPOS_JSON="[]"
PAGE=1
while true; do
    PAGE_DATA=$(curl -ks -H "Authorization: Bearer ${GITHUB_PAT}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/user/repos?per_page=100&affiliation=owner&page=${PAGE}")
    COUNT=$(echo "$PAGE_DATA" | jq 'length' 2>/dev/null || echo "0")
    if [[ "$COUNT" -eq 0 ]]; then break; fi
    # Filter to only repos owned by GITHUB_ORG (user account)
    PAGE_FILTERED=$(echo "$PAGE_DATA" | jq --arg owner "$GITHUB_ORG" '[.[] | select(.owner.login == $owner)]')
    REPOS_JSON=$(echo "$REPOS_JSON" "$PAGE_FILTERED" | jq -s 'add')
    PAGE=$((PAGE + 1))
    [[ "$COUNT" -lt 100 ]] && break
done

# Normalize: produce array of {name, visibility, isArchived, description}
REPOS_JSON=$(echo "$REPOS_JSON" | jq '[.[] | {
    name: .name,
    visibility: (if .private then "PRIVATE" else "PUBLIC" end),
    isArchived: .archived,
    description: (.description // ""),
    isFork: .fork
}]')

# Filter visibility
if [[ $INCLUDE_PUBLIC -eq 0 ]]; then
    REPOS_JSON=$(echo "$REPOS_JSON" | jq '[.[] | select(.visibility == "PRIVATE")]')
fi

TOTAL=$(echo "$REPOS_JSON" | jq 'length')
echo "  Repos to process: $TOTAL"
echo ""

echo "$REPOS_JSON" | jq -c '.[]' | while read -r repo; do
    NAME=$(echo "$repo" | jq -r .name)
    VISIBILITY=$(echo "$repo" | jq -r .visibility)
    PRIVATE=$([ "$VISIBILITY" = "PRIVATE" ] && echo "true" || echo "false")
    ARCHIVED=$(echo "$repo" | jq -r .isArchived)
    DESCRIPTION=$(echo "$repo" | jq -r '.description // ""' | head -c 200)

    if [[ "$ARCHIVED" == "true" ]]; then
        INTERVAL="168h"
        PREFIX="[archived] "
    else
        INTERVAL="10m"
        PREFIX=""
    fi

    # Idempotency: check if mirror already exists
    EXISTS=$(curl -ks -o /dev/null -w "%{http_code}" \
        -H "Authorization: token ${FORGEJO_TOKEN}" \
        "${FORGEJO_URL}/api/v1/repos/${FORGEJO_ORG}/${NAME}")

    if [[ "$EXISTS" == "200" ]]; then
        echo -e "${YELLOW}✓ ${NAME}${NC} already mirrored — skip"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    printf "→ Migrating %-40s " "${NAME}..."

    HTTP_CODE=$(curl -ks -o "/tmp/migrate-${NAME}.json" -w "%{http_code}" \
        -X POST "${FORGEJO_URL}/api/v1/repos/migrate" \
        -H "Authorization: token ${FORGEJO_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$(jq -nc \
            --arg addr "https://github.com/${GITHUB_ORG}/${NAME}.git" \
            --arg token "$GITHUB_PAT" \
            --arg owner "$FORGEJO_ORG" \
            --arg name "$NAME" \
            --arg desc "${PREFIX}Pull mirror of github.com/${GITHUB_ORG}/${NAME} — ${DESCRIPTION}" \
            --arg interval "$INTERVAL" \
            --argjson private "$PRIVATE" \
            '{
                clone_addr: $addr,
                auth_token: $token,
                repo_owner: $owner,
                repo_name: $name,
                mirror: true,
                mirror_interval: $interval,
                private: $private,
                description: $desc,
                service: "github",
                issues: false,
                pull_requests: false,
                wiki: false,
                releases: false,
                milestones: false,
                labels: false,
                lfs: false
            }')")

    if [[ "$HTTP_CODE" == "201" ]]; then
        SIZE=$(jq -r '.size // 0' "/tmp/migrate-${NAME}.json")
        echo -e "${GREEN}✓ Created${NC} (size=${SIZE} interval=${INTERVAL})"
        CREATED=$((CREATED + 1))
        rm -f "/tmp/migrate-${NAME}.json"
    elif [[ "$HTTP_CODE" == "409" ]]; then
        echo -e "${YELLOW}✓ Already exists (race)${NC}"
        SKIPPED=$((SKIPPED + 1))
        rm -f "/tmp/migrate-${NAME}.json"
    else
        echo -e "${RED}✗ HTTP ${HTTP_CODE}${NC}"
        echo "  Error: $(cat /tmp/migrate-${NAME}.json | head -c 200)"
        FAILED=$((FAILED + 1))
    fi

    sleep 2
done

echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Summary${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
echo "  Created:  $CREATED"
echo "  Skipped:  $SKIPPED"
echo "  Failed:   $FAILED"
echo "  Total:    $TOTAL"

if [[ $FAILED -eq 0 ]]; then
    echo -e "${GREEN}✓ Done — all mirrors set up${NC}"
else
    echo -e "${RED}✗ Some mirrors failed — check /tmp/migrate-*.json${NC}"
    exit 1
fi
