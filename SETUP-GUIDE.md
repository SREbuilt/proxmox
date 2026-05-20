# OpenClaw on Proxmox — Hardened Setup Guide
## For your Intel N150 / 16GB RAM / Home Assistant environment

> **Important note on Niklas Steenfatt**: Research shows that Niklas Steenfatt's
> YouTube channel (@NiklasSteenfatt) does **not** contain OpenClaw AI assistant
> content. His "OpenClaw" project is an unrelated **robotic arm** project. The
> security guidance in this guide comes from OpenClaw's **official documentation**
> (docs.openclaw.ai/gateway/security) and community best practices.

---

## Corrections to Previous Directions

Based on official OpenClaw documentation, these earlier decisions have been
**overruled**:

| Previous Direction | Official Recommendation | Why |
|-|-|-|
| Gateway bind: `lan` | Gateway bind: **`loopback`** | Official hardened baseline. LAN bind expands attack surface. |
| Node.js 22 | **Node.js 24** (recommended) | 22.14+ works but 24 is the official recommendation |
| No tool restrictions | **Deny all automation/runtime/fs tools** | Official hardened baseline denies dangerous tool groups |
| No security audit | Run **`openclaw security audit --fix`** | Official post-setup step; catches misconfigurations |
| Token in .desktop files | **Never embed tokens in files** | Leakage via screenshots/backups |

---

## Option 1: VM Setup (Strongest Isolation — Recommended)

**Best for**: Maximum security. Full hypervisor isolation means even a complete
compromise inside the VM cannot reach the Proxmox host or other VMs.

### Prerequisites
- Proxmox VE 8.x+ with root access
- SSH public key on the Proxmox host (`~/.ssh/id_ed25519.pub`)
- Your Z.AI API key

### Step-by-Step

#### 1. Generate an SSH key (if you don't have one yet)

On the Proxmox host, check whether a key already exists:

```bash
ls ~/.ssh/id_ed25519.pub
```

If the file does not exist, generate a new Ed25519 key pair:

```bash
ssh-keygen -t ed25519 -C "openclaw-vm" -N "" -f ~/.ssh/id_ed25519
```

- `-t ed25519` — modern, fast, secure key type
- `-N ""` — empty passphrase (required for unattended VM provisioning)
- The command creates `~/.ssh/id_ed25519` (private) and `~/.ssh/id_ed25519.pub` (public)

#### 2. Copy the script to your Proxmox host

```bash
# From your workstation, SCP the script to Proxmox:
scp niklas_setup-openclaw-vm.sh root@<PROXMOX_IP>:/root/
ssh root@<PROXMOX_IP>

# Install jq (not included in Proxmox by default, needed by the script):
apt update && apt install -y jq

chmod +x /root/niklas_setup-openclaw-vm.sh

# Fix Windows line endings (CRLF → LF), required if the file was
# created/edited on Windows:
sed -i 's/\r$//' /root/niklas_setup-openclaw-vm.sh
```

#### 3. Run the setup (fire and forget)

```bash
./niklas_setup-openclaw-vm.sh \
    --zai-api-key "your-zai-api-key-here" \
    --ssh-pubkey ~/.ssh/id_ed25519.pub
```

The script will:
- Download a Debian 12 cloud image (cached for reuse)
- Create a VM with 3GB RAM, 2 cores, 16GB disk
- Configure Proxmox firewall (blocks LAN, allows internet)
- Boot the VM with cloud-init (installs Docker + OpenClaw automatically)
- Wait for the VM to come online
- Inject your Z.AI API key via SSH (never stored in cloud-init)
- Apply hardened OpenClaw configuration
- Run `openclaw security audit --fix`
- Verify health

#### 4. Access OpenClaw (via SSH tunnel)

```bash
# From your workstation:
ssh -L 18789:localhost:18789 claw@<VM_IP>

# Then open in your browser:
# http://localhost:18789
# Enter the auth token printed at the end of setup
```

#### 5. Verify security

```bash
ssh claw@<VM_IP>
docker compose exec openclaw-gateway node openclaw.mjs security audit --deep
```

---

## Option 2: LXC Setup (Lighter Weight, Desktop Included)

**Best for**: Lower resource usage, includes a full remote desktop (noVNC) with
Chrome browser for the OpenClaw onboarding wizard and dashboard.

### Prerequisites
- Proxmox VE 8.x+ with root access
- Your Z.AI API key (optional — can configure later via desktop wizard)

### Step-by-Step

#### 1. Generate an SSH key (recommended for secure access)

While the LXC setup uses password authentication for the container, an SSH key
on the Proxmox host is recommended for secure management:

```bash
# Check if a key already exists:
ls ~/.ssh/id_ed25519.pub

# If not, generate one:
ssh-keygen -t ed25519 -C "proxmox-admin" -N "" -f ~/.ssh/id_ed25519
```

You can later copy it into the container for key-based SSH access:
```bash
pct exec <VMID> -- mkdir -p /root/.ssh
pct push <VMID> ~/.ssh/id_ed25519.pub /root/.ssh/authorized_keys
```

#### 2. Copy the script to your Proxmox host

```bash
scp niklas_setup-openclaw-lxc.sh root@<PROXMOX_IP>:/root/
ssh root@<PROXMOX_IP>

# Install jq (not included in Proxmox by default, needed by the script):
apt update && apt install -y jq

chmod +x /root/niklas_setup-openclaw-lxc.sh

# Fix Windows line endings (CRLF → LF), required if the file was
# created/edited on Windows:
sed -i 's/\r$//' /root/niklas_setup-openclaw-lxc.sh
```

#### 3. Run the setup

```bash
./niklas_setup-openclaw-lxc.sh \
    --password "your-container-password" \
    --zai-api-key "your-zai-api-key-here"
```

Or interactively (password prompted, API key via desktop wizard later):
```bash
./niklas_setup-openclaw-lxc.sh
```

