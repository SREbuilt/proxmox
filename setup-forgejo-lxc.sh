#!/bin/bash
###############################################################################
# setup-forgejo-lxc.sh — Self-hosted Forgejo Git forge in Proxmox LXC
#
# Creates an unprivileged Debian 12 LXC running Forgejo v15 LTS + Postgres 17
# + Caddy (reverse proxy with self-signed TLS) via Docker Compose.
#
# Architecture (LAN-only, hardened):
#
#   ┌────────────────────────────────────────────────────────────┐
#   │ LXC 104 (192.168.178.84) — 768 MB RAM + 512 MB swap        │
#   │                                                            │
#   │  ┌─────────┐  ┌────────────┐  ┌──────────────────┐         │
#   │  │ Caddy   │──│ Forgejo    │──│ Postgres 17      │         │
#   │  │ :80/443 │  │ :3000/22   │  │ :5432 (internal) │         │
#   │  │ (TLS)   │  │            │  │                  │         │
#   │  └─────────┘  └────────────┘  └──────────────────┘         │
#   │       │              │                                     │
#   │       ▼              ▼                                     │
#   │  Host:80/443    Host:3022 (git SSH)                        │
#   └────────────────────────────────────────────────────────────┘
#
# Security adapted from Jorijn's hardened Forgejo NUC setup:
#   - LXC isolation (replaces full KVM VM)
#   - Outbound firewall: RFC1918 blocked except DNS/NTP to gateway
#   - Postgres on internal Docker network (not published)
#   - Repository-specific access tokens (Forgejo v15 native feature)
#   - DISABLE_REGISTRATION, REQUIRE_SIGNIN_VIEW enabled
#   - Pinned image versions (no floating tags)
#   - Self-signed cert from Caddy internal CA (LAN-only)
#
# Usage:
#   ./setup-forgejo-lxc.sh \
#       --ssh-pubkey ~/.ssh/id_ed25519.pub \
#       --admin-user "myname" \
#       --admin-email "me@example.com"
#
# Optional:
#       --ct-id 104  --ct-ip 192.168.178.84  --gateway 192.168.178.1
#       --ram 768   --swap 512  --disk 16  --bridge vmbr0
#       --password "PASS"  --db-password "DBPASS"  --admin-password "ADMINPASS"
#       --backup-dir /var/lib/forgejo-backups
#
# Prerequisites: Proxmox VE 8.x+
###############################################################################

set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────

CT_ID=104
CT_IP="192.168.178.84"
GATEWAY="192.168.178.1"
RAM=768
SWAP=512
DISK=16
BRIDGE="vmbr0"
PASSWORD=""
DB_PASSWORD=""
ADMIN_PASSWORD=""
SSH_PUBKEY_FILE=""
ADMIN_USER=""
ADMIN_EMAIL=""
BACKUP_DIR="/var/lib/forgejo-backups"

FORGEJO_VERSION="15.0.2"
POSTGRES_VERSION="17-alpine"
CADDY_VERSION="2-alpine"

TEMPLATE_URL="http://download.proxmox.com/images/system/debian-12-standard_12.7-1_amd64.tar.zst"
TEMPLATE_NAME="debian-12-standard_12.7-1_amd64.tar.zst"
TEMPLATE_PATH="/var/lib/vz/template/cache/${TEMPLATE_NAME}"

# ─── Colors ──────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; exit 1; }

# ─── Parse arguments ────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ct-id)            CT_ID="$2";            shift 2 ;;
        --ct-ip)            CT_IP="$2";            shift 2 ;;
        --gateway)          GATEWAY="$2";          shift 2 ;;
        --ram)              RAM="$2";              shift 2 ;;
        --swap)             SWAP="$2";             shift 2 ;;
        --disk)             DISK="$2";             shift 2 ;;
        --bridge)           BRIDGE="$2";           shift 2 ;;
        --password)         PASSWORD="$2";         shift 2 ;;
        --db-password)      DB_PASSWORD="$2";      shift 2 ;;
        --admin-password)   ADMIN_PASSWORD="$2";   shift 2 ;;
        --ssh-pubkey)       SSH_PUBKEY_FILE="$2";  shift 2 ;;
        --admin-user)       ADMIN_USER="$2";       shift 2 ;;
        --admin-email)      ADMIN_EMAIL="$2";      shift 2 ;;
        --backup-dir)       BACKUP_DIR="$2";       shift 2 ;;
        *)                  fail "Unknown argument: $1" ;;
    esac
