#!/usr/bin/env bash
# craft: Supabase Cloud -> self-hosted stack. Runs on the server.
#   cutover.sh rehearse   copy and verify with the app up; the stack is rebuilt on the real run
#   cutover.sh cut        stop the app first, then the same; on failure the app restarts on cloud
# stdin: a Supabase Management API token, kept in memory only. Shares the reviewed SQL and the
# storage copy with stacks/kubofood-supabase/migration. After a cut the app is pointed at the
# new stack by golive.sh (env + CI deploy, since the URL is inlined at build time).
set -Eeuo pipefail
MODE=${1:?rehearse or cut}
STACK=/opt/stacks/craft-supabase; MIG=/opt/stacks/kubofood-supabase/migration
APP=idgtmczjvteqkwd1eika5kvr; REF=elevknldozsjnhcocprk; NEW=https://craft-api.ocardoso.com
WORK=/root/dbmig/craft/run-$MODE-$(date -u +%Y%m%dT%H%M%SZ); mkdir -p "$WORK"; chmod 700 "$WORK"; cd "$WORK"
exec > >(tee -a run.log) 2>&1
read -r SBTOKEN
T=$(cat /etc/ci-deploy/coolify.token); B=http://127.0.0.1:8000/api/v1
api() { curl -fsS --max-time 60 -H "Authorization: Bearer $T" -H "Content-Type: application/json" -H "Accept: application/json" "$@"; }
mgmt_sql() { curl -fsS --max-time 120 -X POST "https://api.supabase.com/v1/projects/$REF/database/query" -H "Authorization: Bearer $SBTOKEN" -H "Content-Type: application/json" -d "$(jq -Rs '{query: ., read_only: false}')"; }
login() { local r; r=$(curl -fsS --max-time 30 -X POST "https://api.supabase.com/v1/projects/$REF/cli/login-role" -H "Authorization: Bearer $SBTOKEN" -H "Content-Type: application/json" -d '{"read_only": false}'); CLOUD_URL="postgresql://$(jq -r .role <<<"$r").$REF:$(jq -r .password <<<"$r")@aws-0-sa-east-1.pooler.supabase.com:5432/postgres"; }
local_sql() { docker exec -i craft-sb-db psql -U supabase_admin -d postgres -X -q -v ON_ERROR_STOP=1 "$@"; }
step() { printf '\n[%s] %s\n' "$(date -u +%T)" "$*"; }
FROZEN=0
rollback() { [[ $FROZEN == 1 ]] && { step "ROLLBACK: restarting the app on Supabase Cloud"; api -X POST "$B/applications/$APP/start" >/dev/null || echo "!! start the app BY HAND"; }; }
trap 'rc=$?; [[ $rc -ne 0 ]] && rollback; exit $rc' EXIT

step "0. fresh stack"
echo "select 1 as ok;" | mgmt_sql | jq -e '.[0].ok == 1' >/dev/null
( cd "$STACK" && docker compose down >/dev/null 2>&1; rm -rf volumes/db/data volumes/storage; docker volume rm -f craft-supabase_db-config >/dev/null; ./deploy.sh | tail -1 )

if [[ $MODE == cut ]]; then
  step "A. freeze writes"
  api -X POST "$B/applications/$APP/stop" >/dev/null; FROZEN=1
  for i in $(seq 1 60); do [[ -z "$(docker ps -q --filter name=$APP)" ]] && break; sleep 2; done
  [[ -z "$(docker ps -q --filter name=$APP)" ]] || { echo "app did not stop"; exit 1; }
  sleep 3
fi

