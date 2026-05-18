# GitHub → Forgejo Mirror Plan

> **Goal**: Continuous near-real-time **Git replica** of all 44 GitHub
> repos from `SREbuilt` org to local Forgejo (LXC 104, `192.168.178.84`).
>
> **Policy**: GitHub remains the master, Forgejo is read-only replica.
> Developers continue to push to GitHub. Forgejo auto-pulls changes.
>
> **Scope clarification (per rubber-duck critique)**: This is **not** a
> full backup — it replicates Git refs only. For true disaster-recovery
> backup (immune to force-pushes, branch deletes, GitHub data loss), see
> "Archival snapshots" section below.
>
> **RPO**: Up to 10 minutes stale (poll interval). Acceptable for replica
> purposes. Phase B can reduce to seconds for selected hot repos.

---

## TL;DR (recommended approach)

1. **Phase 1 (now)**: Forgejo native pull-mirror, 10 min interval, all 44 repos
2. **Phase 1b (now)**: Weekly `git bundle` snapshot to NAS (immune to ref deletion)
3. **Phase 2 (deferred)**: Per-repo push-from-GitHub for true real-time sync (needs tunnel)

---

## Inventory (discovered 2026-05-17)

44 repos in `SREbuilt` org, total ~750 MB:

| Visibility | Count | Total size |
|-----------|-------|------------|
| Public | 26 | ~500 MB |
| Private | 18 | ~250 MB |

Largest repos (will dominate initial clone time):
- `HA_GeekDashboard_Lovelance` — 151 MB
- `regenwasserzisterne` — 137 MB
- `knx_ha_converter` — 90 MB
- `esphome-jk-bms` — 77 MB
- `vscode-reveal` — 59 MB
- `EOS` — 43 MB
- `py-gpt` — 38 MB
- `lp-bulk-markdown-converter` — 30 MB
- `JK-CAN-RS485-protocols` — 29 MB

LXC 104 has 16 GB disk, currently using <1 GB — plenty of room for 750 MB
of repos with git-pack overhead (estimate ~1.5 GB packed).

---

## Comparison of mirror approaches

| Approach | Pros | Cons | Latency | Best for |
|----------|------|------|---------|----------|
| **A. Forgejo pull mirror** (recommended) | ✅ Server-side, scalable to many repos<br>✅ No public endpoint needed<br>✅ Survives GitHub outage<br>✅ Auto-retries on failure | ⚠️ Polling-based (10-min min default)<br>⚠️ No issue/PR/release sync | 10 min | All-repo mirror baseline |
| **B. GitHub Actions → Forgejo API** | ✅ Near-instant (seconds)<br>✅ Per-repo control | ❌ Needs Forgejo publicly reachable (tunnel/port-forward)<br>❌ Workflow file in EVERY repo<br>❌ Stops on GitHub Actions outage | <1 min | Hot repos (this `proxmox` repo) |
| **C. webhook → forgejo-sync-bot** | ✅ Near-instant<br>✅ One bot for all repos | ❌ Needs public endpoint<br>❌ Custom bot to maintain<br>❌ Webhook delivery has GitHub outage dependency | <1 min | Org-wide hot setup |
| **D. cron `git fetch` on PVE** | ✅ Simple shell script | ❌ Reinvents wheel<br>❌ No Forgejo UI integration<br>❌ Manual auth/secret handling | configurable | Niche only |

**Decision**: A as baseline for all 44 repos. B optionally for the 1-3 most
active repos (likely just `proxmox`).

---

## Phase 1 — Bulk migration with pull mirror (recommended NOW)

### Prerequisites

1. **GitHub PAT** — **fine-grained**, read-only `Contents` + `Metadata`
   permissions, restricted to the 44 SREbuilt repos. NOT classic `repo`
   scope (too broad).
2. **Forgejo admin PAT** (already have admin user `bvogel`)
   - Forgejo: Settings → Applications → Generate New Token
   - Scopes needed: `write:repository`, `write:user`, `write:organization`
3. **Forgejo org `github-mirror`** to hold all mirrored repos (clean separation)

### Important: pilot first