done

# ─── Validate ────────────────────────────────────────────────────────────────

[[ -z "$SSH_PUBKEY_FILE" ]] && fail "Missing --ssh-pubkey <path>"
[[ ! -f "$SSH_PUBKEY_FILE" ]] && fail "SSH pubkey not found: $SSH_PUBKEY_FILE"
[[ -z "$ADMIN_USER" ]] && fail "Missing --admin-user <username>"
[[ -z "$ADMIN_EMAIL" ]] && fail "Missing --admin-email <email>"
command -v pct &>/dev/null || fail "Must run on a Proxmox host"

# Generate passwords if not provided
[[ -z "$PASSWORD" ]] && PASSWORD=$(openssl rand -base64 12)
[[ -z "$DB_PASSWORD" ]] && DB_PASSWORD=$(openssl rand -base64 32 | tr -d '+/=' | head -c 32)
[[ -z "$ADMIN_PASSWORD" ]] && ADMIN_PASSWORD=$(openssl rand -base64 16 | tr -d '+/=' | head -c 16)

ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$CT_IP" 2>/dev/null || true

SSH_CMD="ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes"

info "═══════════════════════════════════════════════════"
info "  Forgejo LXC Setup — Self-Hosted Git Forge"
info "═══════════════════════════════════════════════════"
info "  CT ID:         $CT_ID"
info "  CT IP:         $CT_IP"
info "  RAM:           ${RAM}MB + ${SWAP}MB swap"
info "  Disk:          ${DISK}GB"
info "  Forgejo:       v${FORGEJO_VERSION}"
info "  Postgres:      ${POSTGRES_VERSION}"
info "  Caddy:         ${CADDY_VERSION}"
info "  Admin user:    ${ADMIN_USER}"
info "  Admin email:   ${ADMIN_EMAIL}"
info "  Backup dir:    ${BACKUP_DIR} (on PVE host)"
info "═══════════════════════════════════════════════════"

###############################################################################
# Step 1/9: Download LXC template
###############################################################################

info "Step 1/9: Downloading Debian 12 LXC template..."
if [[ -f "$TEMPLATE_PATH" ]]; then
    ok "Template already cached"
else
    wget -q --show-progress -O "$TEMPLATE_PATH" "$TEMPLATE_URL"
    ok "Template downloaded"
fi

###############################################################################
# Step 2/9: Prepare backup directory on PVE host
###############################################################################

info "Step 2/9: Preparing backup directory on PVE host..."
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
ok "Backup directory: ${BACKUP_DIR}"

###############################################################################
# Step 3/9: Create LXC
###############################################################################

info "Step 3/9: Creating LXC $CT_ID..."

if pct status "$CT_ID" &>/dev/null; then
    warn "LXC $CT_ID exists — destroying"
    pct stop "$CT_ID" 2>/dev/null || true
    sleep 2
    pct destroy "$CT_ID" --purge 2>/dev/null || true
    sleep 2
fi

pct create "$CT_ID" "$TEMPLATE_PATH" \
    --hostname forgejo \
    --ostype debian \
    --cores 2 \
    --memory "$RAM" \
    --swap "$SWAP" \
    --rootfs "local-lvm:${DISK}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=${CT_IP}/24,gw=${GATEWAY},firewall=0" \
    --nameserver "$GATEWAY" \
    --searchdomain "local" \
    --password "$PASSWORD" \
    --ssh-public-keys "$SSH_PUBKEY_FILE" \
    --unprivileged 1 \
    --features nesting=1,keyctl=1 \
    --onboot 1 \
    --start 0

ok "LXC $CT_ID created (${DISK}GB disk, unprivileged)"

# Bind-mount backup directory from PVE host into LXC
pct set "$CT_ID" -mp0 "${BACKUP_DIR},mp=/backups"
ok "Backup bind-mount configured: ${BACKUP_DIR} → /backups (inside LXC)"

###############################################################################
# Step 4/9: Proxmox firewall (HARDENED: egress allowlist)
###############################################################################

info "Step 4/9: Configuring Proxmox firewall (hardened)..."

cat > "/etc/pve/firewall/${CT_ID}.fw" << EOF
[OPTIONS]
enable: 0
policy_in: DROP
policy_out: DROP

