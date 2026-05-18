#!/bin/bash
# Weekly Git bundle snapshot to NAS — true backup (immune to ref deletion)
# Runs inside LXC 104 via a helper script (avoids subshell /usr/sbin/pct exec issues)
set -euo pipefail

DATE=$(date +%Y-%m-%d)
RETENTION_WEEKS=12

# Verify NAS mounted
mountpoint -q /mnt/nas-praxis || { echo "[$(date)] FATAL: NAS not mounted"; exit 1; }

# Run the bundling inside the LXC (single /usr/sbin/pct exec, all logic in one go)
/usr/sbin/pct exec 104 -- bash -c "
set -euo pipefail
DATE=\"$DATE\"
REPO_DIR=/var/lib/docker/volumes/forgejo_forgejo-data/_data/git/repositories/github-mirror
SNAPSHOT_DIR=/nas-bundles/\${DATE}
mkdir -p \"\$SNAPSHOT_DIR\"
COUNT=0
for repo in \"\$REPO_DIR\"/*.git; do
    [[ -d \"\$repo\" ]] || continue
    name=\$(basename \"\$repo\" .git)
    if git -c safe.directory=\"*\" -C \"\$repo\" bundle create \"\$SNAPSHOT_DIR/\$name.bundle\" --all --quiet 2>&1; then
        COUNT=\$((COUNT + 1))
    fi
done
SIZE=\$(du -sh \"\$SNAPSHOT_DIR\" | cut -f1)
echo \"Bundled \$COUNT repos (\$SIZE) -> \$SNAPSHOT_DIR\"
"

# Retention on host (NAS path accessible directly)
find /mnt/nas-praxis/backups/git-bundles -mindepth 1 -maxdepth 1 -type d -mtime +$((RETENTION_WEEKS * 7)) -exec rm -rf {} \; 2>/dev/null || true

echo "[$(date)] Bundle snapshot complete"
