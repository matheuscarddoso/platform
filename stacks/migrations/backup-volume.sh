#!/usr/bin/env bash
# backup-volume.sh <name> <docker-volume> [keep]: daily archive of an app's file volume, validated before rotation.
set -Eeuo pipefail; umask 077
N=$1; V=$2; KEEP=${3:-14}; D=/root/backups/$N/files; mkdir -p "$D"
S=$(docker volume inspect "$V" --format '{{.Mountpoint}}'); TS=$(date -u +%Y%m%dT%H%M%SZ); TMP=$(mktemp "$D/.tmp.XXXXXX"); trap 'rm -f "$TMP"' EXIT
tar -C "$S" -czf "$TMP" .; tar -tzf "$TMP" >/dev/null
mv "$TMP" "$D/files-$TS.tar.gz"; ls -1t "$D"/files-*.tar.gz | tail -n +$((KEEP + 1)) | xargs -r rm -f
echo "[$(date -u +%FT%TZ)] $N: ok $(du -h "$D/files-$TS.tar.gz" | cut -f1)"