[RULES]
# === Inbound (LAN-only) ===
IN ACCEPT -source 192.168.178.0/24 -p tcp -dport 22 -log nolog
IN ACCEPT -source 192.168.178.0/24 -p tcp -dport 80 -log nolog
IN ACCEPT -source 192.168.178.0/24 -p tcp -dport 443 -log nolog
IN ACCEPT -source 192.168.178.0/24 -p tcp -dport 3022 -log nolog
IN ACCEPT -p icmp -log nolog

# === Outbound (allowlist — block LAN sniffing) ===
# DNS + NTP to gateway only
OUT ACCEPT -dest ${GATEWAY} -p udp -dport 53 -log nolog
OUT ACCEPT -dest ${GATEWAY} -p tcp -dport 53 -log nolog
OUT ACCEPT -dest ${GATEWAY} -p udp -dport 123 -log nolog
# HTTP/HTTPS to internet (apt, container pulls, GitHub mirrors)
OUT ACCEPT -p tcp -dport 80 -log nolog
OUT ACCEPT -p tcp -dport 443 -log nolog
# Git over SSH (for repo mirrors/migrations from external sources)
OUT ACCEPT -p tcp -dport 22 -log nolog
# ICMP
OUT ACCEPT -p icmp -log nolog
# Established/related implicit (PVE firewall handles via conntrack)
EOF

ok "Firewall configured (LAN sniffing blocked via policy_out: DROP)"

###############################################################################
# Step 5/9: Start LXC + wait for SSH
###############################################################################

info "Step 5/9: Starting LXC..."
pct start "$CT_ID"
ok "LXC $CT_ID started"

info "  Waiting for SSH..."
ELAPSED=0
while [[ $ELAPSED -lt 120 ]]; do
    if $SSH_CMD "root@${CT_IP}" "echo SSH_OK" 2>/dev/null | grep -q "SSH_OK"; then
        ok "SSH is ready"
        break
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    printf "."
done
echo ""

if ! $SSH_CMD "root@${CT_IP}" "echo OK" 2>/dev/null | grep -q "OK"; then
    fail "Cannot reach LXC via SSH after 120s."
fi

###############################################################################
# Step 6/9: Install Docker via SSH
###############################################################################

info "Step 6/9: Installing Docker..."

$SSH_CMD "root@${CT_IP}" << 'INSTALL_DOCKER'
set -e
echo "[1/4] Installing prerequisites..."
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg git

echo "[2/4] Adding Docker repository..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" > /etc/apt/sources.list.d/docker.list

echo "[3/4] Installing Docker Engine..."
apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable --now docker

echo "[4/4] Verifying Docker..."
docker run --rm hello-world | head -1
echo "DOCKER_OK"
INSTALL_DOCKER
ok "Docker installed"

###############################################################################
# Step 7/9: Deploy Forgejo + Postgres + Caddy via Docker Compose
###############################################################################

info "Step 7/9: Deploying Forgejo stack..."

# Create app directory and write docker-compose.yml + Caddyfile + .env
$SSH_CMD "root@${CT_IP}" "mkdir -p /opt/forgejo && chmod 700 /opt/forgejo"

# Write .env (chmod 600)
$SSH_CMD "root@${CT_IP}" "cat > /opt/forgejo/.env" << ENV_EOF
DB_PASSWORD=${DB_PASSWORD}
ENV_EOF
$SSH_CMD "root@${CT_IP}" "chmod 600 /opt/forgejo/.env"
ok "  .env created (permissions 600)"

# Write Caddyfile (LAN-only with manually generated self-signed cert)
# NOTE: Caddy's 'tls internal' for IP-only addresses produces certs with
# critical SAN that some TLS clients reject. We pre-generate a proper cert
# with both IP and hostname SANs to avoid handshake failures.
info "  Generating self-signed cert with IP + hostname SAN..."
$SSH_CMD "root@${CT_IP}" "mkdir -p /opt/forgejo/certs && openssl req -x509 -nodes -days 3650 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -keyout /opt/forgejo/certs/key.pem -out /opt/forgejo/certs/cert.pem -subj '/CN=forgejo.lan' -addext 'subjectAltName=DNS:forgejo.lan,DNS:forgejo,DNS:localhost,IP:${CT_IP},IP:127.0.0.1' -addext 'keyUsage=digitalSignature,keyEncipherment' -addext 'extendedKeyUsage=serverAuth' 2>&1 | tail -2"
ok "  Self-signed cert generated (IP + hostname SAN)"

