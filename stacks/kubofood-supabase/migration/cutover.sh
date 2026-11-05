#!/usr/bin/env bash
# kubofood cutover: Supabase Cloud → self-hosted stack. Runs on the server.
#
# Phases (each verified; any failure before the app restarts on the new stack
# triggers rollback(): cloud crons back on, the app back up on cloud; no data loss):
#   A  freeze writes      stop the app, disable cloud crons
#   B  fresh stack        wipe the staging copy, re-init the stack (services migrate)
#   C  dump               Supabase CLI dump of roles, schema, data (fresh login role on stdin)
#   D  restore            single transaction, then fingerprint == cloud (after freeze)
#   E  post-restore       storage policies, crons (inactive), vault (production),
#                         URL rewrite, ACL sync (cloud export), storage objects copy
#   F  verify             ACL diff == cloud, DB SQL tests, realtime check
# After F, the caller points the app at the new stack (env + CI deploy) and runs
# activate-crons.sh. Input on stdin: a Supabase Management API token (kept in
# memory only): cloud crons are toggled and short-lived CLI login roles (5 min
# TTL) are minted through it, a fresh one right before each dump.
set -Eeuo pipefail
STACK=/opt/stacks/kubofood-supabase
MIG=$STACK/migration
WORK=/root/sbmig/cutover-$(date -u +%Y%m%dT%H%M%SZ)
APP_UUID=441khsoyzvfgziplconlvss5
REF=vtbipnkbejcffxmjtshm
mkdir -p "$WORK"; exec > >(tee -a "$WORK/cutover.log") 2>&1
read -r SBTOKEN
T=$(cat /etc/ci-deploy/coolify.token); B=http://127.0.0.1:8000/api/v1
api() { curl -fsS --max-time 60 -H "Authorization: Bearer $T" -H "Content-Type: application/json" -H "Accept: application/json" "$@"; }
mgmt_sql() { curl -fsS --max-time 120 -X POST "https://api.supabase.com/v1/projects/$REF/database/query" -H "Authorization: Bearer $SBTOKEN" -H "Content-Type: application/json" -d "$(jq -Rs '{query: .}')"; }
login() {
  local r; r=$(curl -fsS --max-time 30 -X POST "https://api.supabase.com/v1/projects/$REF/cli/login-role" -H "Authorization: Bearer $SBTOKEN" -H "Content-Type: application/json" -d '{"read_only": false}')
  CLOUD_URL="postgresql://$(jq -r .role <<<"$r").$REF:$(jq -r .password <<<"$r")@aws-0-us-west-2.pooler.supabase.com:5432/postgres"
}
local_sql() { docker exec -i kubofood-sb-db psql -U supabase_admin -d postgres -X -q -v ON_ERROR_STOP=1 "$@"; }
step() { printf '\n[%s] %s\n' "$(date -u +%T)" "$*"; }
FROZEN=0
rollback() {
  step "ROLLBACK: re-enabling cloud crons and restarting the app on Supabase Cloud"
  [[ $FROZEN == 1 ]] && { echo "update cron.job set active = true;" | mgmt_sql >/dev/null || echo "!! re-enable cloud crons BY HAND"; }
  api -X POST "$B/applications/$APP_UUID/start" >/dev/null || echo "!! start the app BY HAND"
  echo "rolled back; production is on Supabase Cloud, unchanged."
}
trap 'rc=$?; [[ $rc -ne 0 ]] && rollback; exit $rc' EXIT

step "0. preflight + fresh stack (before the freeze; staging copy discarded)"
echo "select count(*) as jobs from cron.job;" | mgmt_sql | jq -e '.[0].jobs == 20' >/dev/null || { echo "management API check failed"; exit 1; }
docker rm -f kubofood-staging >/dev/null 2>&1 || true
( cd "$STACK" && docker compose down >/dev/null 2>&1 && rm -rf volumes/db/data volumes/storage && docker volume rm -f kubofood-supabase_db-config >/dev/null && ./deploy.sh | tail -2 )

step "A. freeze writes"
api -X POST "$B/applications/$APP_UUID/stop" >/dev/null
for i in $(seq 1 60); do [[ -z "$(docker ps -q --filter name=$APP_UUID)" ]] && break; sleep 2; done
[[ -z "$(docker ps -q --filter name=$APP_UUID)" ]] || { echo "app did not stop"; exit 1; }
FROZEN=1
echo "update cron.job set active = false; select count(*) filter (where active) as still from cron.job;" | mgmt_sql | jq -e '.[0].still == 0' >/dev/null || { echo "cloud crons did not stop"; exit 1; }
echo "app stopped, cloud crons off"
sleep 5   # let in-flight requests settle