Before bulk migration, do a **pilot run** with the **largest private repo**
(`knx_ha_converter`, 90 MB) and watch:
- Forgejo container memory (`docker stats forgejo`)
- LXC swap usage (`free -h` inside LXC 104)
- OOM kills (`dmesg | grep -i oom`)

If 768 MB RAM thrashes during clone, temporarily bump RAM to 1.5 GB for
the migration (`pct set 104 --memory 1536`), then drop back to 768 MB
after all 44 are imported.

### One-time setup

1. **Inventory personal account** (not just SREbuilt):
   ```bash
   # Check if bvogel personal account has repos
   gh repo list bvogel --limit 50 --json name,isPrivate,diskUsage
   ```
   If yes, decide: mirror them too, or scope to SREbuilt only?

2. **Create Forgejo org** `github-mirror` (via web UI or API):
   ```bash
   curl -ksX POST -H "Authorization: token ${FORGEJO_TOKEN}" \
       -H "Content-Type: application/json" \
       "${FORGEJO_URL}/api/v1/orgs" \
       -d '{"username":"github-mirror","visibility":"private","description":"Auto-mirrored from github.com/SREbuilt"}'
   ```

3. **Lower mirror minimum interval** in Forgejo (if going below 10m):
   - Add env var in `docker-compose.yml`:
     ```yaml
     environment:
       - FORGEJO__mirror__MIN_INTERVAL=5m
       - FORGEJO__mirror__DEFAULT_INTERVAL=10m
     ```
   - **Forgejo restart required**: `docker compose up -d forgejo`
   - Existing mirrors keep their stored interval — new value affects new mirrors only.

### Bulk migration script (`mirror-github-to-forgejo.sh`)

```bash
#!/bin/bash
# Migrate all SREbuilt repos to Forgejo as pull mirrors (idempotent)
set -euo pipefail

GITHUB_ORG="SREbuilt"
GITHUB_PAT="${GITHUB_PAT:?set GITHUB_PAT}"   # fine-grained, read-only

FORGEJO_URL="https://192.168.178.84"
FORGEJO_TOKEN="${FORGEJO_TOKEN:?set FORGEJO_TOKEN}"
FORGEJO_ORG="github-mirror"

# Get all SREbuilt repos via gh (include archived for backup purposes)
gh repo list "$GITHUB_ORG" --limit 100 \
        --json name,visibility,isArchived,description \
    | jq -c '.[]' \
    | while read -r repo; do

    NAME=$(echo "$repo" | jq -r .name)
    PRIVATE=$([ "$(echo "$repo" | jq -r .visibility)" = "PRIVATE" ] && echo "true" || echo "false")
    ARCHIVED=$(echo "$repo" | jq -r .isArchived)
    DESCRIPTION=$(echo "$repo" | jq -r '.description // ""' | sed 's/"/\\"/g')

    # Archived repos: poll once a week (less load, still preserved)
    if [[ "$ARCHIVED" == "true" ]]; then
        INTERVAL="168h"
        PREFIX="[archived] "
    else
        INTERVAL="10m"
        PREFIX=""
    fi

    # IDEMPOTENCY: check if mirror already exists
    EXISTS=$(curl -ks -o /dev/null -w "%{http_code}" \
        -H "Authorization: token ${FORGEJO_TOKEN}" \
        "${FORGEJO_URL}/api/v1/repos/${FORGEJO_ORG}/${NAME}")

    if [[ "$EXISTS" == "200" ]]; then
        echo "✓ ${NAME} already mirrored — skipping"
        continue
    fi

    echo "→ Mirroring ${NAME} (private=${PRIVATE}, archived=${ARCHIVED}, interval=${INTERVAL})..."

    HTTP_CODE=$(curl -ks -o /tmp/migrate-${NAME}.json -w "%{http_code}" \
        -X POST "${FORGEJO_URL}/api/v1/repos/migrate" \
        -H "Authorization: token ${FORGEJO_TOKEN}" \
        -H "Content-Type: application/json" \
        -d @- << EOF
{
    "clone_addr": "https://github.com/${GITHUB_ORG}/${NAME}.git",
    "auth_token": "${GITHUB_PAT}",
    "repo_owner": "${FORGEJO_ORG}",
    "repo_name": "${NAME}",
    "mirror": true,
    "mirror_interval": "${INTERVAL}",
    "private": ${PRIVATE},
    "description": "${PREFIX}Pull mirror of github.com/${GITHUB_ORG}/${NAME}",
    "service": "github",
    "issues": false,
    "pull_requests": false,
    "wiki": false,
    "releases": false,
    "milestones": false,
    "labels": false,
    "lfs": false
}
EOF
)
    if [[ "$HTTP_CODE" == "201" ]]; then
        echo " ✓ Created"
    elif [[ "$HTTP_CODE" == "409" ]]; then
        echo " ✓ Already exists (race)"
    else
        echo " ✗ HTTP $HTTP_CODE — see /tmp/migrate-${NAME}.json"
    fi
    sleep 3   # gentle on GitHub and Forgejo
done

echo "Done. Verify: curl -ks -H 'Authorization: token \$FORGEJO_TOKEN' \\"
echo "  '${FORGEJO_URL}/api/v1/orgs/${FORGEJO_ORG}/repos?limit=50' | jq '.[].name'"
```