The script will:
- Download a Debian 13 template
- Create an **unprivileged** LXC container (3GB RAM, 2 cores, 16GB disk)
- Configure Proxmox firewall + in-container iptables
- Install Node.js 24, OpenClaw, LXQt desktop, Chrome, VNC/noVNC
- Configure OpenClaw with hardened baseline
- Set up all services as non-root user `openclaw`
- Run security audit

#### 4. Access the Remote Desktop (via SSH tunnel)

```bash
# From your workstation:
ssh -L 6080:localhost:6080 root@<CONTAINER_IP>

# Then open in your browser:
# http://localhost:6080/vnc.html
# Enter the VNC password printed at the end of setup
```

#### 5. Use OpenClaw

From the remote desktop:
- Click **"OpenClaw Setup Wizard"** to run onboarding
- Click **"OpenClaw Dashboard"** to open the control UI
- The dashboard is at http://127.0.0.1:18789 (accessible from inside the container)

#### 6. Verify security

```bash
pct exec <VMID> -- su - openclaw -c 'openclaw security audit --deep'
```

---

## Security Layers (Both Options)

```
┌─────────────────────────────────────────────┐
│ Proxmox Firewall (host-enforced)            │
│  ✓ Default policy: DROP in + DROP out       │
│  ✓ Allow: gateway IP (for routing)          │
│  ✓ Allow: DNS server                        │
│  ✓ Block: LAN subnet (192.168.178.0/24)    │
│  ✓ Block: ALL RFC1918 (10/8, 172.16/12)    │
│  ✓ Allow: internet (everything else)        │
│  ✓ Inbound: SSH only from LAN              │
├─────────────────────────────────────────────┤
│ In-Container/VM Hardening (defense in depth) │
│  ✓ Docker cap_drop: NET_RAW, NET_ADMIN,      │
│    SYS_ADMIN                                  │
│  ✓ security_opt: no-new-privileges            │
│  ✓ network_mode: host + loopback bind only    │
│  Note: In-VM iptables removed (conflicts with │
│  Docker). Proxmox firewall is sufficient.     │
├─────────────────────────────────────────────┤
│ IPv6 Disabled                               │
│  ✓ Prevents bypass of IPv4-only rules       │
├─────────────────────────────────────────────┤
│ OpenClaw Hardened Config                    │
│  ✓ Gateway: loopback only                   │
│  ✓ Auth: 256-bit random token               │
│  ✓ Tools profile: "coding" (Skills nutzbar) │
│  ✓ Exec: "full" with ask "off" (für Skills) │
│  ✓ Deny: sessions_spawn, sessions_send      │
│  ✓ Sessions: per-channel-peer isolation     │
│  ✓ Elevated tools: disabled                 │
│  ✓ FS: workspace-only                       │
│  Note: Initial setup uses "messaging" profile│
│  Upgrade to "coding" when adding Skills     │
│  (see openclaw-home-assistant-integration.md)│
├─────────────────────────────────────────────┤
│ OS-Level Hardening                          │
│  ✓ Non-root service user                    │
│  ✓ File permissions: 700/600                │
│  ✓ Unattended security upgrades             │
│  ✓ Chrome sandbox enabled (LXC only)        │
│  ✓ Docker cap drops (VM only)               │
└─────────────────────────────────────────────┘
```

---

## Which Option to Choose?

| Factor | OpenClaw VM | OpenClaw LXC | Hermes VM |
|-|-|-|-|
| **Isolation** | ★★★★★ Hypervisor | ★★★★ Kernel NS | ★★★★★ Hypervisor |
| **RAM** | 4 GB | 3 GB | 3 GB |
| **Desktop/GUI** | No (headless) | Yes (noVNC) | Dashboard (web) |
| **Browser** | No | Yes (Chrome) | Optional |
| **Setup** | Script (fire&forget) | Script | Script (fire&forget) |
| **Skills** | SKILL.md + ClawHub | SKILL.md + ClawHub | Auto-generated |
| **Memory** | Session hooks | Session hooks | Persistent (auto) |
| **Open Source** | No | No | Yes (MIT) |
| **Best for** | Proven gateway | Desktop setup | Open-source alternative |

**Recommendation**: Use VM if you only need the API gateway. Use LXC if you
want the desktop experience for onboarding and browser-based channel setup.

---

## Option 3: Hermes Agent VM (Alternative to OpenClaw)

**Best for**: Side-by-side comparison with OpenClaw. Hermes Agent by Nous
Research is an open-source (MIT) autonomous agent with persistent memory,
auto-generated skills, and scheduled automations.

| Aspekt | OpenClaw (VM 100) | Hermes Agent (VM 101) |
|--------|-------------------|----------------------|
| Hersteller | OpenClaw | Nous Research |
| Lizenz | Proprietary | MIT (Open Source) |
| LLM Provider | Z.AI (nativ) | Z.AI (GLM_API_KEY) |
| Model | zai/glm-4.7 | zai/glm-4.7 |
| Docker Image | ghcr.io/openclaw/openclaw | nousresearch/hermes-agent |
| Gateway Port | 18789 | 8642 |
| Dashboard Port | — (gleicher Port) | 9119 |
| VM IP | 192.168.178.80 | 192.168.178.81 |
| RAM | 4 GB | 3 GB |
| Channels | Telegram, WhatsApp, etc. | Telegram, Discord, Slack, etc. |
| Skills | Workspace-basiert (SKILL.md) | Auto-generiert + installierbar |
| Memory | Hooks + Session-Memory | Persistent (MEMORY.md, USER.md) |
| Sandbox | Docker cap_drop | Local/Docker/SSH/Modal/Singularity |
| Whisper/Audio | Lokaler Whisper Container | Nicht integriert (separat) |

### Prerequisites
- Proxmox VE 8.x+ with root access
- SSH public key on the Proxmox host
- Z.AI API key
- Optional: Telegram bot token, HA long-lived token