step "C. dump from cloud (after freeze)"
cd "$WORK"
login; supabase db dump --db-url "$CLOUD_URL" -f roles.sql --role-only >/dev/null 2>cli-roles.log
login; supabase db dump --db-url "$CLOUD_URL" -f schema.sql >/dev/null 2>cli-schema.log
login; supabase db dump --db-url "$CLOUD_URL" -f data.sql --use-copy --data-only -x storage.buckets_vectors -x storage.vector_indexes >/dev/null 2>cli-data.log
sha256sum roles.sql schema.sql data.sql | tee SHA256SUMS
mgmt_sql < "$MIG/fingerprint.sql" | jq -r '.[] | "\(.kind) \(.name) \(.val)"' > fp.cloud
mgmt_sql < "$MIG/acl-export.sql" | jq -r '.[].stmt' > acl.cloud
echo "select bucket_id, name, coalesce(metadata->>'mimetype','') as m, coalesce(metadata->>'cacheControl','') as c, coalesce(metadata->>'size','') as s, coalesce(metadata->>'eTag','') as e from storage.objects order by 1, 2;" \
  | mgmt_sql | jq -r '.[] | [.bucket_id, .name, .m, .c, .s, .e] | @tsv' > objects.tsv
echo "fingerprint lines: $(wc -l < fp.cloud), acl statements: $(wc -l < acl.cloud), objects: $(wc -l < objects.tsv)"
[[ $(wc -l < acl.cloud) -gt 100 && $(wc -l < fp.cloud) -gt 200 ]] || { echo "export too small"; exit 1; }

step "D. restore + fingerprint"
for f in roles.sql schema.sql data.sql; do docker cp "$f" kubofood-sb-db:/tmp/$f >/dev/null; done
docker exec kubofood-sb-db psql -U supabase_admin -d postgres --single-transaction -v ON_ERROR_STOP=1 -q -X \
  -f /tmp/roles.sql -f /tmp/schema.sql -c "SET session_replication_role = replica" -f /tmp/data.sql > restore.log 2>&1
local_sql -At -F ' ' < $MIG/fingerprint.sql > fp.local
grep -vE '^count storage\.policies|^table storage\.iceberg_' fp.cloud > a; grep -vE '^count storage\.policies|^table storage\.iceberg_' fp.local > b
diff a b && echo "fingerprint IDENTICAL: $(grep -c '^table ' a) tables" || { echo "FINGERPRINT MISMATCH"; exit 1; }

step "E. post-restore"
local_sql < "$MIG/10-storage-policies.sql" >/dev/null
local_sql < "$MIG/20-cron-jobs.sql" >/dev/null
CS=$(docker exec coolify php artisan tinker --execute="echo \\App\\Models\\Application::where('uuid','$APP_UUID')->first()->environment_variables()->where('key','CRON_SECRET')->where('is_preview',false)->first()->value;" 2>/dev/null | tail -1 | tr -d '\r\n')
[[ ${#CS} -ge 32 ]] || { echo "could not read production CRON_SECRET"; exit 1; }
local_sql -v app_url=https://www.kubofood.app -v cron_secret="$CS" < "$MIG/30-vault.sql" | tail -3
local_sql -v old=https://$REF.supabase.co -v new=https://api.kubofood.app < "$MIG/40-storage-urls.sql" 2>&1 | grep -E "total rows rewritten" || true
{ echo 'begin;'; cat "$MIG/50-acl-reset.sql"; cat acl.cloud; echo 'commit;'; } | local_sql >/dev/null
SERVICE_ROLE_KEY=$(sed -n 's/^SUPABASE_SERVICE_ROLE_KEY=//p' /root/sbmig/keys.env) python3 -I "$MIG/copy_storage.py" "https://$REF.supabase.co" http://127.0.0.1:54321 objects.tsv

step "F. verify"
local_sql -At < "$MIG/acl-export.sql" > acl.local
diff <(sort acl.cloud) <(sort acl.local) >/dev/null && echo "ACLs IDENTICAL ($(wc -l < acl.local))" || { echo "ACL MISMATCH"; exit 1; }
pass=0; fail=0
for f in /root/kubo-sqltests/supabase/tests/*.sql; do
  case $(basename "$f") in 055_*|056_*) continue ;; esac   # stale vs schema on cloud too
  if docker exec -i kubofood-sb-db psql -U postgres -d postgres -X -q -v ON_ERROR_STOP=1 < "$f" >/dev/null 2>&1; then pass=$((pass+1)); else fail=$((fail+1)); echo "SQL test failed: $(basename "$f")"; fi
done
echo "SQL tests: $pass passed, $fail failed"; [[ $fail -eq 0 ]] || exit 1
docker run --rm -v /root/sbmig/rt-test.mjs:/t.mjs:ro -e ANON="$(sed -n 's/^NEXT_PUBLIC_SUPABASE_ANON_KEY=//p' /root/sbmig/keys.env)" -e SERVICE="$(sed -n 's/^SUPABASE_SERVICE_ROLE_KEY=//p' /root/sbmig/keys.env)" node:24-slim node /t.mjs | tail -1

trap - EXIT
step "DATA CUTOVER COMPLETE. Next: point the app at https://api.kubofood.app (env + CI deploy), then activate crons."
echo "$WORK" > /root/sbmig/last_cutover