### What this does

- For each `SREbuilt` repo (including archived):
  - **GET first** to check if mirror exists → idempotent re-runs OK
  - Active repos: 10 min poll interval
  - Archived repos: 168h (weekly) poll — preserved but low overhead
  - Calls `POST /api/v1/repos/migrate` with `mirror: true` and `auth_token` (not embedded in URL)
  - Forgejo clones the repo SYNCHRONOUSLY (one at a time, no clone storm)
  - Forgejo encrypts auth creds in DB
- Skip issues/PRs/wiki/releases/LFS (only Git history mirrored)
- Preserve visibility (private → private mirror)
- Reports per-repo HTTP status

### Trigger immediate sync

```bash
# Sync all mirrors now (e.g., right after bulk migration)
for repo in $(gh repo list SREbuilt --limit 100 --json name -q '.[].name'); do
    curl -ksX POST -H "Authorization: token ${FORGEJO_TOKEN}" \
        "${FORGEJO_URL}/api/v1/repos/${FORGEJO_ORG}/${repo}/mirror-sync"
done
```

---

## Phase 1b — Archival snapshots (TRUE backup)

Pull mirror is a replica, not a backup. If GitHub force-pushes or deletes
a branch, Forgejo follows and the history is gone there too. For true
disaster-recovery backup that survives ref deletion:

```bash
# Weekly Git bundle snapshot, stored on NAS
# /usr/local/bin/forgejo-bundle-snapshot.sh on PVE host

#!/bin/bash
set -euo pipefail
SNAPSHOT_DIR="/mnt/nas-praxis/backups/git-bundles/$(date +%Y-%m-%d)"
mkdir -p "$SNAPSHOT_DIR"

cd /var/lib/lxc/104/rootfs/var/lib/docker/volumes/forgejo_forgejo-data/_data/git/repositories/github-mirror

for repo in *.git; do
    name="${repo%.git}"
    git -C "$repo" bundle create "${SNAPSHOT_DIR}/${name}.bundle" --all
done

# Retention: keep last 12 weeks
find /mnt/nas-praxis/backups/git-bundles -mindepth 1 -maxdepth 1 -type d \
    -mtime +90 -exec rm -rf {} +
```

```cron
# /etc/cron.d/forgejo-bundle-snapshot on PVE host
0 4 * * 1 root /usr/local/bin/forgejo-bundle-snapshot.sh
```

Bundles can be restored with `git clone bundle-file.bundle`. They're
immune to upstream rewrites because they're point-in-time snapshots.

---

## Phase 2 (optional) — Near-instant sync for hot repos

Only needed if the 10-min polling lag is too long for specific repos.

### Option B1: GitHub Actions push to Forgejo (per repo)

Add `.github/workflows/mirror-to-forgejo.yml` in each hot repo:

```yaml
name: Mirror to Forgejo
on:
  push:
    branches: ['*']
  delete:

jobs:
  to_forgejo:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: pixta-dev/repository-mirroring-action@v1
        with:
          target_repo_url: git@forgejo.your-domain.com:github-mirror/repo.git
          ssh_private_key: ${{ secrets.FORGEJO_SSH_KEY }}
```

**Blocker**: Forgejo is LAN-only. GitHub Actions runners can't reach
`192.168.178.84`. Requires one of:
- **Cloudflare Tunnel** — free, no port-forward, recommended
- **port-forward** of `:3022` on router (security risk — opens SSH to internet)
- **self-hosted GitHub runner** inside our LAN (defeats GitHub Actions purpose)

**Recommendation if you do this**: Cloudflare Tunnel as a separate
deferred decision. Skip until proven needed.

### Option B2: Reverse direction — push to Forgejo as primary

Make Forgejo the primary, GitHub the mirror. This is what Jorijn does in
his blog post — push goes to Forgejo, Forgejo push-mirrors to GitHub for
discoverability. Bigger change, deferred.

---

## Phase 3 — Maintenance & monitoring

### Health check (mirror sync timestamps)

The critical metric is **last successful mirror sync**, not just disk usage:

```bash
# Per-repo last sync timestamp
curl -ks -H "Authorization: token ${FORGEJO_TOKEN}" \
    "${FORGEJO_URL}/api/v1/orgs/github-mirror/repos?limit=50" \
    | jq -r '.[] | "\(.mirror_updated)\t\(.name)"' \
    | sort

# Alert if any mirror hasn't synced in > 2 hours (e.g., GitHub auth broke)
THRESHOLD=$(date -u -d '2 hours ago' +%FT%TZ)
curl -ks -H "Authorization: token ${FORGEJO_TOKEN}" \
    "${FORGEJO_URL}/api/v1/orgs/github-mirror/repos?limit=50" \
    | jq -r --arg t "$THRESHOLD" '.[] | select(.mirror_updated < $t) | .name'
```

Add this as a daily cron alert (email or Telegram via Hermes).

### Disk usage alerts

```bash
# /etc/cron.d/forgejo-disk-alert on LXC 104
0 */6 * * * root df -h / | awk '/\/$/ {gsub(/%/,"",$5); if ($5+0 >= 60) print "FORGEJO DISK WARNING: " $5"% used"}'
```

Alert thresholds: 60% warn, 75% alarm, 85% urgent.

### Adding new repos

When you create a new GitHub repo, re-run the bulk script — it's
idempotent (`GET` check first) and only adds missing mirrors.

### Removing archived repos from active polling

The script poll-rates archived repos at 168h. If you decide to drop them
entirely, delete via Forgejo UI or API.

### Disk usage budget (revised)

| Item | Size estimate |
|------|---------------|
| All 44 repos (GitHub disk usage, snapshot) | ~750 MB |
| Git pack overhead (~2-3x with history growth) | ~2 GB |
| Postgres growth (mirror metadata) | ~50 MB |
| **LFS objects** (only if `lfs: true` — currently false) | varies |
| **Total expected (no LFS)** | **~2 GB** |
| LXC 104 disk | 16 GB |
| **Headroom** | **~13 GB** |

⚠️ **GitHub "disk usage" excludes LFS, release assets, packages.** If any
SREbuilt repo uses LFS, enable `lfs: true` in migration body and budget
accordingly — LFS objects can easily 10x source size.

To check: `gh repo view SREbuilt/repo --json size,diskUsage` shows `size`
in KB but doesn't separate LFS.

---

## Security considerations

| Concern | Mitigation |
|---------|------------|
| GitHub PAT stored in Forgejo | Forgejo encrypts auth creds in DB. Use a fine-grained PAT (read-only `repo` scope). |
| PAT in shell history during migration | `unset HISTFILE` before running, or pass via `GITHUB_PAT=$(cat .pat)`. |
| Mirror exposes private repos via LAN | Forgejo is `REQUIRE_SIGNIN_VIEW=true` and `DISABLE_REGISTRATION=true`. Only admin (`bvogel`) can view. |
| Compromised GitHub → bad code in mirror | This is a backup, not a CI source. Don't run code from mirror automatically. |
| Mirror auth credentials in Forgejo DB | Daily backup (`/var/lib/forgejo-backups/`) includes encrypted creds. Backup storage is `chmod 700` on PVE host. |
| Token rotation | Add to ops doc: rotate GitHub PAT every 90 days via Forgejo UI → repo settings → mirror config. |