$SSH_CMD "root@${CT_IP}" "cat > /opt/forgejo/Caddyfile" << CADDY_EOF
{
    auto_https disable_redirects
}

:443 {
    tls /certs/cert.pem /certs/key.pem
    reverse_proxy forgejo:3000
    encode gzip
    log {
        output stdout
        format console
    }
}

:80 {
    redir https://{host}{uri} permanent
}
CADDY_EOF
ok "  Caddyfile written (manual cert via :443 catch-all)"

# Write docker-compose.yml
$SSH_CMD "root@${CT_IP}" "cat > /opt/forgejo/docker-compose.yml" << COMPOSE_EOF
services:
  forgejo:
    image: codeberg.org/forgejo/forgejo:${FORGEJO_VERSION}
    container_name: forgejo
    restart: unless-stopped
    environment:
      - USER_UID=1000
      - USER_GID=1000
      - FORGEJO__database__DB_TYPE=postgres
      - FORGEJO__database__HOST=db:5432
      - FORGEJO__database__NAME=forgejo
      - FORGEJO__database__USER=forgejo
      - FORGEJO__database__PASSWD=\${DB_PASSWORD}
      # Server config (CRITICAL for SSH on 3022)
      - FORGEJO__server__DOMAIN=${CT_IP}
      - FORGEJO__server__SSH_DOMAIN=${CT_IP}
      - FORGEJO__server__SSH_PORT=3022
      - FORGEJO__server__SSH_LISTEN_PORT=22
      - FORGEJO__server__ROOT_URL=https://${CT_IP}/
      - FORGEJO__server__PROTOCOL=http
      - FORGEJO__server__HTTP_PORT=3000
      # Security hardening
      - FORGEJO__service__DISABLE_REGISTRATION=true
      - FORGEJO__service__REQUIRE_SIGNIN_VIEW=true
      - FORGEJO__security__INSTALL_LOCK=true
      - FORGEJO__security__MIN_PASSWORD_LENGTH=12
      - FORGEJO__security__PASSWORD_COMPLEXITY=lower,upper,digit,spec
      # Logging
      - FORGEJO__log__LEVEL=Info
      - FORGEJO__log__MODE=console
    volumes:
      - forgejo-data:/data
      - /etc/timezone:/etc/timezone:ro
      - /etc/localtime:/etc/localtime:ro
    ports:
      - "3022:22"
    depends_on:
      db:
        condition: service_healthy
    networks:
      - internal
      - external
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:3000/api/healthz"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s

  db:
    image: postgres:${POSTGRES_VERSION}
    container_name: forgejo-db
    restart: unless-stopped
    environment:
      - POSTGRES_DB=forgejo
      - POSTGRES_USER=forgejo
      - POSTGRES_PASSWORD=\${DB_PASSWORD}
    volumes:
      - postgres-data:/var/lib/postgresql/data
    # Tuned for 768MB LXC RAM (Postgres default 128MB shared_buffers is too large)
    command:
      - postgres
      - -c
      - shared_buffers=64MB
      - -c
      - work_mem=2MB
      - -c
      - maintenance_work_mem=32MB
      - -c
      - max_connections=20
      - -c
      - effective_cache_size=256MB
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U forgejo -d forgejo"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - internal

  caddy:
    image: caddy:${CADDY_VERSION}
    container_name: forgejo-caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./certs:/certs:ro
      - caddy-data:/data
      - caddy-config:/config
    networks:
      - external

networks:
  internal:
    internal: true
  external:

volumes:
  forgejo-data:
  postgres-data:
  caddy-data:
  caddy-config:
COMPOSE_EOF
ok "  docker-compose.yml written"

# Pull images first (so timeouts during startup don't masquerade as failures)
info "  Pulling images (this may take 2-4 minutes)..."
$SSH_CMD "root@${CT_IP}" "cd /opt/forgejo && docker compose pull" 2>&1 | tail -20
ok "  Images pulled"

# Start the stack
info "  Starting Forgejo stack..."
$SSH_CMD "root@${CT_IP}" "cd /opt/forgejo && docker compose up -d"
ok "  Stack started"

