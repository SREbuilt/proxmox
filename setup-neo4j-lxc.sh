#!/bin/bash
###############################################################################
# setup-neo4j-lxc.sh — Self-hosted Neo4j Graph Database in Proxmox LXC
#
# Creates LXC 107 with Docker + Neo4j 5.26-LTS (community) behind Caddy 2.
# Adapts the proven setup-forgejo-lxc.sh pattern with all 24 known lessons
# already baked in.
#
# Two-tier backup:
#   1) Local: /var/lib/neo4j-backups/ (PVE host) -> /backups in LXC, 7 retained
#   2) NAS:   \\brain\backups\proxmox\neo4j\ via CIFS, 30 retained
#
# Usage:
#   ./setup-neo4j-lxc.sh \
#       --ssh-pubkey ~/.ssh/id_ed25519.pub \
#       --smb-user pve-svc-neo4j-backup \
#       --smb-password 'YOUR_SMB_PW'
#
# Optional:
#   --ct-id 107  --ct-ip 192.168.178.87  --gateway 192.168.178.1
#   --ram 2048  --swap 512  --disk 16  --bridge vmbr0
#   --password "LXC_ROOT_PW"  --neo4j-password "NEO4J_ADMIN_PW"
#   --smb-server 192.168.178.74  --smb-share backups
#   --smb-subpath proxmox/neo4j
#
# Prerequisites:
#   1. NAS user 'pve-svc-neo4j-backup' created with R/W on 'backups' share
#   2. Run from Proxmox host (root)
###############################################################################

set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────

CT_ID=107
CT_IP="192.168.178.87"
GATEWAY="192.168.178.1"
RAM=2048
SWAP=512
DISK=16
BRIDGE="vmbr0"
PASSWORD=""
NEO4J_PASSWORD=""
SSH_PUBKEY_FILE=""

NEO4J_VERSION="5.26.26-community"
CADDY_VERSION="2-alpine"

LOCAL_BACKUP_DIR="/var/lib/neo4j-backups"

SMB_SERVER="192.168.178.74"
SMB_SHARE="backups"
SMB_SUBPATH="proxmox/neo4j"
SMB_USER=""
SMB_PASSWORD=""
NAS_MOUNT_POINT="/mnt/nas-proxmox-backups"
SMB_CREDS_FILE="/etc/credentials.d/smb-neo4j-backup"

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
        --neo4j-password)   NEO4J_PASSWORD="$2";   shift 2 ;;
        --ssh-pubkey)       SSH_PUBKEY_FILE="$2";  shift 2 ;;
        --smb-server)       SMB_SERVER="$2";       shift 2 ;;
        --smb-share)        SMB_SHARE="$2";        shift 2 ;;
        --smb-subpath)      SMB_SUBPATH="$2";      shift 2 ;;
        --smb-user)         SMB_USER="$2";         shift 2 ;;
        --smb-password)     SMB_PASSWORD="$2";     shift 2 ;;
        *)                  fail "Unknown argument: $1" ;;
    esac
done

# ─── Validate ────────────────────────────────────────────────────────────────

[[ -z "$SSH_PUBKEY_FILE" ]] && fail "Missing --ssh-pubkey <path>"
[[ ! -f "$SSH_PUBKEY_FILE" ]] && fail "SSH pubkey not found: $SSH_PUBKEY_FILE"
[[ -z "$SMB_USER" ]]     && fail "Missing --smb-user <name>"
[[ -z "$SMB_PASSWORD" ]] && fail "Missing --smb-password <pw>"
command -v pct &>/dev/null || fail "Must run on a Proxmox host"
command -v mount.cifs &>/dev/null || { info "Installing cifs-utils on host..."; apt-get update -qq && apt-get install -y -qq cifs-utils; }

# Generate passwords if not provided
[[ -z "$PASSWORD" ]] && PASSWORD=$(openssl rand -base64 12)
# Neo4j requires a strong password; mixed-class pattern
[[ -z "$NEO4J_PASSWORD" ]] && NEO4J_PASSWORD="Neo$(openssl rand -hex 6)4j!9"

ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$CT_IP" 2>/dev/null || true

SSH_CMD="ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes"

