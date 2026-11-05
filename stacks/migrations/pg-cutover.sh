#!/usr/bin/env bash
# Moves an app's Postgres from a managed service to a private Coolify database.
#
#   pg-cutover.sh rehearse <name>            dump + restore + compare, app stays up
#   pg-cutover.sh cut <name> <app-uuid>      stop app, final dump + restore + compare,
#                                            switch DATABASE_URL, start app
#
# Expects /root/dbmig/<name>/source.url (direct endpoint) and target.url. A content
# mismatch or any failure before the switch starts the app again on the source,
# which was never written to, so nothing is lost.
set -Eeuo pipefail; umask 077
MODE=$1; N=$2; APP=${3:-}
W=/root/dbmig/$N; BK=/root/backups/$N; mkdir -p "$BK"; cd "$W"
S=$(cat source.url); U=$(cat target.url)
TS=$(date -u +%Y%m%dT%H%M%SZ)
PG=postgres:18-alpine
pg() { docker run --rm -i --network coolify -v "$W":/w -v "$BK":/b -e S="$S" -e U="$U" -e TS="$TS" "$PG" sh -c "$1"; }
log() { echo "[$(date -u +%T)] $*"; }

fingerprint() { # $1 = S or U. Rows and content of every table, sequences and object counts.
  pg "psql \"\$$1\" -X -At -v ON_ERROR_STOP=1" <<'SQL' | sort
select 'table|'||n||'|'||(xpath('/row/c/text()', query_to_xml(format('select count(*)||'':''||coalesce(md5(string_agg(t::text, ''|'' order by t::text)),'''') as c from %s t', n), false, true, '')))[1]::text
from (select format('%I.%I', schemaname, tablename) n from pg_tables where schemaname not in ('pg_catalog','information_schema') and schemaname !~ '^(pg_|_timescale)') x;
select 'seq|'||format('%I.%I', schemaname, sequencename)||'|'||coalesce(last_value::text,'-') from pg_sequences where schemaname not in ('pg_catalog','information_schema');
select 'count|functions|'||count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname not in ('pg_catalog','information_schema') and n.nspname !~ '^pg_';
select 'count|indexes|'||count(*) from pg_indexes where schemaname not in ('pg_catalog','information_schema');
select 'count|constraints|'||count(*) from pg_constraint c join pg_namespace n on n.oid=c.connamespace where n.nspname not in ('pg_catalog','information_schema') and n.nspname !~ '^pg_';
select 'count|triggers|'||count(*) from pg_trigger where not tgisinternal;
SQL
}

dump_restore() {
  log "dump from source"
  pg 'pg_dump "$S" --format=custom --no-owner --no-privileges --file=/b/source-$TS.dump && pg_restore --list /b/source-$TS.dump | grep -c "TABLE DATA" | sed "s/^/   tables with data in dump: /"'
  (cd "$BK" && sha256sum "source-$TS.dump" > "source-$TS.sha256")
  log "reset target and restore"
  local DBN=${U##*/}; DBN=${DBN%%\?*}; local ADMIN=${U%/*}/postgres
  docker run --rm --network coolify "$PG" psql "${ADMIN%%\?*}?sslmode=disable" -X -q -v ON_ERROR_STOP=1 -c "drop database if exists \"$DBN\" with (force)" -c "create database \"$DBN\""
  pg 'pg_restore --dbname="$U" --no-owner --no-privileges --exit-on-error --single-transaction /b/source-$TS.dump'
  log "compare content"
  fingerprint S > fp.source; fingerprint U > fp.target
  echo "   lines: source=$(wc -l < fp.source) target=$(wc -l < fp.target) tables=$(grep -c '^table|' fp.source)"
  [ "$(grep -c '^table|' fp.source)" -gt 0 ] || { log "empty fingerprint"; return 1; }
  if diff fp.source fp.target > fp.diff; then log "IDENTICAL"; else log "MISMATCH"; cut -c1-110 fp.diff | head -20; return 1; fi
}

case "$MODE" in
rehearse) dump_restore; echo; echo "biggest tables:"; grep '^table|' fp.source | awk -F'[|:]' '{print $3, $2}' | sort -rn | head -6 ;;
cut)
  [ -n "$APP" ] || { echo "app uuid required"; exit 2; }
  T=$(cat /etc/ci-deploy/coolify.token); B=http://127.0.0.1:8000/api/v1
  api() { curl -fsS --max-time 60 -H "Authorization: Bearer $T" -H "Content-Type: application/json" -H "Accept: application/json" "$@"; }
  FROZEN=0
  rollback() { if [ $FROZEN = 1 ]; then log "ROLLBACK: starting the app on the source database"; api -X POST "$B/applications/$APP/start" >/dev/null || true; fi; }
  trap rollback EXIT
  log "freeze: stopping app"
  api -X POST "$B/applications/$APP/stop" >/dev/null; FROZEN=1
  for i in $(seq 1 60); do [ -z "$(docker ps -q --filter name=$APP)" ] && break; python3 -c 'import time;time.sleep(2)'; done
  [ -z "$(docker ps -q --filter name=$APP)" ] || { log "app did not stop"; exit 1; }
  log "other clients on the source:"; pg "psql \"\$S\" -X -At -c \"select coalesce(application_name,'')||' '||coalesce(state,'')||' '||count(*) from pg_stat_activity where datname=current_database() and pid<>pg_backend_pid() and usename !~ '^(cloud_admin|neon)' group by application_name,state\"" | cut -c1-90
  dump_restore
  log "switch env"
  printf 'DATABASE_URL=%s\n' "$U" > env.new
  python3 -I /root/dbmig/setenv.py "$APP" env.new; shred -u env.new
  trap - EXIT
  log "start app on the new database"
  api -X POST "$B/applications/$APP/start" >/dev/null
  for i in $(seq 1 60); do c=$(docker ps -q --filter name=$APP | head -1); [ -n "$c" ] && [ "$(docker inspect "$c" --format '{{.State.Health.Status}}')" = healthy ] && break; python3 -c 'import time;time.sleep(2)'; done
  c=$(docker ps --filter name=$APP --format '{{.Names}}' | head -1); log "app: $(docker ps --filter name=$APP --format '{{.Status}}' | head -1)"
  [ "$(docker exec "$c" printenv DATABASE_URL)" = "$U" ] && log "app is using the new database" || { log "APP IS NOT ON THE NEW DATABASE"; exit 1; }
  ;;
esac
