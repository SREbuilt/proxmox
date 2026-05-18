#!/bin/bash
# Weekly Git bundle snapshot to NAS — true backup (immune to ref deletion)
# Runs inside LXC 104 via pct exec, output to /nas-bundles (NAS bind-mount)
set -euo pipefail

DATE=$(date +%Y-%m-%d)
RETENTION_WEEKS=12
NAS_HOST_DIR="/mnt/nas-praxis/backups/git-bundles"

# Verify NAS dir exists and is writable (don't check exact mountpoint — too brittle)
if [[ ! -d "$NAS_HOST_DIR" ]] || ! touch "$NAS_HOST_DIR/.write-test" 2>/dev/null; then
    echo "[$(date)] FATAL: NAS dir $NAS_HOST_DIR not writable (NAS unmounted?)"
    exit 1
fi
rm -f "$NAS_HOST_DIR/.write-test"

# Run the bundling inside the LXC (single pct exec, all logic in one go)
/usr/sbin/pct exec 104 -- bash -c "
set -euo pipefail
DATE=\"$DATE\"
REPO_DIR=/var/lib/docker/volumes/forgejo_forgejo-data/_data/git/repositories/github-mirror
SNAPSHOT_DIR=/nas-bundles/\$DATE
mkdir -p \"\$SNAPSHOT_DIR\"
COUNT=0
for repo in \"\$REPO_DIR\"/*.git; do
    [[ -d \"\$repo\" ]] || continue
    name=\$(basename \"\$repo\" .git)
    # safe.directory=* needed: Forgejo files are owned by UID 1000 but cron runs as root inside LXC
    if git -c safe.directory=\"*\" -C \"\$repo\" bundle create \"\$SNAPSHOT_DIR/\$name.bundle\" --all --quiet 2>&1; then
        COUNT=\$((COUNT + 1))
    fi
done
SIZE=\$(du -sh \"\$SNAPSHOT_DIR\" | cut -f1)
echo \"Bundled \$COUNT repos (\$SIZE) -> \$SNAPSHOT_DIR\"
"

# Retention: drop snapshots older than N weeks (run on PVE host, NAS path)
find "$NAS_HOST_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +$((RETENTION_WEEKS * 7)) -exec rm -rf {} \; 2>/dev/null || true

echo "[$(date)] Bundle snapshot complete"