### Step-by-Step

#### 1. Copy the script to your Proxmox host

```bash
scp setup-hermes-vm.sh root@<PROXMOX_IP>:/root/
ssh root@<PROXMOX_IP>

# Install jq if not already:
apt install -y jq

chmod +x /root/setup-hermes-vm.sh
sed -i 's/\r$//' /root/setup-hermes-vm.sh
```

#### 2. Run the setup (fire and forget)

```bash
./setup-hermes-vm.sh \
    --zai-api-key "your-zai-api-key" \
    --ssh-pubkey ~/.ssh/id_ed25519.pub \
    --ha-token "your-ha-long-lived-token"
```

With Telegram:
```bash
./setup-hermes-vm.sh \
    --zai-api-key "your-zai-api-key" \
    --ssh-pubkey ~/.ssh/id_ed25519.pub \
    --ha-token "your-ha-long-lived-token" \
    --telegram-token "your-telegram-bot-token"
```

The script will:
- Download Debian 12 cloud image (cached, shared with OpenClaw)
- Create VM 101 with 3GB RAM, 2 cores, 16GB disk (CPU: x86-64-v2-AES)
- Configure Proxmox firewall (blocks LAN, allows HA + Grafana + internet)
- Deploy Hermes via Docker Compose (gateway + dashboard, bridge network)
- Disable IPv6 (prevent firewall bypass)
- Let Hermes generate its default `config.yaml`, then patch model + provider
- Fix file permissions (`644` for `.env` — Docker container needs read access)
- Enable NIC firewall after setup completes
- Wait for health check

> **Bekannte Eigenheiten:**
> - **CPU-Typ**: `x86-64-v2-AES` statt `host` (Kernel Panic mit `host` auf N150)
> - **config.yaml**: Hermes generiert beim ersten Start eine vollständige Default-Config.
>   Das Script patcht `model` und `provider` nachträglich via `sed`.
> - **.env Permissions**: Muss `644` sein (nicht `600`), da der Docker-Container
>   als anderer UID läuft und die Datei lesen muss.
> - **GATEWAY_ALLOW_ALL_USERS**: Ist auf `true` gesetzt, damit Telegram sofort
>   funktioniert. Für Produktion: durch User-Allowlists ersetzen.

#### 3. Access Hermes (via SSH tunnel)

```bash
# From your workstation:
ssh -L 8642:localhost:8642 -L 9119:localhost:9119 hermes@192.168.178.81

# Dashboard: http://localhost:9119
# Gateway API: http://localhost:8642
```

From Windows:
```powershell
ssh -i C:\Users\bvogel\.ssh\id_ed25519_openclaw ^
    -L 8642:localhost:8642 -L 9119:localhost:9119 ^
    hermes@192.168.178.81
```

#### 4. Configure Telegram (if not set during setup)

```bash
ssh hermes@192.168.178.81
nano ~/.hermes/.env
# Add: TELEGRAM_BOT_TOKEN=your-token
cd ~/hermes && docker compose restart hermes
```

#### 5. Verify security

```bash
# Internet works
ssh hermes@192.168.178.81 "curl -sf --max-time 5 https://cloud.debian.org > /dev/null && echo INTERNET_OK"

# HA accessible
ssh hermes@192.168.178.81 "curl -sf --max-time 5 http://192.168.178.88:8123/api/ && echo HA_OK"

# Rest of LAN blocked
ssh hermes@192.168.178.81 "curl -sf --max-time 3 http://192.168.178.108:8006 2>/dev/null && echo LAN_EXPOSED || echo LAN_BLOCKED"
```

### Hermes Directory Structure

```
~/.hermes/
├── .env            ← API keys (GLM_API_KEY, HA_TOKEN, TELEGRAM_BOT_TOKEN, TENNIS_*)
├── config.yaml     ← Settings (model, terminal, memory, tools)
├── SOUL.md         ← Agent personality/identity
├── memories/       ← Persistent memory (auto-managed)
├── skills/         ← Bundled + custom skills
│   └── leisure/
│       └── tennis-booking/   ← Tennis-Platzbuchung
│           ├── SKILL.md
│           └── scripts/tennis.sh
├── sessions/       ← Conversation history
├── cron/           ← Scheduled jobs
├── hooks/          ← Event hooks
└── logs/           ← Runtime logs
```

### Hermes Skills

Hermes organisiert Skills in **Kategorien** (Ordner) unter `~/.hermes/skills/`.

| Kategorie | Skill | Funktion |
|-----------|-------|----------|
| `smart-home/` | `openhue` | Philips Hue Steuerung |
| `leisure/` | `find-nearby` | Orte in der Nähe finden |
| `leisure/` | **`tennis-booking`** | **Tennisplatz-Verfügbarkeit & Buchung** |

**Skill-Format (SKILL.md):**
```yaml
---
name: skill-name
description: Wann der Skill genutzt werden soll.
version: 1.0.0
metadata:
  hermes:
    tags: [Tag1, Tag2]
prerequisites:
  commands: [curl]
  environment_variables: [VAR1, VAR2]
---
# Dokumentation + Beispiele...
```

**Eigenen Skill hinzufügen:**
```bash
mkdir -p ~/.hermes/skills/<kategorie>/<skill-name>/scripts
# SKILL.md + scripts/ erstellen
# Hermes findet neue Skills automatisch (kein Restart nötig)
```

### Hermes CLI (inside VM)

```bash
# Interactive chat
cd ~/hermes && docker compose exec -it hermes hermes

# View config
docker compose exec hermes hermes config

# Set a value
docker compose exec hermes hermes config set model zai/glm-5.1

# Health check
curl -sf http://127.0.0.1:8642/health

# Logs
docker compose logs --tail 50 hermes
docker compose logs --tail 20 hermes-dashboard
```

### Hermes Maintenance