info "═══════════════════════════════════════════════════"
info "  Neo4j LXC Setup — Graph Database (LTS)"
info "═══════════════════════════════════════════════════"
info "  CT ID:           $CT_ID"
info "  CT IP:           $CT_IP"
info "  RAM:             ${RAM}MB + ${SWAP}MB swap"
info "  Disk:            ${DISK}GB"
info "  Neo4j:           ${NEO4J_VERSION}"
info "  Caddy:           ${CADDY_VERSION}"
info "  Local backups:   ${LOCAL_BACKUP_DIR}"
info "  NAS backups:     //${SMB_SERVER}/${SMB_SHARE}/${SMB_SUBPATH}"
info "═══════════════════════════════════════════════════"

###############################################################################
# Step 1/11: Download LXC template
###############################################################################

info "Step 1/11: Downloading Debian 12 LXC template..."
if [[ -f "$TEMPLATE_PATH" ]]; then
    ok "Template already cached"
else
    wget -q --show-progress -O "$TEMPLATE_PATH" "$TEMPLATE_URL"
    ok "Template downloaded"
fi

###############################################################################
# Step 2/11: Mount NAS via CIFS (with creds file, write test)
###############################################################################

info "Step 2/11: Mounting NAS backup share via CIFS..."

mkdir -p "$(dirname "$SMB_CREDS_FILE")"
cat > "$SMB_CREDS_FILE" << CREDS_EOF
username=${SMB_USER}
password=${SMB_PASSWORD}
CREDS_EOF
chmod 600 "$SMB_CREDS_FILE"
ok "  Credentials file written: ${SMB_CREDS_FILE} (chmod 600)"

mkdir -p "$NAS_MOUNT_POINT"

# CRITICAL: Use uid=100000 so the LXC's UID 0 (= host UID 100000 via UID mapping)
# can write to CIFS files. With uid=0 they appear as "nobody" inside the LXC.
if mountpoint -q "$NAS_MOUNT_POINT" 2>/dev/null; then
    ok "  NAS share already mounted at ${NAS_MOUNT_POINT}"
else
    mount -t cifs "//${SMB_SERVER}/${SMB_SHARE}" "$NAS_MOUNT_POINT" \
        -o "credentials=${SMB_CREDS_FILE},vers=3.1.1,rw,iocharset=utf8,uid=100000,gid=100000,file_mode=0660,dir_mode=0770" \
        || fail "CIFS mount failed — verify SMB credentials and NAS reachability"
    ok "  NAS mounted: //${SMB_SERVER}/${SMB_SHARE} → ${NAS_MOUNT_POINT}"
fi

# Create the proxmox/neo4j subfolder if missing
mkdir -p "${NAS_MOUNT_POINT}/${SMB_SUBPATH}" \
    || fail "Cannot create ${SMB_SUBPATH} on NAS — check share permissions for ${SMB_USER}"
ok "  Subfolder ready: ${NAS_MOUNT_POINT}/${SMB_SUBPATH}"

# Write test
WRITE_TEST_FILE="${NAS_MOUNT_POINT}/${SMB_SUBPATH}/.write-test-$$"
if touch "$WRITE_TEST_FILE" 2>/dev/null && rm -f "$WRITE_TEST_FILE"; then
    ok "  NAS write test passed"
else
    fail "Cannot write to ${NAS_MOUNT_POINT}/${SMB_SUBPATH} — fix NAS permissions"
fi

# Persist in /etc/fstab (idempotent)
FSTAB_LINE="//${SMB_SERVER}/${SMB_SHARE}  ${NAS_MOUNT_POINT}  cifs  credentials=${SMB_CREDS_FILE},vers=3.1.1,rw,iocharset=utf8,uid=100000,gid=100000,file_mode=0660,dir_mode=0770,_netdev  0  0"
if ! grep -qF "$NAS_MOUNT_POINT" /etc/fstab; then
    echo "$FSTAB_LINE" >> /etc/fstab
    ok "  Added NAS mount to /etc/fstab"
else
    ok "  NAS mount already in /etc/fstab"
fi

###############################################################################
# Step 3/11: Prepare local backup dir (with UID-mapping chown)
###############################################################################

info "Step 3/11: Preparing local backup directory..."
mkdir -p "$LOCAL_BACKUP_DIR"
chmod 700 "$LOCAL_BACKUP_DIR"
# UID 100000 on host = UID 0 inside unprivileged LXC
chown 100000:100000 "$LOCAL_BACKUP_DIR"
ok "Local backup directory: ${LOCAL_BACKUP_DIR} (owner 100000:100000 for unpriv LXC)"