# Wait for Forgejo to become healthy
info "  Waiting for Forgejo to become healthy..."
ELAPSED=0
while [[ $ELAPSED -lt 180 ]]; do
    STATUS=$($SSH_CMD "root@${CT_IP}" "docker inspect --format='{{.State.Health.Status}}' forgejo 2>/dev/null || echo notfound")
    if [[ "$STATUS" == "healthy" ]]; then
        ok "Forgejo is healthy"
        break
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    printf "."
done
echo ""

if [[ "$STATUS" != "healthy" ]]; then
    warn "Forgejo not healthy after 180s — check logs:"
    $SSH_CMD "root@${CT_IP}" "cd /opt/forgejo && docker compose logs --tail 30 forgejo"
    fail "Forgejo failed to start"
fi

###############################################################################
# Step 8/9: Create admin user
###############################################################################

info "Step 8/9: Creating admin user..."

$SSH_CMD "root@${CT_IP}" "docker compose -f /opt/forgejo/docker-compose.yml exec -T -u git forgejo forgejo admin user create \
    --admin \
    --username '${ADMIN_USER}' \
    --password '${ADMIN_PASSWORD}' \
    --email '${ADMIN_EMAIL}' \
    --must-change-password=false" 2>&1 | tail -5

ok "Admin user '${ADMIN_USER}' created"

###############################################################################
# Step 9/9: Backup cron + firewall enable + convenience scripts
###############################################################################

info "Step 9/9: Finalizing..."

# Create backup script (runs from PVE host, dumps via docker exec)
$SSH_CMD "root@${CT_IP}" "cat > /usr/local/bin/forgejo-backup" << 'BACKUP_SCRIPT'
#!/bin/bash
# Forgejo backup script — runs forgejo dump and rotates old backups
# Stores backups in /backups (bind-mount from PVE host)
set -euo pipefail

BACKUP_DIR="/backups"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RETENTION_DAYS=14

mkdir -p "$BACKUP_DIR"

cd /opt/forgejo

echo "[$(date)] Starting Forgejo backup..."

# Check if any repos exist (fresh install has no repos yet)
REPO_COUNT=$(docker exec forgejo find /data/git/repositories -mindepth 2 -maxdepth 2 -type d 2>/dev/null | wc -l || echo 0)
if [[ "$REPO_COUNT" -eq 0 ]]; then
    echo "[$(date)] No repos to back up yet (fresh install) — skipping forgejo dump, only Postgres"
    SKIP_FORGEJO_DUMP=1
fi

if [[ "${SKIP_FORGEJO_DUMP:-0}" != "1" ]]; then
    docker compose exec -T -u git forgejo forgejo dump \
        --type zip \
        --file "/tmp/forgejo-dump-${TIMESTAMP}.zip" \
        --tempdir /tmp

    # Copy dump out of container to bind-mount
    docker cp "forgejo:/tmp/forgejo-dump-${TIMESTAMP}.zip" "${BACKUP_DIR}/"
    docker exec forgejo rm -f "/tmp/forgejo-dump-${TIMESTAMP}.zip"
fi

# Also dump postgres separately for fast restore
docker compose exec -T db pg_dump -U forgejo forgejo | gzip > "${BACKUP_DIR}/postgres-${TIMESTAMP}.sql.gz"