```bash
# Update Hermes
cd ~/hermes
docker compose pull
docker compose up -d

# Restart
docker compose restart hermes

# Backup (.hermes contains all state)
tar czf ~/hermes-backup-$(date +%Y%m%d).tar.gz ~/.hermes/
```

### Hermes Troubleshooting

#### Kernel Panic beim ersten Boot (erwartet!)

Debian 12 Cloud-Images haben einen bekannten Bug: Der **erste Boot** nach
der VM-Erstellung endet häufig in einem Kernel Panic. Nach einem Reset
bootet die VM normal. Das Setup-Script erkennt dies automatisch und
löst einen Reset aus.

Falls manuell nötig:
```bash
# VM ist gestoppt nach Kernel Panic → einfach neu starten
qm start 101
# oder Reset falls sie hängt
qm reset 101
```

> **CPU-Typ**: `x86-64-v2-AES` statt `host` reduziert die Kernel-Panic-
> Häufigkeit auf dem N150, eliminiert sie aber nicht komplett beim ersten Boot.

#### SSH "Permission denied (publickey)"
```bash
# SSH-Key manuell injizieren (vom Proxmox Host)
qm guest exec 101 -- mkdir -p /home/hermes/.ssh
qm guest exec 101 -- bash -c "echo '$(cat /root/.ssh/id_ed25519.pub)' > /home/hermes/.ssh/authorized_keys"
qm guest exec 101 -- chown -R hermes:hermes /home/hermes/.ssh
qm guest exec 101 -- chmod 700 /home/hermes/.ssh
qm guest exec 101 -- chmod 600 /home/hermes/.ssh/authorized_keys

# Password-Auth aktivieren (falls Key nicht funktioniert)
qm guest exec 101 -- bash -c "echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config.d/60-cloudimg-settings.conf"
qm guest passwd 101 hermes
qm reboot 101
```

#### "Permission denied: /opt/data/.env" im Container
```bash
# .env muss 644 sein (nicht 600), da Docker-Container als anderer UID läuft
chmod 644 ~/.hermes/.env
docker compose restart hermes
```

#### "Unknown Model" Fehler
```bash
# Model muss "glm-4.7" sein (nicht "zai/glm-4.7" oder "openai/glm-4.7")
# Provider muss separat auf "zai" stehen
grep -A3 "^model:" ~/.hermes/config.yaml
# Erwartet: default: "glm-4.7" und provider: "zai"

# Falls falsch:
sed -i 's/default:.*".*"/default: "glm-4.7"/' ~/.hermes/config.yaml
# Provider-Zeile finden und auf "zai" setzen
docker compose restart hermes
```

#### Container startet aber .hermes Permissions kaputt
```bash
sudo chown -R hermes:hermes ~/.hermes
sudo chmod 755 ~/.hermes
sudo chmod 644 ~/.hermes/.env ~/.hermes/config.yaml
docker compose restart
```

#### HA-Token nicht verfügbar im Agent
Hermes liest `HA_TOKEN` aus `.env`, macht sie aber nicht automatisch in
der Shell verfügbar. Der Agent muss `$HA_TOKEN` explizit aus der Umgebung
lesen. Wenn Hermes nach dem Token fragt, einfach mitteilen — er merkt
es sich dann in seinem persistenten Memory.

---

## ⚠️ CRITICAL: No Docker on Proxmox Host!

> **Stand 2026-04-20 (bewiesen durch mehrstündigen Ausfall)**

Docker darf **NICHT** auf dem Proxmox Host installiert sein! Docker
überschreibt die iptables FORWARD-Chain mit `policy DROP` und einer
`DOCKER-FORWARD` Chain, die **allen VM-Bridge-Traffic blockiert**.

Symptome wenn Docker auf dem Host installiert ist:
- VMs können den Gateway/Router nicht erreichen
- VMs haben kein Internet
- VMs können sich nicht untereinander erreichen
- Telegram-Bots verbinden nicht
- Home Assistant wird unerreichbar

Falls Docker versehentlich auf dem Proxmox Host installiert wurde:

```bash
# Prüfen
iptables -L DOCKER-USER -n 2>/dev/null && echo "DOCKER GEFUNDEN — ENTFERNEN!" || echo "OK"

# Entfernen
systemctl stop docker docker.socket containerd
systemctl disable docker docker.socket containerd
apt purge -y docker-ce docker-ce-cli docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras containerd.io
apt autoremove -y
iptables -P FORWARD ACCEPT
iptables -F FORWARD
pve-firewall restart
```

> Docker gehört **nur in die VMs/LXCs** (OpenClaw VM 100, Hermes VM 101,
> Whisper LXC 102, Invoicing LXC 103), **niemals** auf den Proxmox Host!

---

## ⚠️ Authoring Scripts on Windows for Linux

> If you author or edit scripts on a Windows PC and deploy them to
> Proxmox/LXCs/VMs, follow this checklist EVERY TIME. We hit CRLF and
> related issues repeatedly — these are the proven fixes.

### Repo-level (one-time setup)

```bash
# In repo root:
cat > .gitattributes << 'EOF'
*.sh text eol=lf
*.bash text eol=lf
*.yaml text eol=lf
*.yml text eol=lf
Dockerfile text eol=lf
EOF

git config core.autocrlf input
```

This forces `.sh` files to LF on checkin and prevents Git from inserting
CRs at checkout on Windows. **Already configured in this repo.**

### Editor (VS Code)

`settings.json`:
```json
{
  "files.eol": "\n",
  "files.encoding": "utf8"
}
```

Check the status bar (bottom-right): should show `LF` and `UTF-8`. Click
to change if needed.

### Per-script checklist before deploying

```bash
# 1. Convert any leftover CRLF (PowerShell)
$f = "D:\repo\setup.sh"
[System.IO.File]::WriteAllText($f, ([System.IO.File]::ReadAllText($f) -replace "`r`n","`n"))

# 2. Transfer via scp (NOT copy-paste into nano)
scp setup.sh root@<host>:/root/