# Also chown the NAS subfolder so the LXC root can write to it
# CIFS share permissions override this, but we need correct ownership
# at the kernel level for the bind-mount
chown 100000:100000 "${NAS_MOUNT_POINT}/${SMB_SUBPATH}" 2>/dev/null || true
ok "NAS subfolder ownership set (may be overridden by CIFS, that's OK)"

###############################################################################
# Step 4/11: Create LXC
###############################################################################

info "Step 4/11: Creating LXC $CT_ID..."

if pct status "$CT_ID" &>/dev/null; then
    warn "LXC $CT_ID exists — destroying"
    pct stop "$CT_ID" 2>/dev/null || true
    sleep 2
    pct destroy "$CT_ID" --purge 2>/dev/null || true
    sleep 2
fi

pct create "$CT_ID" "$TEMPLATE_PATH" \
    --hostname neo4j \
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

# Bind-mount both backup tiers
pct set "$CT_ID" -mp0 "${LOCAL_BACKUP_DIR},mp=/backups"
ok "Local backup bind-mount: ${LOCAL_BACKUP_DIR} → /backups"

pct set "$CT_ID" -mp1 "${NAS_MOUNT_POINT}/${SMB_SUBPATH},mp=/nas-backups"
ok "NAS backup bind-mount: ${NAS_MOUNT_POINT}/${SMB_SUBPATH} → /nas-backups"

###############################################################################
# Step 5/11: Proxmox firewall (HARDENED: egress allowlist)
###############################################################################

info "Step 5/11: Configuring Proxmox firewall (hardened)..."

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
IN ACCEPT -source 192.168.178.0/24 -p tcp -dport 7473 -log nolog
IN ACCEPT -source 192.168.178.0/24 -p tcp -dport 7687 -log nolog
IN ACCEPT -p icmp -log nolog

# === Outbound (allowlist — block LAN sniffing) ===
OUT ACCEPT -dest ${GATEWAY} -p udp -dport 53 -log nolog
OUT ACCEPT -dest ${GATEWAY} -p tcp -dport 53 -log nolog
OUT ACCEPT -dest ${GATEWAY} -p udp -dport 123 -log nolog
OUT ACCEPT -p tcp -dport 80 -log nolog
OUT ACCEPT -p tcp -dport 443 -log nolog
OUT ACCEPT -p icmp -log nolog
EOF

ok "Firewall configured (Bolt 7687 + Neo4j HTTPS 7473 + Caddy 80/443 + SSH from LAN)"

###############################################################################
# Step 6/11: Start LXC + wait for SSH
###############################################################################

info "Step 6/11: Starting LXC..."
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

$SSH_CMD "root@${CT_IP}" "echo OK" 2>/dev/null | grep -q "OK" \
    || fail "Cannot reach LXC via SSH after 120s."

###############################################################################
# Step 7/11: Install Docker
###############################################################################

info "Step 7/11: Installing Docker..."

$SSH_CMD "root@${CT_IP}" << 'INSTALL_DOCKER'
set -e
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" > /etc/apt/sources.list.d/docker.list
apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable --now docker
docker run --rm hello-world > /dev/null 2>&1 && echo DOCKER_OK
INSTALL_DOCKER
ok "Docker installed"

###############################################################################
# Step 8/11: Deploy Neo4j + Caddy via Docker Compose
###############################################################################

info "Step 8/11: Deploying Neo4j stack..."

$SSH_CMD "root@${CT_IP}" "mkdir -p /opt/neo4j && chmod 700 /opt/neo4j"

# Generate self-signed cert with proper SANs (avoids Caddy tls internal IP issue)
info "  Generating self-signed cert..."
$SSH_CMD "root@${CT_IP}" "mkdir -p /opt/neo4j/certs && openssl req -x509 -nodes -days 3650 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -keyout /opt/neo4j/certs/key.pem -out /opt/neo4j/certs/cert.pem -subj '/CN=neo4j.lan' -addext 'subjectAltName=DNS:neo4j.lan,DNS:neo4j,DNS:localhost,IP:${CT_IP},IP:127.0.0.1' -addext 'keyUsage=digitalSignature,keyEncipherment' -addext 'extendedKeyUsage=serverAuth' 2>&1 | tail -1"
ok "  Self-signed cert generated"