step "C. dump from cloud"
login; supabase db dump --db-url "$CLOUD_URL" -f roles.sql --role-only >/dev/null 2>cli-roles.log
login; supabase db dump --db-url "$CLOUD_URL" -f schema.sql >/dev/null 2>cli-schema.log
login; supabase db dump --db-url "$CLOUD_URL" -f data.sql --use-copy --data-only -x storage.buckets_vectors -x storage.vector_indexes >/dev/null 2>cli-data.log
sha256sum roles.sql schema.sql data.sql > SHA256SUMS; wc -c roles.sql schema.sql data.sql | tail -1
mgmt_sql < "$MIG/fingerprint.sql" | jq -r '.[] | "\(.kind) \(.name) \(.val)"' > fp.cloud
mgmt_sql < "$MIG/acl-export.sql" | jq -r '.[].stmt' > acl.cloud
cat > pol.sql <<'S'
select format('create policy %I on %I.%I as %s for %s to %s%s%s;', policyname, schemaname, tablename, permissive, cmd, array_to_string(roles, ','), coalesce(' using ('||qual||')',''), coalesce(' with check ('||with_check||')','')) as stmt from pg_policies where schemaname = 'storage';
S
mgmt_sql < pol.sql | jq -r '.[].stmt' > policies.sql
echo "select bucket_id, name, coalesce(metadata->>'mimetype','') as m, coalesce(metadata->>'cacheControl','') as c, coalesce(metadata->>'size','') as s, coalesce(metadata->>'eTag','') as e from storage.objects;" | mgmt_sql | jq -r '.[] | [.bucket_id, .name, .m, .c, .s, .e] | @tsv' > objects.tsv
echo "fingerprint: $(wc -l < fp.cloud), acl: $(wc -l < acl.cloud), storage policies: $(wc -l < policies.sql), objects: $(wc -l < objects.tsv)"
[[ $(wc -l < acl.cloud) -gt 10 && $(wc -l < fp.cloud) -gt 20 && $(wc -l < policies.sql) -eq 4 ]] || { echo "export too small"; exit 1; }

step "D. restore + fingerprint"
for f in roles.sql schema.sql data.sql; do docker cp "$f" craft-sb-db:/tmp/$f >/dev/null; done
docker exec craft-sb-db psql -U supabase_admin -d postgres --single-transaction -v ON_ERROR_STOP=1 -q -X -f /tmp/roles.sql -f /tmp/schema.sql -c "SET session_replication_role = replica" -f /tmp/data.sql > restore.log 2>&1
local_sql -At -F ' ' < "$MIG/fingerprint.sql" > fp.local
grep -vE '^count storage\.policies|^table storage\.iceberg_' fp.cloud > a; grep -vE '^count storage\.policies|^table storage\.iceberg_' fp.local > b
if [[ $MODE == rehearse ]]; then diff a b && echo "fingerprint IDENTICAL: $(grep -c '^table ' a) tables" || echo "DIFF (app is live in a rehearsal, review above)"; else diff a b && echo "fingerprint IDENTICAL: $(grep -c '^table ' a) tables" || { echo "FINGERPRINT MISMATCH"; exit 1; }; fi

step "E. post-restore"
local_sql < policies.sql >/dev/null
local_sql -v old=https://$REF.supabase.co -v new=$NEW < "$MIG/40-storage-urls.sql" 2>&1 | grep -E "total rows rewritten" || true
{ echo 'begin;'; cat "$MIG/50-acl-reset.sql"; cat acl.cloud; echo 'commit;'; } | local_sql >/dev/null
SERVICE_ROLE_KEY=$(sed -n 's/^SUPABASE_SERVICE_ROLE_KEY=//p' /root/dbmig/craft/keys.env) python3 -I "$MIG/copy_storage.py" "https://$REF.supabase.co" "$NEW" objects.tsv

step "F. verify"
local_sql -At < "$MIG/acl-export.sql" > acl.local
diff <(sort acl.cloud) <(sort acl.local) >/dev/null && echo "ACLs IDENTICAL ($(wc -l < acl.local))" || { echo "ACL MISMATCH"; exit 1; }
echo "storage policies: $(local_sql -At -c "select count(*) from pg_policies where schemaname='storage'")  rls on objects: $(local_sql -At -c "select relrowsecurity from pg_class where oid='storage.objects'::regclass")"
echo "users: $(local_sql -At -c 'select count(*) from auth.users')  profiles: $(local_sql -At -c 'select count(*) from public.profiles')"
trap - EXIT
step "DATA COPY COMPLETE ($MODE)"
