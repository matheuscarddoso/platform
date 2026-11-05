#!/usr/bin/env bash
# Local backups of the self-hosted craft Supabase stack.
#   backup.sh hourly -> database dump, keeps 48
#   backup.sh daily  -> database dump (keeps 30) + storage objects archive (keeps 14)
#
# Local copies do not survive losing the server: they cover bad writes and bad
# deploys. Off-site replication is tracked in docs/runbooks/leaving-vercel.md.
#
# Every dump is validated before it replaces anything: a dump pg_restore cannot
# list, or one with too few tables, fails the run and never enters rotation.
# Failures are logged and recorded in $ROOT/LAST_FAILURE; success removes that file.
set -Eeuo pipefail
umask 077

KIND=${1:-}
case "$KIND" in hourly|daily) ;; *) echo "usage: backup.sh hourly|daily" >&2; exit 2 ;; esac

ROOT=/root/backups/craft
STACK=/opt/stacks/craft-supabase
DB=craft-sb-db
MIN_TABLES=30    # 45 tables in public/auth/storage at cutover
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
DIR=$ROOT/$KIND
mkdir -p "$DIR"

log() { echo "[$(date -u +%FT%TZ)] $KIND: $*"; }
TMP_DUMP=$(mktemp "$DIR/.tmp.XXXXXX")
TMP_GLOBALS=$(mktemp "$DIR/.tmp.XXXXXX")
TMP_TAR=$(mktemp "$DIR/.tmp.XXXXXX")
cleanup() { rm -f "$TMP_DUMP" "$TMP_GLOBALS" "$TMP_TAR"; }
fail() { local line=$1; log "FAILED at line $line"; echo "$STAMP $KIND line $line" > "$ROOT/LAST_FAILURE"; cleanup; }
trap 'fail $LINENO' ERR
trap cleanup EXIT

# Newest N files matching a pattern stay; the rest are removed.
rotate() { local keep=$1 pattern=$2; /usr/bin/find "$DIR" -maxdepth 1 -type f -name "$pattern" -printf '%f\n' | sort -r | tail -n +$((keep + 1)) | while read -r f; do rm -f "$DIR/$f"; done; }

docker exec "$DB" pg_dump -U supabase_admin -d postgres -Fc > "$TMP_DUMP"
docker exec "$DB" pg_dumpall -U supabase_admin --globals-only > "$TMP_GLOBALS"

TABLES=$(docker exec -i "$DB" pg_restore -l < "$TMP_DUMP" | grep -c ' TABLE DATA ' || true)
if [ "$TABLES" -lt "$MIN_TABLES" ]; then
  log "dump has only $TABLES tables with data (minimum $MIN_TABLES)"
  false
fi

mv "$TMP_DUMP" "$DIR/db-$STAMP.dump"
mv "$TMP_GLOBALS" "$DIR/globals-$STAMP.sql"
(cd "$DIR" && sha256sum "db-$STAMP.dump" "globals-$STAMP.sql" > "db-$STAMP.sha256")

if [ "$KIND" = hourly ]; then
  rotate 48 'db-*.dump'; rotate 48 'globals-*.sql'; rotate 48 'db-*.sha256'
else
  rotate 30 'db-*.dump'; rotate 30 'globals-*.sql'; rotate 30 'db-*.sha256'
  # .env holds the JWT secret and generated service passwords a restore needs.
  tar -C "$STACK" -czf "$TMP_TAR" volumes/storage .env
  mv "$TMP_TAR" "$DIR/storage-$STAMP.tar.gz"
  rotate 14 'storage-*.tar.gz'
fi

rm -f "$ROOT/LAST_FAILURE"
log "ok: $TABLES tables, db $(du -h "$DIR/db-$STAMP.dump" | cut -f1)"