# 3. ALWAYS run defensive sed after scp (belt-and-suspenders)
ssh root@<host> 'sed -i "s/\r$//" /root/setup.sh && chmod +x /root/setup.sh'

# 4. Validate syntax before executing
ssh root@<host> 'bash -n /root/setup.sh && echo SYNTAX_OK'

# 5. Then run
ssh root@<host> '/root/setup.sh'
```

### PowerShell-to-SSH gotcha: command substitution

```powershell
# ❌ DOUBLE quotes — PowerShell expands $() and $var CLIENT-side
ssh root@host "PW=$(openssl rand -base64 16); echo $PW"
# → 'openssl' is not recognized as a cmdlet

# ✅ SINGLE quotes — string passes verbatim, Linux evaluates
ssh root@host 'PW=$(openssl rand -base64 16); echo $PW'
```

### Why this matters

A CRLF in a shell script causes:
- `syntax error near unexpected token $'in\r''`
- `$'\r': command not found`
- Silent `case` fall-through (CR makes patterns never match)
- `#!/bin/bash\r` → "No such file or directory" on first line

See `LESSONS-LEARNED.md` section 15 for full details and entries
#25, #26, #27 in the chronology.

---

## Option 4: Shared Whisper LXC (Voice Transcription)

**Best for**: Shared speech-to-text service used by both OpenClaw and Hermes
for Telegram voice messages.

### Step-by-Step

```bash
scp setup-whisper-lxc.sh root@<PROXMOX_IP>:/root/
ssh root@<PROXMOX_IP>
chmod +x /root/setup-whisper-lxc.sh
sed -i 's/\r$//' /root/setup-whisper-lxc.sh

./setup-whisper-lxc.sh --ssh-pubkey ~/.ssh/id_ed25519.pub
```

The script creates LXC 102 (IP .82) with faster-whisper-server, restricted
by firewall to only accept connections from OpenClaw (.80) and Hermes (.81).

---

## Option 5: e-Invoice LXC (Batch Invoicing + Web UI) ✅ Tested

**Best for**: Running the e-Invoice application as a Docker batch job with
NAS access via NFS. Generates PDF invoices from Excel input, sends via email.
Also provides a web UI on port 8080 for interactive invoice management.

### Prerequisites

- Synology NAS (`brain`) with NFS enabled on the `praxis` share
  - NFS permissions for both **Proxmox host IP** (.108) and **LXC IP** (.83)
  - Squash: "Map all users to admin" (required for unprivileged LXC UID mapping)
- GitHub PAT for the private repo (used once during clone, then removed)
- KeePassXC master password (for credentials database on NAS)

### NAS Setup (Synology DSM)

1. **Create service account**: Control Panel → User & Group → Create `svc-invoicing`
   - Permissions: `praxis` share = Read/Write, all others = No Access
   - Applications: Deny all (DSM, File Station, etc.)

2. **Enable NFS**: Control Panel → File Services → NFS → Enable

3. **Add NFS rule**: Shared Folder → `praxis` → Edit → NFS Permissions → Create
   - Hostname/IP: `192.168.178.108` (Proxmox host — does the actual NFS mount)
   - Also add: `192.168.178.83` (LXC IP — for future flexibility)
   - Privilege: Read/Write
   - Squash: Map all users to admin
   - Security: sys
   - Enable async: Yes, Allow non-privileged ports: Yes

4. **Find the export path**: `showmount -e 192.168.178.74` (typically `/volume8/praxis`)

### Step-by-Step

```bash
scp setup-einvoice-lxc.sh root@<PROXMOX_IP>:/root/
ssh root@<PROXMOX_IP>
chmod +x /root/setup-einvoice-lxc.sh
sed -i 's/\r$//' /root/setup-einvoice-lxc.sh

./setup-einvoice-lxc.sh \
    --ssh-pubkey ~/.ssh/id_ed25519.pub \
    --keepass-pw "YourKeePassMasterPassword" \
    --github-pat "ghp_xxxx" \
    --nas-ip 192.168.178.74 \
    --nas-export /volume8/praxis
```