# Mirror the cert into Neo4j's required ssl/{bolt,https} subdirs
# Neo4j 5 expects private.key + public.crt in dedicated dirs per policy
info "  Setting up SSL directory structure for Neo4j Bolt+HTTPS..."
$SSH_CMD "root@${CT_IP}" "
    mkdir -p /opt/neo4j/ssl/bolt /opt/neo4j/ssl/https
    cp /opt/neo4j/certs/key.pem  /opt/neo4j/ssl/bolt/private.key
    cp /opt/neo4j/certs/cert.pem /opt/neo4j/ssl/bolt/public.crt
    cp /opt/neo4j/certs/key.pem  /opt/neo4j/ssl/https/private.key
    cp /opt/neo4j/certs/cert.pem /opt/neo4j/ssl/https/public.crt
    chmod 644 /opt/neo4j/ssl/bolt/private.key /opt/neo4j/ssl/https/private.key
"
ok "  SSL dirs ready (bolt/ + https/ with cert + key)"

# Caddyfile
$SSH_CMD "root@${CT_IP}" "cat > /opt/neo4j/Caddyfile" << 'CADDY_EOF'
{
    auto_https disable_redirects
}

:443 {
    tls /certs/cert.pem /certs/key.pem
    reverse_proxy neo4j:7474
    encode gzip
}

:80 {
    redir https://{host}{uri} permanent
}
CADDY_EOF
ok "  Caddyfile written"