---

## Open decisions before implementation

1. **Forgejo org name**: `github-mirror`, `SREbuilt`, or `mirrors`?
   - **Recommendation**: `github-mirror` — explicit about what it is.
2. **Mirror interval**: 5m, 10m, or 30m for active repos?
   - **Recommendation**: 10m (Forgejo default min) — balance freshness vs API quota
3. **Archived repos**: skip entirely or mirror with long interval?
   - **Recommendation**: **mirror with 168h interval** — preserves them, low overhead. Per critique: "archived repos are often precisely what you want preserved."
4. **Personal GitHub account**: does `bvogel` (or another personal account) have repos to mirror?
   - **Action item**: run `gh repo list bvogel --limit 50` to discover
5. **LFS**: do any SREbuilt repos use Git LFS?
   - **Action item**: inspect — if yes, enable `lfs: true` and re-estimate disk budget
6. **Archival snapshots**: enable weekly `git bundle` to NAS now or defer?
   - **Recommendation**: enable now — true backup (vs replica), cheap, immune to GitHub data loss
7. **Phase 2 real-time sync**: defer entirely or set up Cloudflare Tunnel now?
   - **Recommendation**: defer until 10-min lag actually bites you.
8. **RAM bump during initial migration**: temporarily 1.5 GB then back to 768 MB?
   - **Recommendation**: yes — `pct set 104 --memory 1536` before bulk migration, restore after.

---

## Implementation steps (when you say "go")

### Preparation (one-time, ~10 min)
1. Inventory personal GitHub account (decide if in scope)
2. Check for LFS usage across SREbuilt repos
3. Create **fine-grained** GitHub PAT (Contents+Metadata read, scoped to 44 repos)
4. Create Forgejo admin PAT (`write:repository`, `write:organization`)
5. Create Forgejo org `github-mirror`
6. Temporarily bump LXC 104 RAM: `pct set 104 --memory 1536 && pct reboot 104`

### Pilot (validate before bulk, ~5 min)
7. Run migration script for ONLY the largest private repo (`knx_ha_converter` 90 MB)
8. Watch memory, swap, OOM logs during clone
9. Verify clone via SSH: `git clone forgejo:github-mirror/knx_ha_converter.git /tmp/test && cd /tmp/test && git log -5`
10. Force a sync, verify mirror updates: `curl -ksX POST ... /mirror-sync`

### Bulk migration (~5-10 min)
11. Run `mirror-github-to-forgejo.sh` for all 44 repos
12. Watch `docker logs -f forgejo` for any errors
13. Verify all 44 created: `curl -ks ... /api/v1/orgs/github-mirror/repos | jq '. | length'`

### Post-migration (~5 min)
14. Restore RAM: `pct set 104 --memory 768`
15. Trigger immediate sync of all mirrors
16. Spot-check 3 repos: clone, browse, compare with GitHub
17. Install Phase 3 monitoring cron (sync staleness + disk alert)
18. Install Phase 1b archival snapshot cron (weekly Git bundles to NAS)
19. Update SETUP-GUIDE.md and openclaw_ops.md
20. Commit + push to `feature/forgejo-lxc` branch

**Estimated total time**: ~30 min with verification.

---

## Future considerations (not in scope)

- **Migrate Issues/PRs/Releases**: One-shot import via `POST /repos/migrate`
  with `issues: true, pull_requests: true`. Done once if you ever decide
  to flip Forgejo to primary.
- **Forgejo Actions runner** (Phase 2 of Forgejo deployment) — useful if
  you flip primary direction and want CI inside Forgejo.
- **Public Forgejo via Cloudflare Tunnel** — only needed if external
  collaborators or webhook flow.
