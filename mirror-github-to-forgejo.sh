#!/bin/bash
###############################################################################
# mirror-github-to-forgejo.sh — Bulk-mirror GitHub repos + install monitoring
#
# Performs these phases (all idempotent):
#   1. Bulk-mirror GitHub repos via Forgejo's migrate API
#   2. Persist Forgejo token to /root/.forgejo-token (chmod 600)
#   3. Bind-mount NAS bundle dir into LXC (if NAS available)
#   4. Install /usr/local/bin/forgejo-mirror-health + daily cron
#   5. Install /usr/local/bin/forgejo-bundle-snapshot + weekly cron (if NAS)
#
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
#   --org NAME          GitHub org/user (default: SREbuilt)
#   --forgejo-org NAME  Forgejo org (default: github-mirror)
#   --forgejo-url URL   Forgejo URL (default: https://192.168.178.84)
#   --ct-id N           Forgejo LXC ID (default: 104)
#   --nas-bundle-dir P  PVE host path for NAS bundles (default: /mnt/nas-praxis/backups/git-bundles)
#   --skip-monitoring   Skip monitoring/bundle install (just mirror)
###############################################################################

set -euo pipefail

GITHUB_ORG="SREbuilt"
FORGEJO_URL="https://192.168.178.84"
FORGEJO_ORG="github-mirror"
INCLUDE_PUBLIC=0
CT_ID=104
NAS_BUNDLE_DIR="/mnt/nas-praxis/backups/git-bundles"
SKIP_MONITORING=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --include-public) INCLUDE_PUBLIC=1; shift ;;
        --org) GITHUB_ORG="$2"; shift 2 ;;
        --forgejo-org) FORGEJO_ORG="$2"; shift 2 ;;
        --forgejo-url) FORGEJO_URL="$2"; shift 2 ;;
        --ct-id) CT_ID="$2"; shift 2 ;;
        --nas-bundle-dir) NAS_BUNDLE_DIR="$2"; shift 2 ;;
        --skip-monitoring) SKIP_MONITORING=1; shift ;;
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
echo -e "${BLUE}  Mirror Summary${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
echo "  Total:    $TOTAL"

if [[ $SKIP_MONITORING -eq 1 ]]; then
    echo -e "${YELLOW}--skip-monitoring: not installing helper scripts/crons${NC}"
    exit 0
fi

###############################################################################
# Phase 2: Install monitoring + bundle backup (idempotent)
###############################################################################

echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Installing monitoring + backup${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"

# Persist Forgejo token (used by mirror-health cron)
if [[ ! -f /root/.forgejo-token ]]; then
    printf '%s' "${FORGEJO_TOKEN}" > /root/.forgejo-token
    chmod 600 /root/.forgejo-token
    echo -e "${GREEN}✓${NC} Saved Forgejo token → /root/.forgejo-token (chmod 600)"
else
    echo -e "${GREEN}✓${NC} /root/.forgejo-token already exists"
fi

# Install forgejo-mirror-health script
cat > /usr/local/bin/forgejo-mirror-health << HEALTH_EOF
#!/bin/bash
# Alert if any Forgejo mirror has not synced in > 2 hours
set -euo pipefail
FORGEJO_URL="${FORGEJO_URL}"
FORGEJO_ORG="${FORGEJO_ORG}"
FORGEJO_TOKEN_FILE="/root/.forgejo-token"

[[ ! -f "\$FORGEJO_TOKEN_FILE" ]] && { echo "FATAL: \$FORGEJO_TOKEN_FILE missing"; exit 1; }
TOKEN=\$(cat "\$FORGEJO_TOKEN_FILE")
THRESHOLD=\$(date -u -d "2 hours ago" +%FT%TZ)

STALE=\$(curl -ks -H "Authorization: token \$TOKEN" \\
    "\${FORGEJO_URL}/api/v1/orgs/\${FORGEJO_ORG}/repos?limit=100" \\
    | jq -r --arg t "\$THRESHOLD" \\
        '.[] | select(.mirror_updated < \$t) | "\(.name) last=\(.mirror_updated)"')

if [[ -n "\$STALE" ]]; then
    echo "[\$(date)] FORGEJO MIRROR STALE (>2h):"
    echo "\$STALE"
    exit 1
fi
echo "[\$(date)] All mirrors fresh"
HEALTH_EOF
chmod +x /usr/local/bin/forgejo-mirror-health
echo -e "${GREEN}✓${NC} Installed /usr/local/bin/forgejo-mirror-health"

# Install mirror-health cron (with explicit PATH for /usr/sbin etc.)
cat > /etc/cron.d/forgejo-mirror-health << 'HEALTH_CRON'
# Daily health check of Forgejo GitHub mirrors
PATH=/usr/sbin:/usr/bin:/sbin:/bin
0 6 * * * root /usr/local/bin/forgejo-mirror-health >> /var/log/forgejo-mirror-health.log 2>&1
HEALTH_CRON
chmod 644 /etc/cron.d/forgejo-mirror-health
echo -e "${GREEN}✓${NC} Installed cron /etc/cron.d/forgejo-mirror-health (daily 06:00)"

# Bundle snapshot setup (requires NAS mount)
if [[ -d "$NAS_BUNDLE_DIR" ]] || mountpoint -q "$(dirname "$NAS_BUNDLE_DIR")" 2>/dev/null; then
    mkdir -p "$NAS_BUNDLE_DIR"

    # Bind-mount NAS dir into LXC (idempotent: pct set is fine if already configured)
    if ! pct config "$CT_ID" 2>/dev/null | grep -q "mp=/nas-bundles"; then
        pct set "$CT_ID" -mp1 "${NAS_BUNDLE_DIR},mp=/nas-bundles"
        echo -e "${GREEN}✓${NC} Bind-mounted ${NAS_BUNDLE_DIR} → /nas-bundles in LXC ${CT_ID}"
    else
        echo -e "${GREEN}✓${NC} LXC ${CT_ID} already has /nas-bundles bind-mount"
    fi

    # Install bundle script (uses /usr/sbin/pct absolute path — cron PATH safe)
    cat > /usr/local/bin/forgejo-bundle-snapshot << BUNDLE_EOF
#!/bin/bash
# Weekly Git bundle snapshot to NAS — true backup (immune to ref deletion)
# Runs inside LXC ${CT_ID} via pct exec, output to /nas-bundles (NAS bind-mount)
set -euo pipefail

DATE=\$(date +%Y-%m-%d)
RETENTION_WEEKS=12
NAS_HOST_DIR="${NAS_BUNDLE_DIR}"

# Verify NAS dir exists and is writable (don't check exact mountpoint — too brittle)
if [[ ! -d "\$NAS_HOST_DIR" ]] || ! touch "\$NAS_HOST_DIR/.write-test" 2>/dev/null; then
    echo "[\$(date)] FATAL: NAS dir \$NAS_HOST_DIR not writable (NAS unmounted?)"
    exit 1
fi
rm -f "\$NAS_HOST_DIR/.write-test"

# Run the bundling inside the LXC (single pct exec, all logic in one go)
/usr/sbin/pct exec ${CT_ID} -- bash -c "
set -euo pipefail
DATE=\\"\$DATE\\"
REPO_DIR=/var/lib/docker/volumes/forgejo_forgejo-data/_data/git/repositories/${FORGEJO_ORG}
SNAPSHOT_DIR=/nas-bundles/\\\$DATE
mkdir -p \\"\\\$SNAPSHOT_DIR\\"
COUNT=0
for repo in \\"\\\$REPO_DIR\\"/*.git; do
    [[ -d \\"\\\$repo\\" ]] || continue
    name=\\\$(basename \\"\\\$repo\\" .git)
    # safe.directory=* needed: Forgejo files are owned by UID 1000 but cron runs as root inside LXC
    if git -c safe.directory=\\"*\\" -C \\"\\\$repo\\" bundle create \\"\\\$SNAPSHOT_DIR/\\\$name.bundle\\" --all --quiet 2>&1; then
        COUNT=\\\$((COUNT + 1))
    fi
done
SIZE=\\\$(du -sh \\"\\\$SNAPSHOT_DIR\\" | cut -f1)
echo \\"Bundled \\\$COUNT repos (\\\$SIZE) -> \\\$SNAPSHOT_DIR\\"
"

# Retention: drop snapshots older than N weeks (run on PVE host, NAS path)
find "\$NAS_HOST_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +\$((RETENTION_WEEKS * 7)) -exec rm -rf {} \\; 2>/dev/null || true

echo "[\$(date)] Bundle snapshot complete"
BUNDLE_EOF
    chmod +x /usr/local/bin/forgejo-bundle-snapshot
    echo -e "${GREEN}✓${NC} Installed /usr/local/bin/forgejo-bundle-snapshot"

    cat > /etc/cron.d/forgejo-bundle-snapshot << 'BUNDLE_CRON'
# Weekly Forgejo Git bundle snapshot — true backup to NAS
PATH=/usr/sbin:/usr/bin:/sbin:/bin
0 4 * * 1 root /usr/local/bin/forgejo-bundle-snapshot >> /var/log/forgejo-bundle-snapshot.log 2>&1
BUNDLE_CRON
    chmod 644 /etc/cron.d/forgejo-bundle-snapshot
    echo -e "${GREEN}✓${NC} Installed cron /etc/cron.d/forgejo-bundle-snapshot (weekly Mon 04:00)"
else
    echo -e "${YELLOW}⚠${NC}  NAS dir ${NAS_BUNDLE_DIR} not available — skipping bundle backup"
    echo "   Mount your NAS at /mnt/nas-praxis first, then re-run this script."
fi

# Run health check once to verify and seed log file
echo ""
echo -e "${BLUE}=== Initial health check ===${NC}"
/usr/local/bin/forgejo-mirror-health

echo ""
if [[ $FAILED -eq 0 ]]; then
    echo -e "${GREEN}✓ Done — mirrors + monitoring set up${NC}"
    echo ""
    echo "Cron schedule:"
    echo "  • Mirror health check  → daily 06:00"
    [[ -f /etc/cron.d/forgejo-bundle-snapshot ]] && \
        echo "  • Git bundle snapshot  → weekly Mon 04:00"
    echo "  (Forgejo's own backup runs inside the LXC daily at 03:00)"
else
    echo -e "${RED}✗ Some mirrors failed — check /tmp/migrate-*.json${NC}"
    exit 1
fi