# docker-compose.yml — Neo4j tuned for 2 GB LXC
$SSH_CMD "root@${CT_IP}" "cat > /opt/neo4j/docker-compose.yml" << COMPOSE_EOF
services:
  neo4j:
    image: neo4j:${NEO4J_VERSION}
    container_name: neo4j
    restart: unless-stopped
    environment:
      - NEO4J_AUTH=neo4j/${NEO4J_PASSWORD}
      - NEO4J_server_default__listen__address=0.0.0.0
      - NEO4J_server_default__advertised__address=${CT_IP}
      - NEO4J_server_bolt_advertised__address=${CT_IP}:7687
      - NEO4J_server_http_advertised__address=${CT_IP}:7474
      - NEO4J_server_https_advertised__address=${CT_IP}:7473
      # Memory tuning for 2 GB LXC
      - NEO4J_server_memory_heap_initial__size=512m
      - NEO4J_server_memory_heap_max__size=512m
      - NEO4J_server_memory_pagecache_size=512m
      - NEO4J_db_memory_transaction_total_max=256m
      # Bolt TLS — REQUIRED so the HTTPS Browser can connect via bolt+s://
      - NEO4J_server_bolt_tls__level=OPTIONAL
      - NEO4J_dbms_ssl_policy_bolt_enabled=true
      - NEO4J_dbms_ssl_policy_bolt_base__directory=/ssl/bolt
      - NEO4J_dbms_ssl_policy_bolt_private__key=private.key
      - NEO4J_dbms_ssl_policy_bolt_public__certificate=public.crt
      - NEO4J_dbms_ssl_policy_bolt_client__auth=NONE
      # HTTPS on Neo4j itself (7473) — recommended login URL
      - NEO4J_server_https_enabled=true
      - NEO4J_dbms_ssl_policy_https_enabled=true
      - NEO4J_dbms_ssl_policy_https_base__directory=/ssl/https
      - NEO4J_dbms_ssl_policy_https_private__key=private.key
      - NEO4J_dbms_ssl_policy_https_public__certificate=public.crt
      - NEO4J_dbms_ssl_policy_https_client__auth=NONE
      # Accept license for Community (Apache 2.0)
      - NEO4J_ACCEPT_LICENSE_AGREEMENT=yes
    ports:
      - "7687:7687"
      - "7473:7473"
    volumes:
      - neo4j-data:/data
      - neo4j-logs:/logs
      - neo4j-plugins:/plugins
      - neo4j-conf:/conf
      - neo4j-import:/import
      - ./ssl:/ssl:ro
      - /backups:/backups
      - /nas-backups:/nas-backups
    networks:
      - internal
      - external
    healthcheck:
      test: ["CMD-SHELL", "wget -q --spider http://localhost:7474/ || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 90s

  caddy:
    image: caddy:${CADDY_VERSION}
    container_name: neo4j-caddy
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
    depends_on:
      - neo4j

networks:
  internal:
    internal: true
  external:

volumes:
  neo4j-data:
  neo4j-logs:
  neo4j-plugins:
  neo4j-conf:
  neo4j-import:
  caddy-data:
  caddy-config:
COMPOSE_EOF
ok "  docker-compose.yml written"

info "  Pulling images (this may take 2-4 minutes)..."
$SSH_CMD "root@${CT_IP}" "cd /opt/neo4j && docker compose pull" 2>&1 | tail -8
ok "  Images pulled"

info "  Starting Neo4j stack..."
$SSH_CMD "root@${CT_IP}" "cd /opt/neo4j && docker compose up -d"
ok "  Stack started"

info "  Waiting for Neo4j to become healthy (may take 60-120s)..."
ELAPSED=0
STATUS="starting"
while [[ $ELAPSED -lt 240 ]]; do
    STATUS=$($SSH_CMD "root@${CT_IP}" "docker inspect --format='{{.State.Health.Status}}' neo4j 2>/dev/null || echo notfound")
    if [[ "$STATUS" == "healthy" ]]; then
        ok "Neo4j is healthy"
        break
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    printf "."
done
echo ""

if [[ "$STATUS" != "healthy" ]]; then
    warn "Neo4j not healthy after 240s — check logs:"
    $SSH_CMD "root@${CT_IP}" "cd /opt/neo4j && docker compose logs --tail 30 neo4j"
    fail "Neo4j failed to start"
fi

###############################################################################
# Step 9/11: Install 2-tier backup script + cron
###############################################################################

info "Step 9/11: Installing 2-tier backup..."

# Write the backup script via a temp file + pct push (more reliable than heredoc-over-ssh)
BACKUP_SCRIPT_TMP=$(mktemp)
cat > "$BACKUP_SCRIPT_TMP" << 'BACKUP_EOF'
#!/bin/bash
# Neo4j 2-tier backup (local + NAS) with rotation
# Tier 1: /backups (PVE bind-mount, keep 7)
# Tier 2: /nas-backups (NAS CIFS bind-mount, keep 30)
set -euo pipefail

LOCAL_DIR=/backups
NAS_DIR=/nas-backups
LOCAL_KEEP=7
NAS_KEEP=30
TS=$(date +%Y%m%d-%H%M%S)

cd /opt/neo4j

echo "[$(date)] Starting Neo4j backup ${TS}..."
echo "[$(date)] Stopping Neo4j for consistent dump..."
docker compose stop neo4j

echo "[$(date)] Running database dump..."
docker compose run --rm \
    -v neo4j_neo4j-data:/data \
    -v "${LOCAL_DIR}:/backups" \
    --entrypoint "" \
    neo4j \
    neo4j-admin database dump neo4j --to-path=/backups --overwrite-destination=true

LOCAL_DUMP=$(ls -1t ${LOCAL_DIR}/neo4j.dump 2>/dev/null | head -1)
if [[ -z "$LOCAL_DUMP" ]]; then
    echo "[$(date)] FATAL: no dump file produced"
    docker compose start neo4j
    exit 1
fi

NAMED_DUMP="${LOCAL_DIR}/neo4j-${TS}.dump"
mv "$LOCAL_DUMP" "$NAMED_DUMP"
echo "[$(date)] Local dump created: $(basename "$NAMED_DUMP") ($(du -h "$NAMED_DUMP" | cut -f1))"

echo "[$(date)] Restarting Neo4j..."
docker compose start neo4j

NAS_DUMP="${NAS_DIR}/neo4j-${TS}.dump"
if cp "$NAMED_DUMP" "$NAS_DUMP"; then
    echo "[$(date)] NAS dump copied: $(basename "$NAS_DUMP")"
else
    echo "[$(date)] WARNING: NAS copy failed (local backup still OK)"
fi

ls -1t ${LOCAL_DIR}/neo4j-*.dump 2>/dev/null | tail -n +$((LOCAL_KEEP + 1)) | xargs -r rm -f
ls -1t ${NAS_DIR}/neo4j-*.dump 2>/dev/null | tail -n +$((NAS_KEEP + 1)) | xargs -r rm -f

LOCAL_COUNT=$(ls -1 ${LOCAL_DIR}/neo4j-*.dump 2>/dev/null | wc -l)
NAS_COUNT=$(ls -1 ${NAS_DIR}/neo4j-*.dump 2>/dev/null | wc -l)
echo "[$(date)] Backup complete. Local: $LOCAL_COUNT/${LOCAL_KEEP}, NAS: $NAS_COUNT/${NAS_KEEP}"
BACKUP_EOF
pct push "$CT_ID" "$BACKUP_SCRIPT_TMP" /usr/local/bin/neo4j-backup
pct exec "$CT_ID" -- chmod +x /usr/local/bin/neo4j-backup
rm -f "$BACKUP_SCRIPT_TMP"
ok "Backup script installed"

# Cron file with PATH fix — written via temp file too (safer than ssh heredoc)
CRON_TMP=$(mktemp)
cat > "$CRON_TMP" << 'CRON_EOF'
# Neo4j 2-tier backup — local (7) + NAS (30)
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 3 * * * root /usr/local/bin/neo4j-backup >> /var/log/neo4j-backup.log 2>&1
CRON_EOF
pct push "$CT_ID" "$CRON_TMP" /etc/cron.d/neo4j-backup
pct exec "$CT_ID" -- chmod 644 /etc/cron.d/neo4j-backup
rm -f "$CRON_TMP"
ok "Backup cron installed (daily 03:00)"

###############################################################################
# Step 10/11: Enable firewall + verify initial backup
###############################################################################

info "Step 10/11: Running initial backup test..."
$SSH_CMD "root@${CT_IP}" "/usr/local/bin/neo4j-backup 2>&1 | tail -10"

# Verify both tiers
LOCAL_FILE=$($SSH_CMD "root@${CT_IP}" "ls -lh /backups/neo4j-*.dump 2>/dev/null | tail -1")
NAS_FILE=$($SSH_CMD "root@${CT_IP}" "ls -lh /nas-backups/neo4j-*.dump 2>/dev/null | tail -1")
[[ -n "$LOCAL_FILE" ]] && ok "Local backup verified: $LOCAL_FILE" || warn "Local backup file missing"
[[ -n "$NAS_FILE" ]]   && ok "NAS backup verified:   $NAS_FILE"   || warn "NAS backup file missing"

info "Step 11/11: Enabling firewall..."
sed -i 's/^enable: 0/enable: 1/' "/etc/pve/firewall/${CT_ID}.fw"
pct set "$CT_ID" --net0 "name=eth0,bridge=${BRIDGE},ip=${CT_IP}/24,gw=${GATEWAY},firewall=1"
ok "Firewall enabled"

###############################################################################
# Summary
###############################################################################

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✅ Neo4j LXC Setup Complete!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""
echo "  LXC ID:           $CT_ID"
echo "  LXC IP:           $CT_IP"
echo "  LXC root pw:      $PASSWORD"
echo "  SSH:              ssh root@${CT_IP}"
echo ""
echo "  Neo4j Browser:    https://${CT_IP}:7473/browser/   ← RECOMMENDED"
echo "                    (or: https://${CT_IP}/browser/  via Caddy)"
echo "  Neo4j user:       neo4j"
echo "  Neo4j password:   ${NEO4J_PASSWORD}"
echo ""
echo "  Connect URL:      neo4j+s://${CT_IP}:7687"
echo "                    (or bolt+ssc://${CT_IP}:7687 if cert is rejected)"
echo "  HTTP API:         https://${CT_IP}:7473/  (Neo4j native HTTPS)"
echo ""
echo "  Backups:          /var/lib/neo4j-backups/ (PVE)         — 7 retained"
echo "                    \\\\brain\\backups\\proxmox\\neo4j (NAS)  — 30 retained"
echo "                    Daily at 03:00"
echo ""
echo "  User manual:      USER-MANUAL-NEO4J.md (in repo)"
echo ""
echo "  Connect from another host (cypher-shell):"
echo "    cypher-shell -a bolt+ssc://${CT_IP}:7687 -u neo4j -p '${NEO4J_PASSWORD}'"
echo ""
echo "  Manual backup:    ssh root@${CT_IP} neo4j-backup"
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}  ⚠️  SAVE Neo4j password: ${NEO4J_PASSWORD}${NC}"
echo -e "${YELLOW}  ⚠️  SAVE LXC root pw:    ${PASSWORD}${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