The script:
- Mounts NAS via NFS on the **Proxmox host** (unprivileged LXCs can't mount NFS)
- Bind-mounts into LXC via `pct set -mp0` (persists across reboots)
- Creates LXC 103 (IP .83) with Docker
- Clones the private repo, copies Century Gothic fonts from NAS, builds Docker image
- Creates convenience commands: `invoice` and `invoice-update`
- Verifies NAS read+write access from inside LXC
- Opens firewall port 8080 for the web UI (LAN access only)

### Usage

```bash
# Generate April 2026 invoices (draft mode)
pct enter 103
cd /opt/e-invoice/e-Invoice
docker compose run --rm e-invoice \
    --journal /data/praxis/Rechnungen/2026/Rechnungsliste_2026.xlsx \
    --session SaaS_LXC --config config \
    --year 2026 --month 4 -dr -u

# Fire & forget (sends emails directly)
docker compose run --rm e-invoice \
    --journal /data/praxis/Rechnungen/2026/Rechnungsliste_2026.xlsx \
    --session SaaS_LXC --config config \
    --year 2026 --month 4 --fireforget --prodrun

# Update code + rebuild
cd /opt/e-invoice && git pull && cd e-Invoice && docker compose build
```

### Troubleshooting

| Problem | Cause | Fix |
|---------|-------|-----|
| `mount.nfs: access denied` | NFS permissions missing for PVE host IP | Add `.108` to NFS rules on NAS |
| `"/\|\|": not found` during build | Dockerfile `COPY ... 2>/dev/null` | Fixed: COPY is not a shell cmd |
| `ImportError: libtk8.6.so` | tkinter imported at module level | Fixed: lazy import in Python code |
| Docker FORWARD chain on host | Setup script ran Docker install on host | Remove with `iptables -F/-X DOCKER*` |
| NAS writable but not from LXC | UID mapping (unprivileged LXC) | NAS squash: "Map all users to admin" |
| `ping: Operation not permitted` | Docker needs NET_RAW capability | `cap_add: [NET_RAW]` in compose |

---

## Option 6: Home Assistant OS VM

**Best for**: Reproducing or creating a new Home Assistant OS VM based on
the proven VM 108 configuration.

### Step-by-Step

```bash
scp setup-haos-vm.sh root@<PROXMOX_IP>:/root/
ssh root@<PROXMOX_IP>
chmod +x /root/setup-haos-vm.sh
sed -i 's/\r$//' /root/setup-haos-vm.sh

./setup-haos-vm.sh --vm-id 109
```

Optional parameters: `--vm-ip`, `--ram`, `--disk`, `--usb-device`, etc.

---

## Option 7: Forgejo LXC (Self-Hosted Git Forge) ✅ Tested

**Best for**: Sovereign self-hosted Git platform — alternative to GitHub.
Adapted from [Jorijn's hardened Forgejo setup](https://jorijn.com/en/blog/leaving-github-for-forgejo/)
but using LXC + Docker Compose (proven pattern) instead of bare-metal Docker.

### Architecture

```
LXC 104 (192.168.178.84)  — 256 MB RAM + 512 MB swap, 16 GB disk
├── Caddy 2 (reverse proxy, self-signed TLS, ports 80/443)
├── Forgejo v15.0.2 (web UI on 3000, SSH on 3022)
└── Postgres 17 (internal Docker network only)
```

### Security adapted from Jorijn's 5-layer model

| Jorijn (Forgejo on bare-metal NUC) | Our LXC adaptation |
|------------------------------------|--------------------|
| KVM VM for runner | Separate LXC 105 (Phase 2, deferred) |
| gVisor runtime | Deferred (no Actions runner yet) |
| nftables egress filter | **Proxmox firewall: `policy_out: DROP`**, RFC1918 blocked, DNS/NTP/HTTPS allowed |
| Weekly destructive rebuild | Cron when runner is added (Phase 2) |
| Scope-bound runner tokens | Forgejo v15 native repo-specific tokens |
| Traefik | **Caddy 2** with pre-generated self-signed cert (IP + hostname SANs) |

### Step-by-Step

```bash
scp setup-forgejo-lxc.sh root@<PROXMOX_IP>:/root/
ssh root@<PROXMOX_IP>
chmod +x /root/setup-forgejo-lxc.sh
sed -i 's/\r$//' /root/setup-forgejo-lxc.sh

# Stop a VM first if RAM is tight (e.g., haos-dev)
qm stop 109

./setup-forgejo-lxc.sh \
    --ssh-pubkey /root/.ssh/id_ed25519.pub \
    --admin-user bvogel \
    --admin-email your@email.com
```

Optional: `--ct-id 104  --ct-ip 192.168.178.84  --ram 768  --swap 512  --disk 16`

### What the script does

- Creates LXC 104 (unprivileged Debian 12, onboot=1)
- Bind-mounts `/var/lib/forgejo-backups` (PVE host) → `/backups` (LXC)
- Hardens firewall (inbound: SSH/HTTPS/HTTP/3022/ICMP from LAN; outbound: DROP except DNS/NTP/HTTP/HTTPS/SSH)
- Installs Docker (proven pattern)
- Pre-generates self-signed cert with IP + hostname SANs (avoids Caddy `tls internal` IP-SNI issues)
- Deploys Forgejo + Postgres 17 (tuned for 256 MB) + Caddy 2 via Docker Compose
- Creates admin user
- Installs daily backup cron at 03:00 (14-day retention)
- Creates convenience commands: `forgejo-backup`, `forgejo-update <version>`
- Verifies HTTPS endpoint works

### First-time browser access

```
https://192.168.178.84/
→ Accept self-signed cert warning (one-time)
→ Login with admin user + password printed at end of setup
```

### Git SSH setup on workstation

Add to `~/.ssh/config`:

```sshconfig
Host forgejo
    HostName 192.168.178.84
    User git
    Port 3022
    IdentityFile ~/.ssh/id_ed25519
```

Then: `git clone forgejo:bvogel/myrepo.git`

> **Why port 3022 and not 22?** Port 22 on the LXC is used by the system SSH
> daemon (for management). Forgejo's Git SSH runs on port 22 inside the
> container, mapped to host port 3022. This is the simpler approach (no
> conflict, no need to move system SSH).

### Troubleshooting

| Problem | Cause | Fix |
|---------|-------|-----|
| `TLS handshake: internal error` | Caddy `tls internal` produces critical SAN with IP-only — clients reject | Script pre-generates cert with `openssl req` — IP+hostname SANs |
| `git clone git@192.168.178.84:...` fails | Defaults to port 22 (LXC SSH, not Forgejo) | Use `ssh://git@.84:3022/...` or `~/.ssh/config` Host alias |
| Browser cert warning | Self-signed cert (LAN-only) | Accept once or install Caddy root CA |
| `password does not meet complexity` | Forgejo requires upper+lower+digit+special, ≥12 chars | Use mixed-class password |
| Initial backup test "no such file or directory: /data/git/repositories" | No repos exist yet on fresh install | Expected; backup script skips `forgejo dump` and runs `pg_dump` only until repos exist |
| `open /backups/...: permission denied` in backup log | Unprivileged LXC: PVE host's `/var/lib/forgejo-backups` owned by UID 0 maps to "nobody" inside LXC | `chown 100000:100000 /var/lib/forgejo-backups` on PVE host (UID 100000 = root inside LXC) |
| Out of memory / Postgres OOM | Default `shared_buffers=128MB` too big for 256 MB LXC | Script tunes Postgres: `shared_buffers=32MB`, `work_mem=2MB`, `effective_cache_size=128MB` |

### What's NOT included (Phase 2)

- **Forgejo Actions runner** — separate LXC 105 planned, with egress filtering, ephemeral runners, weekly destructive rebuild
- **External access** — currently LAN-only; for internet exposure, set up a domain + Let's Encrypt
- **GitHub repo migration** — see Option 8 for automated bulk mirror

---

## Option 8: GitHub → Forgejo Bulk Mirror ✅ Tested

**Best for**: Continuous near-real-time replication of GitHub repos to your
local Forgejo as backup/sovereignty insurance. GitHub remains master, Forgejo
auto-pulls changes every 10 minutes. See `forgejo-github-mirror-plan.md`
for the full design rationale (validated by rubber-duck).

### What it does

- Bulk-creates pull mirrors via Forgejo's `/api/v1/repos/migrate` API
- Idempotent — safe to re-run when new GitHub repos are created
- Default: mirrors only PRIVATE repos. Add `--include-public` for all.
- Active repos: poll every 10 min. Archived repos: weekly.
- Stores GitHub PAT encrypted in Forgejo's DB (rotation: re-run script).
- 3 cron-managed companion jobs:
  - **Daily health check** (06:00) — alerts if any mirror stale >2h
  - **Weekly Git bundles** (Mon 04:00) — true backup to NAS, immune to force-push
  - Plus the existing **daily Forgejo dump** (03:00) from setup

### Step-by-Step

```bash
# On PVE host (Forgejo LXC 104 must be running)

# 1. Bump LXC RAM temporarily for initial clone storm
pct set 104 --memory 1536

# 2. Get GitHub PAT (fine-grained, Contents+Metadata read-only, scoped to repos)
echo "ghp_xxx..." > /tmp/github-pat.txt && chmod 600 /tmp/github-pat.txt

# 3. Create Forgejo admin PAT via API
curl -ks -X POST -u "ADMIN:ADMIN_PW" -H "Content-Type: application/json" \
    -d '{"name":"mirror-bot","scopes":["write:repository","write:organization","write:user","read:admin"]}' \
    https://192.168.178.84/api/v1/users/ADMIN/tokens | jq -r .sha1 > /root/.forgejo-token
chmod 600 /root/.forgejo-token

# 4. Create Forgejo org `github-mirror`
curl -ksX POST -H "Authorization: token $(cat /root/.forgejo-token)" \
    -H "Content-Type: application/json" \
    -d '{"username":"github-mirror","visibility":"private","description":"Mirror from GitHub"}' \
    https://192.168.178.84/api/v1/orgs

# 5. Copy and run the mirror script (does EVERYTHING: mirror, NAS bind-mount,
#    install monitoring scripts, install crons, run initial health check)
scp mirror-github-to-forgejo.sh root@<PROXMOX_IP>:/root/
chmod +x /root/mirror-github-to-forgejo.sh

export GITHUB_PAT=$(cat /tmp/github-pat.txt)
export FORGEJO_TOKEN=$(cat /root/.forgejo-token)
/root/mirror-github-to-forgejo.sh
# → mirrors all PRIVATE repos
# → bind-mounts /mnt/nas-praxis/backups/git-bundles → /nas-bundles in LXC
# → installs /usr/local/bin/forgejo-mirror-health (daily 06:00 cron)
# → installs /usr/local/bin/forgejo-bundle-snapshot (weekly Mon 04:00 cron)
# → runs initial health check

# 6. Verify mirrors
curl -ks -H "Authorization: token $(cat /root/.forgejo-token)" \
    "https://192.168.178.84/api/v1/orgs/github-mirror/repos?limit=50" \
    | jq -r '.[] | "\(.name)\t\(.size)KB"'

# 7. Restore LXC RAM
pct set 104 --memory 768

# 8. Clean up PAT file
shred -u /tmp/github-pat.txt
```

### Tested results (2026-05-17)

- 13 PRIVATE repos mirrored in ~2 minutes
- Total disk on LXC 104: 252 MB (well within 16 GB)
- Forgejo peak memory during bulk: 327 MB (use temp `pct set 104 --memory 1536` during bulk; actual idle ~75 MB)
- All 13 bundled to NAS at 250 MB total

### Troubleshooting

| Problem | Cause | Fix |
|---------|-------|-----|
| `Not Found` from `/orgs/SREbuilt/repos` | SREbuilt is a USER not an org | Use `/user/repos?affiliation=owner` (script already does) |
| `git bundle: Need a repository` | Git's safe.directory check rejects different UID | Use `git -c safe.directory='*' bundle ...` |
| `git bundle: Need a repository` | Git's safe.directory check rejects different UID | Use `git -c safe.directory='*' bundle ...` |
| `pct: command not found` in cron | Cron's minimal PATH excludes `/usr/sbin` | Add `PATH=/usr/sbin:/usr/bin:/sbin:/bin` to cron file (script does this) |
| `mountpoint -q` returns false but NAS mounted | `dirname` of `/mnt/nas-praxis/backups/git-bundles` ≠ mountpoint | Script now uses `touch test-write` to detect writability |
| Bulk migration counters show 0 | Subshell variable scope (pipe to `while read`) | Cosmetic only — count by listing mirrors after |
| Mirror stuck not syncing | GitHub auth failed (rotated PAT) | Edit mirror auth via Forgejo UI per repo |

---

## Option 9: Neo4j Graph Database LXC ✅ Tested

**Best for**: Self-hosted graph database for relationship-heavy data (knowledge graphs, recommendation systems, code dependencies, social networks). Same proven LXC + Docker + Caddy pattern as Forgejo.

### Architecture

```
LXC 107 (192.168.178.87) — 2 GB RAM + 512 MB swap, 16 GB disk
├── Caddy 2 (reverse proxy :80 → :443 self-signed)
├── Neo4j 5.26.26-community (LTS, pinned)
│   ├── HTTP/Browser :7474 (internal, behind Caddy)
│   └── Bolt protocol :7687 (exposed to LAN)
└── Backup bind-mounts:
    ├── /backups       → /var/lib/neo4j-backups (PVE, 7 retained)
    └── /nas-backups   → /mnt/nas-proxmox-backups/proxmox/neo4j (NAS, 30 retained)
```

### Prerequisites — NAS user

Create on Synology DSM **first**:
1. User & Group → Create `pve-svc-neo4j-backup` (strong password, no apps enabled)
2. Shared Folder `backups` → Edit → Permissions → grant `pve-svc-neo4j-backup` **Read/Write**

### Memory tuning for 2 GB LXC

- Neo4j heap (init+max): 512 MB
- Page cache: 512 MB
- Tx memory cap: 256 MB
- Caddy + OS + Docker: ~500 MB
- Headroom: ~500 MB

### Step-by-Step

```bash
scp setup-neo4j-lxc.sh root@<PROXMOX_IP>:/root/
ssh root@<PROXMOX_IP>
chmod +x /root/setup-neo4j-lxc.sh
sed -i 's/\r$//' /root/setup-neo4j-lxc.sh

# Pass NAS credentials via flags
/root/setup-neo4j-lxc.sh \
    --ssh-pubkey /root/.ssh/id_ed25519.pub \
    --smb-user pve-svc-neo4j-backup \
    --smb-password 'YOUR_NAS_PASSWORD'
```

The script (11 steps):
1. Downloads Debian 12 template
2. Mounts NAS share `\\brain\backups` via CIFS (creates creds file, persists in `/etc/fstab`), creates `proxmox/neo4j/` subfolder, writes test
3. Prepares local backup dir with `chown 100000:100000` (unprivileged LXC UID mapping)
4. Creates LXC 107 with both bind-mounts
5. Hardens firewall (Bolt 7687 + HTTPS/HTTP + SSH from LAN, RFC1918 outbound blocked)
6. Starts LXC, waits for SSH
7. Installs Docker
8. Pre-generates self-signed cert (IP + hostname SANs), deploys Neo4j + Caddy
9. Installs 2-tier backup script + daily cron at 03:00
10. Runs initial backup, verifies both tiers
11. Enables firewall

### Connect from your workstation

**Browser UI** (graph visualization, cypher editor):
- **Recommended**: https://192.168.178.87:7473/browser/ (Neo4j's own HTTPS — no proxy)
- Alternative: https://192.168.178.87/browser/ (via Caddy)
- Accept self-signed cert (one-time)
- Connect URL: **`neo4j+s://192.168.178.87:7687`** (use `bolt+ssc://` if cert is rejected)
- Login: `neo4j` / *(password printed at end of setup)*

**Bolt driver** (Python, Node.js, Java, Go, etc.):
```python
from neo4j import GraphDatabase
driver = GraphDatabase.driver("neo4j+ssc://192.168.178.87:7687",
                              auth=("neo4j", "YOUR_PASSWORD"))
```

**cypher-shell** (CLI):
```bash
cypher-shell -a bolt+ssc://192.168.178.87:7687 -u neo4j -p 'YOUR_PASSWORD'
```

📖 **See `USER-MANUAL-NEO4J.md` for the full user guide**, including driver examples for all languages, CSV import, restore procedures, and troubleshooting.

### Troubleshooting

| Problem | Cause | Fix |
|---------|-------|-----|
| `Unrecognized setting: dbms.backup.enabled` | Enterprise-only flag in compose env | Remove `NEO4J_dbms_backup_enabled=true` — Community doesn't have it |
| NAS copy "Permission denied" inside LXC | CIFS `uid=0` maps to "nobody" inside unprivileged LXC | Mount with `uid=100000,gid=100000` (script does this) |
| Neo4j refuses connection (`Bolt`) | Container still starting (60-90s) | Wait — health check has 90s start_period |
| Backup script fails in cron, works manually | Cron PATH missing `/usr/sbin` | `PATH=/usr/sbin:...` in `/etc/cron.d/` (script does this) |
| HTTPS handshake fails | Caddy `tls internal` IP-only SAN issue | Script pre-generates cert with `openssl req` (IP + hostname SANs) |
| **Browser login "Failed to fetch"** | **HTTPS Browser blocked from `bolt://` (mixed-content)** | **Use `neo4j+s://` or `bolt+ssc://` connect URL — script enables Bolt TLS** |

---

## Post-Setup: Connecting Channels

After setup, configure your messaging channels:
1. Access the dashboard (via SSH tunnel)
2. Or run the onboard wizard: `openclaw onboard`
3. Follow prompts to connect WhatsApp, Telegram, Discord, etc.

## Maintenance

```bash
# Update OpenClaw (VM 100):
ssh claw@192.168.178.80 'cd ~/openclaw && docker compose pull && docker compose up -d'

# Update Hermes (VM 101):
ssh hermes@192.168.178.81 'cd ~/hermes && docker compose pull && docker compose up -d'

# Update Whisper (LXC 102):
ssh root@192.168.178.82 'cd /root/whisper && docker compose pull && docker compose up -d'

# Update e-Invoice (LXC 103):
ssh root@192.168.178.83 invoice-update

# Update Forgejo (LXC 104):
ssh root@192.168.178.108 'pct exec 104 -- forgejo-update 15.0.3'

# Backup Forgejo (manual, runs daily at 03:00 automatically):
ssh root@192.168.178.108 'pct exec 104 -- forgejo-backup'

# Security audit (OpenClaw):
ssh claw@192.168.178.80 'cd ~/openclaw && docker compose exec openclaw-gateway node openclaw.mjs security audit --deep'

# Check all services:
ssh claw@192.168.178.80 'cd ~/openclaw && docker compose ps'       # OpenClaw
ssh hermes@192.168.178.81 'cd ~/hermes && docker compose ps'        # Hermes
ssh root@192.168.178.82 'cd /root/whisper && docker compose ps'     # Whisper
```
