#!/bin/bash
# Neo4j 2-tier backup (local + NAS) with rotation
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