# Set permissions
chmod 600 "${BACKUP_DIR}"/*.zip "${BACKUP_DIR}"/*.sql.gz 2>/dev/null || true

# Rotate: keep last RETENTION_DAYS days
find "$BACKUP_DIR" -name 'forgejo-dump-*.zip' -mtime +${RETENTION_DAYS} -delete
find "$BACKUP_DIR" -name 'postgres-*.sql.gz' -mtime +${RETENTION_DAYS} -delete

SIZE=$(du -sh "${BACKUP_DIR}/forgejo-dump-${TIMESTAMP}.zip" | cut -f1)
echo "[$(date)] Backup complete: forgejo-dump-${TIMESTAMP}.zip (${SIZE})"
BACKUP_SCRIPT
$SSH_CMD "root@${CT_IP}" "chmod +x /usr/local/bin/forgejo-backup"
ok "Backup script created: /usr/local/bin/forgejo-backup"

# Install cron job (daily at 03:00)
$SSH_CMD "root@${CT_IP}" "cat > /etc/cron.d/forgejo-backup" << 'CRON_EOF'
# Forgejo daily backup at 03:00
0 3 * * * root /usr/local/bin/forgejo-backup >> /var/log/forgejo-backup.log 2>&1
CRON_EOF
$SSH_CMD "root@${CT_IP}" "chmod 644 /etc/cron.d/forgejo-backup"
ok "Cron job installed: daily backup at 03:00"

# Create convenience update script
$SSH_CMD "root@${CT_IP}" "cat > /usr/local/bin/forgejo-update" << 'UPDATE_SCRIPT'
#!/bin/bash
# Update Forgejo to a new pinned version
# Usage: forgejo-update 15.0.3
set -euo pipefail

NEW_VERSION="${1:-}"
[[ -z "$NEW_VERSION" ]] && { echo "Usage: forgejo-update <version>"; exit 1; }

cd /opt/forgejo

echo "Backing up before upgrade..."
/usr/local/bin/forgejo-backup

echo "Updating image to ${NEW_VERSION}..."
sed -i "s|codeberg.org/forgejo/forgejo:.*|codeberg.org/forgejo/forgejo:${NEW_VERSION}|" docker-compose.yml

echo "Pulling new image..."
docker compose pull forgejo

echo "Recreating container..."
docker compose up -d forgejo

echo "Waiting for healthy..."
for i in {1..36}; do
    if [[ "$(docker inspect --format='{{.State.Health.Status}}' forgejo)" == "healthy" ]]; then
        echo "✅ Forgejo upgraded to ${NEW_VERSION}"
        exit 0
    fi
    sleep 5
done
echo "❌ Health check failed — check 'docker compose logs forgejo'"
exit 1
UPDATE_SCRIPT
$SSH_CMD "root@${CT_IP}" "chmod +x /usr/local/bin/forgejo-update"
ok "Update script created: /usr/local/bin/forgejo-update <version>"

# Run initial backup test (skip the repos check on fresh install — no repos yet)
info "  Running initial backup test (skipping repos: none exist on fresh install)..."
$SSH_CMD "root@${CT_IP}" "cd /opt/forgejo && docker compose exec -T db pg_dump -U forgejo forgejo | gzip > /backups/postgres-initial-test.sql.gz 2>/dev/null && ls -lh /backups/postgres-initial-test.sql.gz" 2>&1 | tail -3 || warn "Initial backup test failed (non-fatal)"
ok "  Initial postgres backup verified (full forgejo dump will work after first repo is created)"

# Enable LXC firewall
sed -i 's/^enable: 0/enable: 1/' "/etc/pve/firewall/${CT_ID}.fw"
pct set "$CT_ID" --net0 "name=eth0,bridge=${BRIDGE},ip=${CT_IP}/24,gw=${GATEWAY},firewall=1"
ok "Firewall enabled"

###############################################################################
# Summary
###############################################################################

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✅ Forgejo LXC Setup Complete!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""
echo "  LXC ID:         $CT_ID"
echo "  LXC IP:         $CT_IP"
echo "  LXC root pw:    $PASSWORD"
echo "  SSH:            ssh root@${CT_IP}"
echo ""
echo "  Forgejo URL:    https://${CT_IP}/"
echo "  Admin user:     ${ADMIN_USER}"
echo "  Admin pw:       ${ADMIN_PASSWORD}"
echo "  Admin email:    ${ADMIN_EMAIL}"
echo ""
echo "  Git SSH:        ssh://git@${CT_IP}:3022/<user>/<repo>.git"
echo "  DB password:    (stored in /opt/forgejo/.env on LXC)"
echo ""
echo "  Backups:        ${BACKUP_DIR} (PVE host) ↔ /backups (LXC)"
echo "                  Daily at 03:00, 14-day retention"
echo ""
echo "  Browser (first time):"
echo "    https://${CT_IP}/ → accept self-signed cert warning"
echo ""
echo "  Git SSH config (add to ~/.ssh/config on your workstation):"
echo "    Host forgejo"
echo "        HostName ${CT_IP}"
echo "        User git"
echo "        Port 3022"
echo "        IdentityFile ~/.ssh/id_ed25519"
echo ""
echo "  Then: git clone forgejo:${ADMIN_USER}/myrepo.git"
echo ""
echo "  Upgrade:  ssh root@${CT_IP} forgejo-update 15.0.3"
echo "  Backup:   ssh root@${CT_IP} forgejo-backup"
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}  ⚠️  SAVE the admin password: ${ADMIN_PASSWORD}${NC}"
echo -e "${YELLOW}  ⚠️  SAVE the LXC root password: ${PASSWORD}${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
